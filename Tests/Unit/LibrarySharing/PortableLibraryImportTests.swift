import Foundation
import GRDB
import XCTest
@testable import OFFLINE

/// Phase 11.4 import: preview, duplicate protection, atomic and idempotent commit,
/// local-first reuse and strict reference acceptance.
final class PortableLibraryImportTests: XCTestCase {
    private typealias F = PortableFixtures

    private func fixture(_ count: Int = 3) throws -> LibraryFixture {
        let value = try LibraryFixture(count: count)
        retainUntilTeardown(value)
        return value
    }

    private func repository(_ fixture: LibraryFixture) -> PortableLibraryImportRepository {
        PortableLibraryImportRepository(db: fixture.storage.database.dbQueue)
    }

    private func commit(_ fixture: LibraryFixture, _ preview: PortableImportPreview, unassigned: Bool = false,
                        automatic: Bool = false, selections: [String: PortableImportSelection]? = nil) async throws -> PortableImportCommit {
        let request = PortableImportRequest(preview: preview, selections: selections ?? preview.defaultSelections,
                                            includeUnassigned: unassigned, automaticAcquisition: automatic)
        return try await repository(fixture).commit(preview, request: request)
    }

    private func playlistCount(_ fixture: LibraryFixture) throws -> Int {
        try fixture.storage.database.dbQueue.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM playlists") ?? 0 }
    }

    func testCommitCreatesPlaylistsWithExactOrderRepeatsAndNativeSource() async throws {
        let fixture = try fixture()
        let document = F.document(songs: [F.song("s1", "Alpha"), F.song("s2", "Beta", videos: [F.videoA])],
                                  playlists: [F.playlist("p1", "Shared Mix", ["s2", "s1", "s2"])])
        let preview = try await F.preview(fixture, document)
        XCTAssertEqual(preview.playlists.first?.duplicate, PortableDuplicate.none)
        let result = try await commit(fixture, preview)
        XCTAssertEqual(result.migrationIDs.count, 1)
        let session = try await fixture.storage.playlistMigrations.session(id: result.migrationIDs[0])
        XCTAssertEqual(session?.source, .muzikBelesh)
        XCTAssertEqual(session?.status, .metadataReady)
        let entries = try await fixture.storage.playlistMigrations.entries(migrationID: result.migrationIDs[0])
        XCTAssertEqual(entries.map(\.source.title), ["Beta", "Alpha", "Beta"])
        XCTAssertTrue(entries.allSatisfy { $0.status == .pending && $0.localTrackID == nil })
        let rows = try F.entries(fixture, importID: result.importID)
        XCTAssertEqual(Set(rows.map(\.record.songRef)), ["s1", "s2"])
        XCTAssertEqual(rows.first { $0.record.songRef == "s2" }?.record.videoIDs, [F.videoA])
        XCTAssertEqual(try fixture.foreignKeys(), 0)
    }

    func testRepeatingTheSameConfirmationIsIdempotentAndChangedChoicesConflict() async throws {
        let fixture = try fixture()
        let preview = try await F.preview(fixture, F.document(songs: [F.song("s1", "Alpha")], playlists: [F.playlist("p1", "Mix", ["s1"])]))
        let first = try await commit(fixture, preview)
        let before = try playlistCount(fixture)
        let again = try await commit(fixture, preview)
        XCTAssertTrue(again.reused)
        XCTAssertEqual(again.migrationIDs, first.migrationIDs)
        XCTAssertEqual(try playlistCount(fixture), before, "No duplicate playlists from a repeated confirmation")
        do {
            _ = try await commit(fixture, preview, automatic: true)
            XCTFail("The same operation with different choices must not be applied")
        } catch { XCTAssertEqual(error as? PortableLibraryError, .operationConflict) }
    }

