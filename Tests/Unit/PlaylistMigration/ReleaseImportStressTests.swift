import Foundation
import GRDB
import XCTest
@testable import OFFLINE

/// Phase 10.9 import stress and occurrence-integrity gates (G04).
///
/// Deterministic CSV/JSON fixtures, no network. Every size runs the production path:
/// coordinated file staging → parser → import review → one IMMEDIATE transaction →
/// repository read-back → reopen from disk. Elapsed times are printed with the
/// `[Phase10.9]` prefix for the release report; they are observations, not gates.
final class ReleaseImportStressTests: XCTestCase {
    private typealias R = ReleaseImportFixtures

    private func fixtureWithOrdinaryLibrary() throws -> (LibraryFixture, StoredPlaylist) {
        let fixture = try LibraryFixture(count: 2)
        retainUntilTeardown(fixture)
        let ordinary = try fixture.repository.createPlaylist(name: "Ordinary")
        try fixture.repository.addTracks(fixture.ids, playlistID: ordinary.id)
        return (fixture, ordinary)
    }

    private func importFile(_ bytes: Data, named filename: String, into fixture: LibraryFixture, label: String) async throws -> (PlaylistImportCandidate, PlaylistImportCommit) {
        let url = fixture.paths.documents.appendingPathComponent(filename)
        try bytes.write(to: url)
        let (report, parseMs) = try await releaseMeasure { try await PlaylistImportFixtures.importer(fixture).prepare(file: url) }
        XCTAssertEqual(report.validCount, 1, "\(label): \(report.candidates.flatMap(\.diagnostics))")
        let candidate = try XCTUnwrap(report.candidates.first)
        let coordinator = PlaylistImportCoordinator(persistence: fixture.storage.playlistMigrations)
        let (commit, commitMs) = try await releaseMeasure { try await coordinator.commit(candidate, destinationName: candidate.name) }
        print("[Phase10.9] \(label): \(candidate.entryCount ?? -1) entries, \(bytes.count) bytes, stage+parse \(parseMs) ms, commit \(commitMs) ms")
        return (candidate, commit)
    }

    /// Small, medium, large, very large (mandatory 1,000) and extended (2,000) CSV imports.
    func testCSVImportsPreserveEveryDistinctOccurrenceInOrderFromTenToTwoThousandEntries() async throws {
        for size in [10, 100, 500, 1000, 2000] {
            let (fixture, ordinary) = try fixtureWithOrdinaryLibrary()
            let before = try ReleaseIntegritySnapshot.capture(fixture.storage.database.dbQueue, paths: fixture.paths)
            let repeats = size > 44 ? [19: 12, 44: 12] : [:]
            let (candidate, commit) = try await importFile(R.csv(size, repeats: repeats), named: "Stress \(size).csv", into: fixture, label: "CSV \(size)")
            let source = try XCTUnwrap(candidate.source)
            XCTAssertEqual(candidate.entryCount, size); XCTAssertEqual(source.entries.count, size)
            XCTAssertFalse(commit.existing)
            // The parser itself kept source order and identity.
            for (index, entry) in source.entries.enumerated() {
                let song = repeats[index] ?? index
                if entry.title != "Track \(String(format: "%05d", song))" || entry.sourceTrackID != R.trackID(song) {
                    XCTFail("CSV \(size): parsed entry \(index) is not source row \(index)"); break
                }
            }
            let repository = fixture.storage.playlistMigrations
            let entries = try await repository.entries(migrationID: commit.session.id)
            assertOccurrenceInvariant(entries, source: source)
            if size > 44 {
                // Position 12, 19 and 44 are the same recording and stay three occurrences.
                let same = [12, 19, 44].map { entries[$0] }
                XCTAssertEqual(Set(same.map(\.source.sourceTrackID)).count, 1)
                XCTAssertEqual(Set(same.map(\.id)).count, 3)
                XCTAssertEqual(same.map(\.position), [12, 19, 44])
            }
            XCTAssertTrue(entries.allSatisfy { $0.status == .pending && $0.localTrackID == nil }, "No audio is fabricated at import")
            let rows = try repository.rows(playlistID: XCTUnwrap(commit.session.destinationPlaylistID))
            XCTAssertEqual(rows.count, size, "Playlist read model shows every occurrence")

            // Reopening from disk (a relaunch) restores exactly the same occurrences.
            let reopened = try StorageCoordinator(paths: fixture.paths)
            let restored = try await reopened.playlistMigrations.entries(migrationID: commit.session.id)
            XCTAssertEqual(restored, entries)

            // The import added only its own playlist, session and occurrences.
            let after = try ReleaseIntegritySnapshot.capture(fixture.storage.database.dbQueue, paths: fixture.paths)
            for table in ["tracks", "playlist_tracks", "liked_tracks", "albums", "artists"] {
                XCTAssertEqual(after.tables[table], before.tables[table], "CSV \(size): \(table) changed")
            }
            XCTAssertEqual(after.files, before.files, "CSV \(size): managed files changed")
            XCTAssertEqual(after.rows("playlists"), before.rows("playlists") + 1)
            XCTAssertEqual(after.rows("playlist_migrations"), before.rows("playlist_migrations") + 1)
            XCTAssertEqual(after.rows("migration_entries"), before.rows("migration_entries") + size)
            XCTAssertEqual(try fixture.repository.snapshot().playlistTracks(ordinary.id).map(\.id), fixture.ids)
            XCTAssertEqual(try fixture.foreignKeys(), 0)
        }
    }

