import Foundation
import GRDB
import XCTest
@testable import OFFLINE

/// Phase 10.9: malformed, hostile or unsupported import files are rejected with a message
/// and never change anything already in the library — tracks, files, ordinary playlists,
/// earlier imports and their occurrences (byte-for-byte integrity snapshot).
final class ReleaseCorruptImportTests: XCTestCase {
    private typealias F = PlaylistImportFixtures
    private typealias R = ReleaseImportFixtures

    private func populatedFixture() async throws -> LibraryFixture {
        let fixture = try LibraryFixture(count: 3)
        retainUntilTeardown(fixture)
        let ordinary = try fixture.repository.createPlaylist(name: "Ordinary")
        try fixture.repository.addTracks(fixture.ids, playlistID: ordinary.id)
        let earlier = try XCTUnwrap(F.parse(R.csv(20), filename: "Earlier.csv").candidates.first)
        _ = try await PlaylistImportCoordinator(persistence: fixture.storage.playlistMigrations).commit(earlier, destinationName: "Earlier import")
        return fixture
    }

    private static func row(_ title: String, uri: String = "spotify:track:\(ReleaseImportFixtures.trackID(1))") -> String {
        "\(title),Artist,Album,180000,\(uri)\n"
    }

    /// Files that parse into a report whose every candidate is invalid (with a diagnostic).
    private var invalidDocuments: [(String, Data)] {
        let h = R.header
        var cases: [(String, Data)] = [
            ("Empty.csv", Data()),
            ("NoTrackName.csv", Data("Artist Name(s),Album Name\nArtist,Album\n".utf8)),
            ("UnclosedQuote.csv", Data((h + "\"Unclosed,Artist,Album,180000,spotify:track:\(R.trackID(1))\n").utf8)),
            ("StrayQuote.csv", Data((h + "Bad\"Quote,Artist,Album,180000,spotify:track:\(R.trackID(1))\n").utf8)),
            ("InvalidUTF8.csv", Data(h.utf8) + Data([0x53, 0x6F, 0xFF, 0xFE, 0x2C, 0x0A])),
            ("Semicolons.csv", Data("Track Name;Artist Name(s);Track URI\nSong;Artist;spotify:track:\(R.trackID(1))\n".utf8)),
            ("MissingTitle.csv", Data((h + Self.row("")).utf8)),
            ("LongTitle.csv", Data((h + Self.row(String(repeating: "x", count: 301))).utf8)),
            ("HugeField.csv", Data((h + Self.row(String(repeating: "y", count: 17 * 1024))).utf8)),
            ("BadSpotifyID.csv", Data((h + Self.row("Song", uri: "spotify:track:short")).utf8)),
            ("EpisodeURI.csv", Data((h + Self.row("Song", uri: "spotify:episode:\(R.trackID(1))")).utf8)),
            ("ColumnMismatch.csv", Data((h + "Song,Artist\n").utf8)),
            ("NegativeDuration.csv", Data((h + "Song,Artist,Album,-5,spotify:track:\(R.trackID(1))\n").utf8)),
            ("MalformedJSON.json", Data(#"{"playlists": ["#.utf8)),
            ("ArrayRoot.json", Data("[1,2,3]".utf8)),
            ("PlaylistsObject.json", Data(#"{"playlists": {"name": "x"}}"#.utf8)),
            ("StreamingHistory.json", Data(#"[{"endTime":"2024-01-01 00:00","artistName":"A","trackName":"B","msPlayed":1}]"#.utf8)),
            ("InvalidUTF8.json", Data([0x7B, 0xFF, 0x7D])),
            ("EpisodeItem.json", (try? F.json([["name": "Bad", "items": [["episode": ["name": "Podcast"]]]]])) ?? Data()),
        ]
        // A ZIP whose only playlist member is invalid.
        if let zip = try? F.zip([("Bad.csv", Data("Track Name\n\"open\n".utf8))]) { cases.append(("OnlyBadMember.zip", zip)) }
        return cases
    }

    /// Files rejected as a whole before any playlist is reviewed.
    private func rejectedFiles() throws -> [(String, Data)] {
        let valid = try F.zip([("Good.csv", R.csv(5))])
        return [
            ("Playlist.txt", R.csv(5)),
            ("Playlist.mp3", R.csv(5)),
            ("NoExtension", R.csv(5)),
            ("Truncated.zip", valid.prefix(valid.count / 2)),
            ("Garbage.zip", Data(repeating: 0x50, count: 4096)),
            ("Traversal.zip", try F.zip([("../escape.csv", R.csv(5))])),
            ("Absolute.zip", try F.zip([("/abs.csv", R.csv(5))])),
            ("Nested.zip", try F.zip([("inner.zip", valid)])),
            ("Oversized.csv", Data(count: PlaylistImportLimits.inputBytes + 1)),
        ]
    }

    func testInvalidDocumentsAreReportedAndNeverCommitOrChangeExistingData() async throws {
        let fixture = try await populatedFixture()
        let before = try ReleaseIntegritySnapshot.capture(fixture.storage.database.dbQueue, paths: fixture.paths)
        let coordinator = PlaylistImportCoordinator(persistence: fixture.storage.playlistMigrations)
        for (name, bytes) in invalidDocuments {
            let url = fixture.paths.documents.appendingPathComponent(name)
            try bytes.write(to: url)
            let report: PlaylistImportReport
            do { report = try await F.importer(fixture).prepare(file: url) }
            catch { XCTAssertTrue(error is PlaylistImportProblem, "\(name): \(error)"); continue }
            XCTAssertEqual(report.validCount, 0, "\(name) produced an importable playlist")
            XCTAssertFalse(report.candidates.isEmpty && report.notes.isEmpty, "\(name) produced no explanation")
            for candidate in report.candidates {
                XCTAssertFalse(candidate.diagnostics.isEmpty, "\(name) has no meaningful error")
                do { _ = try await coordinator.commit(candidate, destinationName: "Must not exist"); XCTFail("\(name) was committed") }
                catch { XCTAssertTrue(error is PlaylistImportProblem, "\(name): \(error)") }
            }
        }
        let after = try ReleaseIntegritySnapshot.capture(fixture.storage.database.dbQueue, paths: fixture.paths)
        XCTAssertEqual(after, before, "Rejected files changed user data: \(before) → \(after)")
        XCTAssertEqual(try fixture.foreignKeys(), 0)
    }

    func testRejectedFilesFailWholeWithAMessageAndLeaveNoStagingOrData() async throws {
        let fixture = try await populatedFixture()
        let before = try ReleaseIntegritySnapshot.capture(fixture.storage.database.dbQueue, paths: fixture.paths)
        for (name, bytes) in try rejectedFiles() {
            let url = fixture.paths.documents.appendingPathComponent(name)
            try bytes.write(to: url)
            do {
                let report = try await F.importer(fixture).prepare(file: url)
                XCTFail("\(name) was accepted for review with \(report.validCount) playlists")
            } catch {
                let problem = error as? PlaylistImportProblem
                XCTAssertNotNil(problem, "\(name): unexpected \(error)")
                XCTAssertFalse(problem?.errorDescription?.isEmpty ?? true, "\(name) has no meaningful error")
            }
        }
        XCTAssertEqual(try ReleaseIntegritySnapshot.capture(fixture.storage.database.dbQueue, paths: fixture.paths), before)
        let staged = (try? FileManager.default.contentsOfDirectory(atPath: fixture.paths.imports.path)) ?? []
        XCTAssertFalse(staged.contains { $0.hasPrefix("playlist-import-") }, "Staging copies were left behind")
    }

    /// A ZIP holding several playlists commits each valid one independently; the invalid ones
    /// are reported and nothing partial is written for them.
    func testMixedArchiveImportsOnlyValidPlaylistsCompletely() async throws {
        let fixture = try await populatedFixture()
        let before = try ReleaseIntegritySnapshot.capture(fixture.storage.database.dbQueue, paths: fixture.paths)
        let archive = try F.zip([("Good one.csv", R.csv(120)), ("Broken.csv", Data((R.header + Self.row("")).utf8)),
                                 ("Playlist1.json", R.json(80)), ("Notes.txt", Data("hello".utf8)),
                                 ("Truncated.json", Data(#"{"playlists":[{"name":"x","items":["#.utf8))])
        let report = try F.parse(archive, filename: "Export.zip")
        XCTAssertEqual(report.validCount, 2)
        XCTAssertEqual(report.candidates.count, 4)
        XCTAssertTrue(report.notes.contains { $0.contains("Notes.txt") })
        let coordinator = PlaylistImportCoordinator(persistence: fixture.storage.playlistMigrations)
        var committed = 0
        for candidate in report.candidates {
            do {
                let result = try await coordinator.commit(candidate, destinationName: candidate.name)
                committed += 1
                let entries = try await fixture.storage.playlistMigrations.entries(migrationID: result.session.id)
                assertOccurrenceInvariant(entries, source: try XCTUnwrap(candidate.source))
            } catch { XCTAssertNil(candidate.source, "A valid playlist failed: \(error)") }
        }
        XCTAssertEqual(committed, 2)
        let after = try ReleaseIntegritySnapshot.capture(fixture.storage.database.dbQueue, paths: fixture.paths)
        XCTAssertEqual(after.rows("playlist_migrations"), before.rows("playlist_migrations") + 2)
        XCTAssertEqual(after.rows("migration_entries"), before.rows("migration_entries") + 200)
        for table in ["tracks", "playlist_tracks", "liked_tracks"] { XCTAssertEqual(after.tables[table], before.tables[table]) }
        XCTAssertEqual(after.files, before.files)
    }
}