    func testIdenticalContentIsDetectedAndSkippedByDefaultButCanBeImportedAsACopy() async throws {
        let fixture = try fixture()
        let local = try fixture.repository.createPlaylist(name: "Favourites")
        try fixture.repository.addTracks([fixture.ids[0], fixture.ids[1]], playlistID: local.id)
        let exported = try await PortableLibraryExporter(db: fixture.storage.database.dbQueue).plan(.playlist(local.id))
        var renamed = exported.document
        renamed.collection.playlists[0].name = "Something Else"
        let preview = try await F.preview(fixture, renamed)
        guard case .identical(let existing) = preview.playlists[0].duplicate else { return XCTFail("\(preview.playlists[0].duplicate)") }
        XCTAssertEqual(existing, "Favourites")
        XCTAssertEqual(preview.defaultSelections[preview.playlists[0].id]?.included, false)
        XCTAssertEqual(preview.alreadyAvailable + preview.likelyAvailable, 0, "Fixture tracks have no artist, so no claimed match")
        do { _ = try await commit(fixture, preview); XCTFail("Nothing selected") }
        catch { XCTAssertEqual(error as? PortableLibraryError, .nothingSelected) }
        var copy = preview.defaultSelections
        copy[preview.playlists[0].id]?.included = true
        let result = try await commit(fixture, preview, selections: copy)
        XCTAssertEqual(result.playlistIDs.count, 1)
        XCTAssertEqual(try playlistCount(fixture), 2, "The existing playlist is never overwritten")
    }

    func testSameNameDifferentContentIsImportedUnderANewName() async throws {
        let fixture = try fixture()
        try fixture.repository.createPlaylist(name: "Mix")
        let preview = try await F.preview(fixture, F.document(songs: [F.song("s1", "Alpha")], playlists: [F.playlist("p1", "Mix", ["s1"])]))
        XCTAssertEqual(preview.playlists[0].duplicate, .sameName)
        XCTAssertEqual(preview.defaultSelections["p1"]?.name, "Mix (2)")
        let result = try await commit(fixture, preview)
        let name = try await fixture.storage.database.dbQueue.read { try String.fetchOne($0, sql: "SELECT name FROM playlists WHERE id = ?", arguments: [result.playlistIDs[0]]) }
        XCTAssertEqual(name, "Mix (2)")
    }

    func testSelectiveImportRenameAndUnassignedCollection() async throws {
        let fixture = try fixture()
        let document = F.document(songs: [F.song("s1", "Alpha"), F.song("s2", "Beta"), F.song("s3", "Loose")],
                                  playlists: [F.playlist("p1", "Keep", ["s1"]), F.playlist("p2", "Skip", ["s2"])])
        let preview = try await F.preview(fixture, document)
        XCTAssertEqual(preview.unassignedSongs, 1)
        var selections = preview.defaultSelections
        selections["p1"]?.name = "Kept Renamed"
        selections["p2"]?.included = false
        let result = try await commit(fixture, preview, unassigned: true, selections: selections)
        let names = try await fixture.storage.database.dbQueue.read { db in
            try result.playlistIDs.map { try String.fetchOne(db, sql: "SELECT name FROM playlists WHERE id = ?", arguments: [$0]) }
        }
        XCTAssertEqual(names, ["Kept Renamed", PortableImportNames.unassignedCollection])
        let kinds = try await fixture.storage.database.dbQueue.read { try String.fetchAll($0, sql: "SELECT kind FROM portable_library_import_items ORDER BY ordinal") }
        XCTAssertEqual(kinds, ["playlist", "standaloneSongs"])
    }

    func testFailedCommitLeavesTheLibraryUnchanged() async throws {
        let fixture = try fixture()
        let preview = try await F.preview(fixture, F.document(songs: [F.song("s1", "Alpha")],
            playlists: [F.playlist("p1", "Good", ["s1"]), F.playlist("p2", "Bad", ["s1"], prefix: "q")]))
        var selections = preview.defaultSelections
        selections["p2"]?.name = "   "
        let before = try playlistCount(fixture)
        do { _ = try await commit(fixture, preview, selections: selections); XCTFail("Invalid name must refuse the whole import") }
        catch { XCTAssertNotNil(error as? PortableLibraryError) }
        XCTAssertEqual(try playlistCount(fixture), before)
        let imports = try await fixture.storage.database.dbQueue.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM portable_library_imports") }
        XCTAssertEqual(imports, 0)
    }

