import Foundation
import GRDB
import XCTest
@testable import OFFLINE

final class HybridPlaylistTests: XCTestCase {
    func testTwoHundredSourceEntriesPlusManualDuplicatesSurviveRestartAndRemoval() async throws {
        let f = try LibraryFixture(count: 2), repo = f.storage.playlistMigrations
        let input = MatchingCorrectionTests.source(200)
        let session = try await repo.createPlaylist(from: input, operationID: "hybrid")
        let id = try XCTUnwrap(session.destinationPlaylistID)
        try f.repository.addTracks([f.ids[0]], playlistID: id)
        var snapshot = try f.repository.snapshot()
        XCTAssertEqual(snapshot.migrationEntries.count, 200); XCTAssertEqual(snapshot.localOccurrences.count, 1)
        try f.repository.addTracks([f.ids[1], f.ids[0]], playlistID: id)
        snapshot = try f.repository.snapshot()
        XCTAssertEqual(snapshot.localOccurrences.map(\.trackID), [f.ids[0], f.ids[1], f.ids[0]])
        XCTAssertEqual(Set(snapshot.localOccurrences.map(\.id)).count, 3)
        XCTAssertEqual(snapshot.migrationEntries.map(\.source), input.entries)
        let audio = try repo.hybridPlaybackOccurrences(playlistID: id)
        XCTAssertEqual(audio.count, 3); XCTAssertEqual(Set(audio.map(\.id)).count, 3)
        let database = try DatabaseManager(url: f.paths.database), reopened = LibraryRepository(db: database.dbQueue)
        XCTAssertEqual(try reopened.snapshot().localOccurrences, snapshot.localOccurrences)
        try reopened.removeManualOccurrence(snapshot.localOccurrences[0].id, playlistID: id)
        XCTAssertEqual(try reopened.snapshot().localOccurrences.count, 2)
        XCTAssertTrue(FileManager.default.fileExists(atPath: try f.file(0).path))
        let preserved = try await repo.entries(migrationID: session.id)
        XCTAssertEqual(preserved.map(\.source), input.entries)
        let progress = try await repo.progress(migrationID: session.id)
        XCTAssertEqual(progress.actual, 200)
        XCTAssertEqual(try f.foreignKeys(), 0)
    }
    func testTrackDeletionCascadesOnlyManualMembershipAndOrdinaryPlaylistsKeepSetSemantics() async throws {
        let f = try LibraryFixture(count: 2), repo = f.storage.playlistMigrations
        let session = try await repo.createPlaylist(from: MatchingCorrectionTests.source(2), operationID: "delete")
        let id = try XCTUnwrap(session.destinationPlaylistID)
        try f.repository.addTracks([f.ids[0], f.ids[0]], playlistID: id)
        let ordinary = try f.repository.createPlaylist(name: "Ordinary")
        try f.repository.addTracks([f.ids[1], f.ids[1]], playlistID: ordinary.id)
        XCTAssertEqual(try f.repository.snapshot().playlistTracks(ordinary.id).count, 1)
        try await f.storage.database.dbQueue.write { db in _ = try StoredTrack.deleteOne(db, key: f.ids[0]) }
        XCTAssertTrue(try f.repository.snapshot().localOccurrences.isEmpty)
        let entries = try await repo.entries(migrationID: session.id)
        XCTAssertEqual(entries.count, 2); XCTAssertTrue(entries.allSatisfy { $0.localTrackID == nil })
    }
    @MainActor func testHybridPlaybackRestoresRepeatedOccurrenceIdentitiesAndRemoval() async throws {
        let f = try LibraryFixture(count: 2), repo = f.storage.playlistMigrations
        let session = try await repo.createPlaylist(from: MatchingCorrectionTests.source(2), operationID: "queue")
        let id = try XCTUnwrap(session.destinationPlaylistID)
        let sourceEntry = try await repo.entries(migrationID: session.id)[0]
        try await repo.associateVerifiedTrack(entryID: sourceEntry.id, trackID: f.ids[0])
        try f.repository.addTracks([f.ids[1], f.ids[0]], playlistID: id)
        let occurrences = try repo.hybridPlaybackOccurrences(playlistID: id)
        XCTAssertEqual(occurrences.count, 3)
        let queue = PlaybackQueueManager(storage: f.storage, makeShuffle: { $0 })
        queue.setMigrationContext(occurrences, selected: occurrences[2].id)
        queue.didStart(occurrences[2].trackID)
        queue.persistState(currentTrackID: occurrences[2].trackID, positionMs: 100, sleepDeadline: nil, sleepTimerDuration: nil, contextKind: "migrationPlaylist", contextSourceID: id)
        let restored = PlaybackQueueManager(storage: f.storage, makeShuffle: { $0 })
        XCTAssertEqual(restored.migrationContext?.occurrences, occurrences)
        XCTAssertEqual(restored.currentOccurrenceID, occurrences[2].id)
        let manual = try f.repository.snapshot().localOccurrences
        try f.repository.removeManualOccurrence(manual[1].id, playlistID: id)
        let afterRemoval = PlaybackQueueManager(storage: f.storage)
        XCTAssertEqual(afterRemoval.migrationContext?.occurrences.count, 2)
        XCTAssertFalse(afterRemoval.migrationContext?.occurrences.contains { $0.id == occurrences[2].id } ?? true)
    }
    func testUpgradeFromV013AddsTablesWithoutRewritingSourceOrPlayback() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = try AppStoragePaths(root: root)
        let old = try DatabaseManager(url: paths.database, migrationTarget: "v013_playlist_migration_storage")
        let repo = GRDBPlaylistMigrationRepository(db: old.dbQueue, paths: paths), input = MatchingCorrectionTests.source(200)
        let session = try await repo.createPlaylist(from: input, operationID: "upgrade")
        let upgraded = try DatabaseManager(url: paths.database)
        let upgradedRepo = GRDBPlaylistMigrationRepository(db: upgraded.dbQueue, paths: paths)
        let entries = try await upgradedRepo.entries(migrationID: session.id)
        XCTAssertEqual(entries.map(\.source), input.entries)
        let saved = try await upgradedRepo.session(id: session.id)
        XCTAssertEqual(saved, session)
        let migrations = try await upgraded.dbQueue.read { try String.fetchAll($0, sql: "SELECT identifier FROM grdb_migrations ORDER BY identifier") }
        XCTAssertEqual(migrations.count, 14); XCTAssertEqual(migrations.last, "v014_matching_recovery_hybrid_playlists")
    }
    func testExplicitResolutionDoesNotAppendManualOccurrence() async throws {
        let f = try LibraryFixture(count: 1), repo = f.storage.playlistMigrations
        let input = MatchingCorrectionTests.source(1), session = try await repo.createPlaylist(from: input, operationID: "resolve")
        let entry = try await repo.entries(migrationID: session.id)[0]
        try await repo.confirmLocalRecording(for: entry, trackID: f.ids[0])
        let after = try await repo.entries(migrationID: session.id)[0], candidates = try await repo.candidates(entryID: entry.id)
        XCTAssertEqual(after.source, entry.source); XCTAssertEqual(after.status, .ready)
        XCTAssertTrue(try f.repository.snapshot().localOccurrences.isEmpty)
        XCTAssertEqual(candidates.first?.decision, .accepted)
        XCTAssertEqual(candidates.first?.evidence["matchingAlgorithmVersion"], "manual-10.4")
    }
}