    /// Extended JSON account-data export through the same pipeline.
    func testTwoThousandEntryJSONExportKeepsTheSameInvariant() async throws {
        let (fixture, _) = try fixtureWithOrdinaryLibrary()
        let (candidate, commit) = try await importFile(R.json(2000), named: "Playlist1.json", into: fixture, label: "JSON 2000")
        let entries = try await fixture.storage.playlistMigrations.entries(migrationID: commit.session.id)
        assertOccurrenceInvariant(entries, source: try XCTUnwrap(candidate.source))
        XCTAssertEqual(entries.last?.source.title, "JSON 01999")
    }

    /// The supported maximum (10,000) is accepted whole; one more is rejected before any write.
    func testTenThousandEntryLimitIsAcceptedWholeAndOneMoreIsRejectedWithoutWrites() async throws {
        let (fixture, _) = try fixtureWithOrdinaryLibrary()
        let (candidate, commit) = try await importFile(R.csv(10_000), named: "Limit.csv", into: fixture, label: "CSV 10000")
        let entries = try await fixture.storage.playlistMigrations.entries(migrationID: commit.session.id)
        assertOccurrenceInvariant(entries, source: try XCTUnwrap(candidate.source))

        let before = try ReleaseIntegritySnapshot.capture(fixture.storage.database.dbQueue, paths: fixture.paths)
        let report = try PlaylistImportFixtures.parse(R.csv(10_001), filename: "Over.csv")
        XCTAssertEqual(report.validCount, 0)
        let rejected = try XCTUnwrap(report.candidates.first)
        XCTAssertNil(rejected.source); XCTAssertFalse(rejected.diagnostics.isEmpty)
        do {
            _ = try await PlaylistImportCoordinator(persistence: fixture.storage.playlistMigrations).commit(rejected, destinationName: "Over")
            XCTFail("An over-limit playlist was committed")
        } catch { XCTAssertTrue(error is PlaylistImportProblem) }
        XCTAssertEqual(try ReleaseIntegritySnapshot.capture(fixture.storage.database.dbQueue, paths: fixture.paths), before)
    }