    func testProvenanceReusesTheExactLocalRecordingForEveryOccurrence() async throws {
        let fixture = try fixture()
        try F.addSource(fixture, trackID: fixture.ids[1], video: F.videoA)
        let document = F.document(songs: [F.song("s1", "Different Title On Sender", videos: [F.videoA]), F.song("s2", "Unknown")],
                                  playlists: [F.playlist("p1", "Mix", ["s1", "s2", "s1"])])
        let preview = try await F.preview(fixture, document)
        XCTAssertEqual(preview.alreadyAvailable, 1)
        let result = try await commit(fixture, preview)
        let metadata = PortableStubMetadata([])
        let report = try await PortableImportReconciler(db: fixture.storage.database.dbQueue, migrations: fixture.storage.playlistMigrations,
                                                        metadata: metadata).run(importID: result.importID)
        XCTAssertEqual(report.provenance, 2)
        XCTAssertEqual(metadata.requestCount, 0, "Without automatic acquisition nothing is looked up")
        let rows = try F.entries(fixture, importID: result.importID)
        for row in rows where row.record.songRef == "s1" {
            XCTAssertEqual(row.entry.status, .ready); XCTAssertEqual(row.entry.localTrackID, fixture.ids[1])
            XCTAssertEqual(row.record.resolution, .provenance)
        }
        XCTAssertEqual(rows.first { $0.record.songRef == "s2" }?.entry.status, .pending)
        let phase = try await fixture.storage.database.dbQueue.read { try String.fetchOne($0, sql: "SELECT phase FROM portable_library_imports") }
        XCTAssertEqual(phase, "handedOff")
        let progress = try await fixture.storage.database.dbQueue.read { try PortableLibraryImportRepository.progress($0, importID: result.importID) }
        XCTAssertEqual(progress.songs, 2); XCTAssertEqual(progress.available, 1); XCTAssertEqual(progress.reusedLocally, 1)
        XCTAssertEqual(progress.occurrences, 3)
    }

    func testLocalMetadataReuseFollowsTheEstablishedPolicyExactly() async throws {
        let fixture = try fixture()
        try F.setArtist(fixture, trackID: fixture.ids[0], name: "Exact Artist")
        let track = try await fixture.storage.database.dbQueue.read { try XCTUnwrap(StoredTrack.fetchOne($0, key: fixture.ids[0])) }
        let document = F.document(songs: [F.song("s1", track.title, artist: "Exact Artist", duration: track.durationMs)],
                                  playlists: [F.playlist("p1", "Mix", ["s1"])])
        let result = try await commit(fixture, try await F.preview(fixture, document))
        let before = try F.entries(fixture, importID: result.importID)[0].entry
        let index = try await fixture.storage.playlistMigrations.matchingLibrary()
        let local = index.candidates(for: before.source)
        let expected = MatchDecisionPolicy().decide(local.values.map { CandidateScoringEngine().score(source: before.source, candidate: $0) }, truncated: local.truncated)
        try await PortableImportReconciler(db: fixture.storage.database.dbQueue, migrations: fixture.storage.playlistMigrations, metadata: nil)
            .run(importID: result.importID)
        let after = try F.entries(fixture, importID: result.importID)[0]
        if expected.outcome == .local {
            XCTAssertEqual(after.entry.status, .ready); XCTAssertEqual(after.entry.localTrackID, fixture.ids[0])
            XCTAssertEqual(after.record.resolution, .localMatch)
        } else {
            XCTAssertNil(after.entry.localTrackID, "A non-local decision is never committed by the importer")
            XCTAssertEqual(after.record.resolution, .deferred)
        }
    }

