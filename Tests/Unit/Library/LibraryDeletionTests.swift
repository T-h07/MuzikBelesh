import XCTest
import GRDB
import MediaPlayer
@testable import OFFLINE

final class LibraryDeletionTests: XCTestCase {
    func testDeletionRequiresExplicitConfirmation() throws {
        let f = try LibraryFixture(); let bytes = try Data(contentsOf: f.file(0))
        XCTAssertThrowsError(try ManagedLibraryFiles.deleteTrack(f.ids[0], confirmed: false, paths: f.paths, db: f.storage.database.dbQueue))
        XCTAssertEqual(try f.storage.tracks.all().count, 4); XCTAssertEqual(try Data(contentsOf: f.file(0)), bytes)
        XCTAssertEqual(try f.storage.database.dbQueue.read { try ManagedFileOperation.fetchAll($0).count }, 0)
    }
    func testPermanentDeletionCleansAllRelationshipsAndPreservesOtherBytes() throws {
        let f = try LibraryFixture(); let p = try f.repository.createPlaylist(name: "A")
        try f.repository.addTracks(f.ids, playlistID: p.id); try f.repository.setLiked(true, trackID: f.ids[0])
        try f.storage.playback.replaceQueue([StoredQueueEntry(id: "q0", trackID: f.ids[0], position: 0, dateAdded: Date()), StoredQueueEntry(id: "q1", trackID: f.ids[1], position: 1, dateAdded: Date())])
        try f.storage.playback.addHistory(StoredHistoryEntry(id: "h", trackID: f.ids[0], startedAt: Date(), completedAt: nil, durationListenedMs: nil, source: "test"))
        try f.storage.database.dbQueue.write { db in
            try LibraryRepository.recordSource(trackID: f.ids[0], type: "test", identifier: "source", db: db)
            try StoredDownloadJob(id: "job", sourceType: "test", sourceIdentifier: nil, trackID: f.ids[0], state: .completed, progress: 1, errorMessage: nil, quality: "test", dateAdded: Date(), dateModified: Date()).insert(db)
        }
        let other = try Data(contentsOf: f.file(1))
        let result = try ManagedLibraryFiles.deleteTrack(f.ids[0], confirmed: true, paths: f.paths, db: f.storage.database.dbQueue)
        XCTAssertFalse(result.cleanupPending); XCTAssertNil(try f.storage.tracks.find(id: f.ids[0]))
        XCTAssertFalse(FileManager.default.fileExists(atPath: try f.file(0).path)); XCTAssertEqual(try Data(contentsOf: f.file(1)), other)
        let snapshot = try f.repository.snapshot()
        XCTAssertFalse(snapshot.likedIDs.contains(f.ids[0])); XCTAssertEqual(snapshot.playlistTracks(p.id).map(\.id), Array(f.ids.dropFirst()))
        XCTAssertEqual(snapshot.memberships.map(\.position), [0, 1, 2]); XCTAssertEqual(try f.storage.playback.queue().map(\.trackID), [f.ids[1]])
        XCTAssertEqual(try f.storage.playback.queue().first?.position, 0); XCTAssertTrue(try f.storage.playback.history(limit: 10).isEmpty)
        XCTAssertEqual(try f.storage.database.dbQueue.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM track_sources") }, 0)
        XCTAssertNil(try f.storage.downloads.all().first?.trackID); XCTAssertEqual(try f.foreignKeys(), 0)
    }
    func testFailuresBeforeCommitRestoreFileAndAllDatabaseReferences() throws {
        for point in [LibraryFileFault.afterStage, .beforeCommit] {
            let f = try LibraryFixture(); let p = try f.repository.createPlaylist(name: "Keep"); try f.repository.addTracks(f.ids, playlistID: p.id)
            try f.repository.setLiked(true, trackID: f.ids[0]); let before = try f.repository.snapshot(); let bytes = try Data(contentsOf: f.file(0))
            XCTAssertThrowsError(try ManagedLibraryFiles.deleteTrack(f.ids[0], confirmed: true, paths: f.paths, db: f.storage.database.dbQueue, fault: { if $0 == point { throw LibraryError.operationFailed } }))
            XCTAssertEqual(try f.repository.snapshot(), before); XCTAssertEqual(try Data(contentsOf: f.file(0)), bytes)
            XCTAssertEqual(try f.storage.database.dbQueue.read { try ManagedFileOperation.fetchAll($0).count }, 0)
            XCTAssertEqual(try f.foreignKeys(), 0)
        }
    }
    func testCommittedDeletionRecoveryFinalizesDurableStaging() throws {
        let f = try LibraryFixture()
        let result = try ManagedLibraryFiles.deleteTrack(f.ids[0], confirmed: true, paths: f.paths, db: f.storage.database.dbQueue, fault: { if $0 == .afterCommit { throw LibraryError.operationFailed } })
        XCTAssertTrue(result.cleanupPending); XCTAssertNil(try f.storage.tracks.find(id: f.ids[0]))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: f.paths.deletions.path).count, 1)
        let reopened = try StorageCoordinator(paths: f.paths)
        XCTAssertEqual(try reopened.tracks.all().count, 3)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: f.paths.deletions.path).isEmpty)
        XCTAssertEqual(try reopened.database.dbQueue.read { try ManagedFileOperation.fetchAll($0).count }, 0)
    }
    func testPreparedDeletionAfterCrashRestoresOriginalBeforeMissingReconciliation() throws {
        let f = try LibraryFixture(); let original = try f.file(0); let bytes = try Data(contentsOf: original)
        let operation = ManagedFileOperation(id: UUID().uuidString, kind: "delete-track", ownerID: f.ids[0], originalPath: original.lastPathComponent, stagedPath: "\(UUID().uuidString).wav", state: "prepared", dateUpdated: Date())
        try f.storage.database.dbQueue.write { try operation.insert($0) }
        try FileManager.default.moveItem(at: original, to: f.paths.relativeURL(operation.stagedPath, in: f.paths.deletions))
        let reopened = try StorageCoordinator(paths: f.paths)
        XCTAssertEqual(try Data(contentsOf: original), bytes); XCTAssertEqual(try reopened.tracks.find(id: f.ids[0])?.availability, .available)
        XCTAssertEqual(try reopened.database.dbQueue.read { try ManagedFileOperation.fetchAll($0).count }, 0)
    }
    func testRecoveryCollisionPreservesBothDifferentCopiesAndJournal() throws {
        let f = try LibraryFixture(); let original = try f.file(0); let old = try Data(contentsOf: original)
        let operation = ManagedFileOperation(id: UUID().uuidString, kind: "delete-track", ownerID: f.ids[0], originalPath: original.lastPathComponent, stagedPath: "\(UUID().uuidString).wav", state: "prepared", dateUpdated: Date())
        try f.storage.database.dbQueue.write { try operation.insert($0) }
        let staged = try f.paths.relativeURL(operation.stagedPath, in: f.paths.deletions)
        try FileManager.default.moveItem(at: original, to: staged); try Data([9, 8, 7]).write(to: original)
        XCTAssertThrowsError(try ManagedLibraryFiles.recover(paths: f.paths, db: f.storage.database.dbQueue))
        XCTAssertEqual(try Data(contentsOf: staged), old); XCTAssertEqual(try Data(contentsOf: original), Data([9, 8, 7]))
        XCTAssertEqual(try f.storage.database.dbQueue.read { try ManagedFileOperation.fetchAll($0).count }, 1)
    }
    func testRemovingMissingEntryPreservesUnrelatedTracks() throws {
        let f = try LibraryFixture(); try FileManager.default.removeItem(at: f.file(0)); try f.storage.reconcileMissingFiles()
        XCTAssertEqual(try f.storage.tracks.find(id: f.ids[0])?.availability, .missing)
        _ = try ManagedLibraryFiles.deleteTrack(f.ids[0], confirmed: true, paths: f.paths, db: f.storage.database.dbQueue)
        XCTAssertEqual(try f.storage.tracks.all().count, 3); XCTAssertTrue(FileManager.default.fileExists(atPath: try f.file(1).path))
    }
    func testSharedAudioPathIsNotDeletedWhileAnotherTrackReferencesIt() throws {
        let f = try LibraryFixture(); let original = try Data(contentsOf: f.file(0))
        var other = try XCTUnwrap(f.storage.tracks.find(id: f.ids[1])); other.fileRelativePath = "\(f.ids[0]).wav"; try f.storage.tracks.save(other)
        _ = try ManagedLibraryFiles.deleteTrack(f.ids[0], confirmed: true, paths: f.paths, db: f.storage.database.dbQueue)
        XCTAssertEqual(try Data(contentsOf: f.file(0)), original); XCTAssertNotNil(try f.storage.tracks.find(id: f.ids[1]))
    }
    func testInvalidAndSymlinkPathsCannotDeleteExternalFiles() throws {
        let f = try LibraryFixture(); let outside = f.root.appendingPathComponent("outside.wav"); try Data([1, 2, 3]).write(to: outside)
        var track = try XCTUnwrap(f.storage.tracks.find(id: f.ids[0])); track.fileRelativePath = "../outside.wav"; try f.storage.tracks.save(track)
        XCTAssertThrowsError(try ManagedLibraryFiles.deleteTrack(track.id, confirmed: true, paths: f.paths, db: f.storage.database.dbQueue))
        let link = f.paths.music.appendingPathComponent("escape.wav"); try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
        track.fileRelativePath = "escape.wav"; try f.storage.tracks.save(track)
        XCTAssertThrowsError(try ManagedLibraryFiles.deleteTrack(track.id, confirmed: true, paths: f.paths, db: f.storage.database.dbQueue))
        XCTAssertEqual(try Data(contentsOf: outside), Data([1, 2, 3])); XCTAssertNotNil(try f.storage.tracks.find(id: track.id))
    }
    @MainActor func testDeletingCurrentTrackStopsTransportAndPreservesOtherQueueOccurrencesAndTimer() async throws {
        let f = try LibraryFixture(); let (player, transport, library) = f.services()
        try await player.play(trackID: f.ids[0]); player.queue.addToQueue(trackID: f.ids[0]); player.queue.addToQueue(trackID: f.ids[1]); player.queue.addToQueue(trackID: f.ids[1])
        player.sleepTimer.start(minutes: 5); let deadline = player.sleepTimer.deadline
        _ = try await library.deleteTrack(id: f.ids[0], confirmed: true)
        XCTAssertFalse(transport.isPlaying); XCTAssertNil(player.state.currentTrackID); XCTAssertEqual(player.state.status, .idle)
        XCTAssertEqual(player.queue.entries.map(\.trackID), [f.ids[1], f.ids[1]]); XCTAssertEqual(player.sleepTimer.deadline, deadline)
        XCTAssertNil(MPNowPlayingInfoCenter.default().nowPlayingInfo)
        await player.next(); XCTAssertEqual(player.state.currentTrackID, f.ids[1]); XCTAssertTrue(transport.isPlaying)
    }
    @MainActor func testDeletingOtherTrackPreservesCurrentItemPositionAndValidSnapshot() async throws {
        let f = try LibraryFixture(); let (player, transport, library) = f.services()
        try await player.play(trackID: f.ids[0], contextTrackIDs: f.ids, contextKind: "playlist", contextSourceID: "snapshot")
        await player.seek(to: 0.5); let generation = player.activeItemGeneration; let replacements = transport.replacements
        _ = try await library.deleteTrack(id: f.ids[1], confirmed: true)
        XCTAssertEqual(player.activeItemGeneration, generation); XCTAssertEqual(transport.replacements, replacements)
        XCTAssertEqual(player.state.elapsedTime, 0.5); XCTAssertTrue(transport.isPlaying)
        XCTAssertEqual(player.queue.contextTrackIDs, [f.ids[0], f.ids[2], f.ids[3]])
        let saved = try XCTUnwrap(f.storage.playback.state()); XCTAssertFalse(saved.contextTrackIDsJSON?.contains(f.ids[1]) ?? true)
        XCTAssertEqual(try f.foreignKeys(), 0)
    }
}