    /// Three 500-entry playlists that share most recordings, committed at the same time from
    /// three database connections (the app, a background task and a retry). Each is complete
    /// and isolated; a fourth import cancelled before its transaction leaves nothing behind.
    func testConcurrentFiveHundredEntryImportsSharingRecordingsStayCompleteAndIsolated() async throws {
        let (fixture, ordinary) = try fixtureWithOrdinaryLibrary()
        let inputs: [(String, Data)] = [("A.csv", R.csv(500)), ("B.csv", R.csv(500, repeats: [0: 1, 250: 3])), ("C.csv", R.csv(500, prefix: "Mix"))]
        let candidates = try inputs.map { try XCTUnwrap(PlaylistImportFixtures.parse($0.1, filename: $0.0).candidates.first) }
        let sources = try candidates.map { try XCTUnwrap($0.source) }
        let operations = try candidates.map { try XCTUnwrap($0.operationID) }
        XCTAssertEqual(Set(operations).count, 3)
        let paths = fixture.paths
        let (sessions, elapsed) = try await releaseMeasure {
            try await withThrowingTaskGroup(of: (Int, PlaylistMigrationSession).self) { group in
                for index in 0..<3 {
                    let source = sources[index], operation = operations[index]
                    group.addTask {
                        let connection = try DatabaseManager(url: paths.database)
                        let repository = GRDBPlaylistMigrationRepository(db: connection.dbQueue, paths: paths)
                        let session = try repository.createCommittedPlaylist(from: source, operationID: operation, destinationName: "Concurrent \(index)")
                        return (index, session)
                    }
                }
                var result: [Int: PlaylistMigrationSession] = [:]
                for try await (index, session) in group { result[index] = session }
                return result
            }
        }
        print("[Phase10.9] 3 concurrent 500-entry imports on separate connections: \(elapsed) ms")
        XCTAssertEqual(Set(sessions.values.map(\.id)).count, 3)
        for index in 0..<3 {
            let session = try XCTUnwrap(sessions[index])
            let entries = try await fixture.storage.playlistMigrations.entries(migrationID: session.id)
            assertOccurrenceInvariant(entries, source: sources[index])
        }
        let doomed = try XCTUnwrap(PlaylistImportFixtures.parse(R.csv(500, prefix: "Cancelled"), filename: "D.csv").candidates.first)
        let persistence = fixture.storage.playlistMigrations
        let cancelled = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await PlaylistImportCoordinator(persistence: persistence).commit(doomed, destinationName: "Cancelled")
        }
        do { _ = try await cancelled.value; XCTFail("Cancelled import committed") } catch { XCTAssertTrue(error is CancellationError) }
        let snapshot = try ReleaseIntegritySnapshot.capture(fixture.storage.database.dbQueue, paths: fixture.paths)
        XCTAssertEqual(snapshot.rows("playlist_migrations"), 3)
        XCTAssertEqual(snapshot.rows("migration_entries"), 1500)
        XCTAssertEqual(snapshot.rows("playlists"), 4)
        XCTAssertEqual(try fixture.repository.snapshot().playlistTracks(ordinary.id).map(\.id), fixture.ids)
        XCTAssertEqual(try fixture.foreignKeys(), 0)
    }

    /// Importing the same export again (three times) reuses the first import: no extra
    /// occurrences, no overwrite of the user's rename, and a removed occurrence stays removed.
    func testRepeatedImportOfTheSameExportReusesItAndKeepsLocalEdits() async throws {
        let (fixture, _) = try fixtureWithOrdinaryLibrary()
        let bytes = R.csv(100, repeats: [60: 10])
        let (_, first) = try await importFile(bytes, named: "Weekly.csv", into: fixture, label: "CSV 100 (first import)")
        let playlistID = try XCTUnwrap(first.session.destinationPlaylistID)
        try fixture.repository.updatePlaylist(id: playlistID, name: "My renamed playlist", description: "")
        let repository = fixture.storage.playlistMigrations
        let original = try await repository.entries(migrationID: first.session.id)
        let removed = original[60]
        try await repository.removeOccurrence(entryID: removed.id, playlistID: playlistID)
        let edited = try ReleaseIntegritySnapshot.capture(fixture.storage.database.dbQueue, paths: fixture.paths)

        for attempt in 1...3 {
            let url = fixture.paths.documents.appendingPathComponent("Weekly.csv")
            let report = try await PlaylistImportFixtures.importer(fixture).prepare(file: url)
            let candidate = try XCTUnwrap(report.candidates.first)
            let review = try await PlaylistImportCoordinator(persistence: repository).review(report)
            XCTAssertEqual(review[candidate.id], .existing(first.session.id), "Attempt \(attempt) is recognized")
            let again = try await PlaylistImportCoordinator(persistence: repository).commit(candidate, destinationName: "Should not rename")
            XCTAssertTrue(again.existing); XCTAssertEqual(again.session.id, first.session.id)
        }
        XCTAssertEqual(try ReleaseIntegritySnapshot.capture(fixture.storage.database.dbQueue, paths: fixture.paths), edited,
                       "Repeated imports changed nothing")
        let entries = try await repository.entries(migrationID: first.session.id)
        XCTAssertEqual(entries.count, 99); XCTAssertFalse(entries.contains { $0.id == removed.id })
        XCTAssertTrue(entries.contains { $0.id == original[10].id }, "The other occurrence of the same song stays")
        XCTAssertEqual(try fixture.repository.snapshot().playlists.first(where: { $0.id == playlistID })?.name, "My renamed playlist")
    }

    /// The import works on a private staged copy: once review has the file, later changes
    /// to the original (a Files provider sync, an edit) cannot alter what is committed.
    func testSourceFileChangedAfterReviewDoesNotAlterTheCommittedPlaylist() async throws {
        let (fixture, _) = try fixtureWithOrdinaryLibrary()
        let url = fixture.paths.documents.appendingPathComponent("Changing.csv")
        try R.csv(100).write(to: url)
        let report = try await PlaylistImportFixtures.importer(fixture).prepare(file: url)
        let candidate = try XCTUnwrap(report.candidates.first)
        try R.csv(3, prefix: "Replaced").write(to: url, options: .atomic)
        let commit = try await PlaylistImportCoordinator(persistence: fixture.storage.playlistMigrations).commit(candidate, destinationName: "Changing")
        let entries = try await fixture.storage.playlistMigrations.entries(migrationID: commit.session.id)
        assertOccurrenceInvariant(entries, source: try XCTUnwrap(candidate.source))
        XCTAssertEqual(entries.count, 100)
        let staged = (try? FileManager.default.contentsOfDirectory(atPath: fixture.paths.imports.path)) ?? []
        XCTAssertFalse(staged.contains { $0.hasPrefix("playlist-import-") }, "Staging is removed after review")
    }
}