    func testSharedReferenceIsAcceptedOnlyWhenTheStrictPolicyRecommendsIt() async throws {
        let fixture = try fixture()
        let good = YouTubeVideo(id: F.videoA, title: "Real Artist - Real Song", channel: "Real Artist", channelID: nil, thumbnailURL: nil,
                                duration: 200, availability: .available)
        let bad = YouTubeVideo(id: F.videoB, title: "Completely Unrelated Cooking Video", channel: "Kitchen", channelID: nil, thumbnailURL: nil,
                               duration: 900, availability: .available)
        let document = F.document(songs: [F.song("s1", "Real Song", artist: "Real Artist", duration: 200_000, videos: [F.videoA]),
                                          F.song("s2", "Another Song", artist: "Another Artist", duration: 180_000, videos: [F.videoB])],
                                  playlists: [F.playlist("p1", "Mix", ["s1", "s2"])])
        let result = try await commit(fixture, try await F.preview(fixture, document), automatic: true)
        let metadata = PortableStubMetadata([good, bad])
        let report = try await PortableImportReconciler(db: fixture.storage.database.dbQueue, migrations: fixture.storage.playlistMigrations,
                                                        metadata: metadata, pacer: MatchingRequestPacer(interval: .zero)).run(importID: result.importID)
        XCTAssertEqual(metadata.requestCount, 2)
        let rows = try F.entries(fixture, importID: result.importID)
        for row in rows {
            let video = row.record.songRef == "s1" ? good : bad
            let recommended = GRDBPlaylistMigrationRepository.portableReferenceRecommended(for: row.entry, video: video)
            let candidates = try await F.candidates(fixture, entryID: row.entry.id)
            if recommended {
                XCTAssertEqual(row.entry.status, .matched)
                XCTAssertEqual(candidates.filter { $0.decision == .accepted }.map(\.providerTrackID), [video.id])
                XCTAssertEqual(row.record.resolution, .reference)
            } else {
                XCTAssertTrue(candidates.allSatisfy { $0.decision != .accepted }, "An unreliable reference is never auto-accepted")
                XCTAssertEqual(candidates.filter { $0.decision == .pending }.map(\.providerTrackID), [video.id])
                XCTAssertEqual(row.record.resolution, .proposed)
            }
        }
        XCTAssertFalse(GRDBPlaylistMigrationRepository.portableReferenceRecommended(for: rows.first { $0.record.songRef == "s2" }!.entry, video: bad))
        XCTAssertEqual(report.references + report.proposed, 2)
    }

    func testReconcilerResumesAfterInterruptionWithoutRepeatingWork() async throws {
        let fixture = try fixture()
        try F.addSource(fixture, trackID: fixture.ids[0], video: F.videoA)
        let document = F.document(songs: [F.song("s1", "One", videos: [F.videoA])], playlists: [F.playlist("p1", "Mix", ["s1"])])
        let result = try await commit(fixture, try await F.preview(fixture, document))
        // A relaunch mid-reconciliation leaves the phase at `reconciling`.
        try await repository(fixture).setPhase(result.importID, .reconciling)
        let unfinished = try await repository(fixture).unfinishedImports()
        XCTAssertEqual(unfinished.map(\.id), [result.importID])
        let reconciler = PortableImportReconciler(db: fixture.storage.database.dbQueue, migrations: fixture.storage.playlistMigrations, metadata: nil)
        let first = try await reconciler.run(importID: result.importID)
        let second = try await reconciler.run(importID: result.importID)
        XCTAssertEqual(first.provenance, 1)
        XCTAssertEqual(second, PortableImportReconciler.Report(), "A handed-off import is not reconciled again")
        let unfinishedAfter = try await repository(fixture).unfinishedImports()
        XCTAssertTrue(unfinishedAfter.isEmpty)
    }

    func testLargeImportCommitsAtThePerPlaylistLimit() async throws {
        let fixture = try fixture(1)
        let count = PortableLibraryLimits.occurrencesPerPlaylist
        let songs = (0..<count).map { F.song("s\($0)", "Song number \($0)", artist: "Artist \($0 % 50)") }
        let document = F.document(songs: songs, playlists: [F.playlist("p1", "Huge", songs.map(\.id))])
        let started = Date()
        let preview = try await F.preview(fixture, document)
        let result = try await commit(fixture, preview)
        // Recorded for the delivery report; not a pass/fail threshold.
        print("PERF portable preview+commit \(count) occurrences: \(Date().timeIntervalSince(started))s")
        let entries = try await fixture.storage.playlistMigrations.entries(migrationID: result.migrationIDs[0])
        XCTAssertEqual(entries.count, count)
        XCTAssertEqual(entries.map(\.position), Array(0..<count))
    }
}
