import Foundation
import GRDB
import XCTest
@testable import OFFLINE

final class PlaylistMigrationPersistenceTests: XCTestCase {
    private func source(_ count: Int, name: String = "Source playlist") -> PlaylistMigrationSourcePlaylist {
        PlaylistMigrationSourcePlaylist(source: .exportify, name: name, sourcePlaylistID: "same-playlist", entries: (0..<count).map {
            PlaylistMigrationSourceTrack(position: $0, title: "Source song \($0 % 3)", primaryArtist: "Original artist", additionalArtists: ["Guest"], album: "Original album", durationMs: 180000, sourceTrackID: "repeated-recording", sourceURI: "spotify:track:repeated-recording", artworkURL: URL(string: "https://example.com/art.jpg"))
        })
    }
    private func count(_ table: String, _ fixture: LibraryFixture) throws -> Int {
        try fixture.storage.database.dbQueue.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM \(table)")! }
    }
    private func fails<E: Error & Equatable>(_ expected: E, _ action: () async throws -> Void, file: StaticString = #filePath, line: UInt = #line) async {
        do { try await action(); XCTFail("Expected \(expected)", file: file, line: line) }
        catch { XCTAssertEqual(error as? E, expected, file: file, line: line) }
    }

    func testFreshSchemaAndReopeningHaveExactlyThirteenMigrations() throws {
        let f = try LibraryFixture(count: 0)
        XCTAssertEqual(try count("grdb_migrations", f), 13)
        for table in ["playlist_migrations", "migration_entries", "migration_candidates", "migration_issues"] { XCTAssertEqual(try count(table, f), 0) }
        let reopened = try DatabaseManager(url: f.paths.database)
        let migrations = try reopened.dbQueue.read { try String.fetchAll($0, sql: "SELECT identifier FROM grdb_migrations ORDER BY identifier") }
        XCTAssertEqual(migrations.count, 13); XCTAssertEqual(migrations.last, "v013_playlist_migration_storage")
        XCTAssertEqual(try f.foreignKeys(), 0)
    }

    func testUpgradeFromReleasedV012PreservesLibraryQueueHistoryAndState() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = try AppStoragePaths(root: root)
        let old = try DatabaseManager(url: paths.database, migrationTarget: "v012_background_transfers")
        let now = Date()
        try old.dbQueue.write { db in
            try StoredTrack(id: "local", title: "Keep", artistID: nil, albumID: nil, durationMs: 2000, fileRelativePath: "keep.wav", fileExtension: "wav", fileSizeBytes: 123, contentSHA256: "hash", artworkRelativePath: nil, availability: .available, dateAdded: now, dateModified: now, originalFilename: nil, metadataSource: "test").insert(db)
            try StoredPlaylist(id: "legacy", name: "Keep playlist", description: nil, artworkRelativePath: nil, dateAdded: now, dateModified: now).insert(db)
            try db.execute(sql: "INSERT INTO playlist_tracks VALUES ('legacy','local',0,?)", arguments: [now])
            try StoredLikedTrack(trackID: "local", dateLiked: now).insert(db)
            try StoredQueueEntry(id: "queue", trackID: "local", position: 0, dateAdded: now).insert(db)
            try StoredHistoryEntry(id: "history", trackID: "local", startedAt: now, completedAt: nil, durationListenedMs: 100, source: "legacy").insert(db)
            try db.execute(sql: "INSERT INTO playback_state(scope,currentTrackID,positionMs,shuffleEnabled,repeatMode,dateModified) VALUES ('default','local',123,0,'all',?)", arguments: [now])
        }
        let upgraded = try DatabaseManager(url: paths.database)
        let snapshot = try LibraryRepository(db: upgraded.dbQueue).snapshot()
        XCTAssertEqual(snapshot.playlistTracks("legacy").map(\.id), ["local"]); XCTAssertEqual(snapshot.likedIDs, ["local"])
        let playback = GRDBPlaybackRepository(db: upgraded.dbQueue)
        XCTAssertEqual(try playback.state()?.positionMs, 123); XCTAssertNil(try playback.state()?.migrationContextJSON)
        XCTAssertEqual(try playback.queue().map(\.id), ["queue"]); XCTAssertEqual(try playback.history(limit: 10).map(\.id), ["history"])
        XCTAssertEqual(try upgraded.dbQueue.read { try Row.fetchAll($0, sql: "PRAGMA foreign_key_check").count }, 0)
    }

    func testZeroOneTenFiveHundredAndThousandEntriesRemainExactOrderedPlaceholders() async throws {
        for size in [0, 1, 10, 500, 1000] {
            let f = try LibraryFixture(count: 0), input = source(size)
            let repo = f.storage.playlistMigrations
            let session = try await repo.createPlaylist(from: input, operationID: "operation-\(size)")
            let entries = try await repo.entries(migrationID: session.id)
            let progress = try await repo.progress(migrationID: session.id)
            XCTAssertEqual(entries.count, size); XCTAssertEqual(entries.map(\.position), Array(0..<size))
            XCTAssertEqual(entries.map(\.id), input.entries.map(\.id)); XCTAssertEqual(entries.map(\.source), input.entries)
            XCTAssertEqual(Set(entries.map(\.id)).count, size)
            XCTAssertTrue(entries.allSatisfy { $0.localTrackID == nil && $0.status == .pending })
            XCTAssertEqual(session.status, .metadataReady); XCTAssertTrue(progress.metadataComplete)
            XCTAssertEqual(progress.audioComplete, size == 0); XCTAssertEqual(progress.ready, 0)
            XCTAssertEqual(try count("tracks", f), 0); XCTAssertEqual(try count("playlist_tracks", f), 0)
            XCTAssertEqual(try repo.rows(playlistID: XCTUnwrap(session.destinationPlaylistID)).playbackOccurrences, [])
            print("PHASE10.1 integrity entries=\(size) ordered=\(entries.count) distinctOccurrences=\(Set(entries.map(\.id)).count) playable=0")
        }
    }

    func testValidationAndDatabaseConstraintsRejectDuplicateIdentityAndPosition() async throws {
        let f = try LibraryFixture(count: 0), repo = f.storage.playlistMigrations
        let item = PlaylistMigrationSourceTrack(position: 0, title: "One")
        let duplicateID = PlaylistMigrationSourceTrack(id: item.id, position: 1, title: "Two")
        await fails(PlaylistMigrationFoundationError.duplicateOccurrenceID) {
            _ = try await repo.createPlaylist(from: PlaylistMigrationSourcePlaylist(source: .exportify, name: "Bad", entries: [item, duplicateID]), operationID: "bad")
        }
        await fails(PlaylistMigrationFoundationError.invalidPosition(index: 1)) {
            _ = try await repo.createPlaylist(from: PlaylistMigrationSourcePlaylist(source: .exportify, name: "Bad", entries: [item, item]), operationID: "bad")
        }
        XCTAssertEqual(try count("playlists", f), 0)
        let session = try await repo.createPlaylist(from: source(1), operationID: "ok")
        let db = f.storage.database.dbQueue
        do {
            try await db.write { db in
                var record = try XCTUnwrap(MigrationEntryRecord.fetchOne(db))
                record.sourcePosition = 1; try record.insert(db)
            }; XCTFail("Duplicate UUID accepted")
        } catch { XCTAssertTrue(error is DatabaseError) }
        do {
            try await db.write { db in
                var record = try XCTUnwrap(MigrationEntryRecord.fetchOne(db))
                record.id = UUID().uuidString; try record.insert(db)
            }; XCTFail("Duplicate source position accepted")
        } catch { XCTAssertTrue(error is DatabaseError) }
        let entries = try await repo.entries(migrationID: session.id); XCTAssertEqual(entries.count, 1)
    }

    func testMidTransactionFailureRollsBackPlaylistSessionAndAllOccurrences() async throws {
        let f = try LibraryFixture(count: 0)
        try await f.storage.database.dbQueue.write { try $0.execute(sql: "CREATE TRIGGER fail_entry BEFORE INSERT ON migration_entries WHEN NEW.sourcePosition = 250 BEGIN SELECT RAISE(ABORT, 'injected insertion failure'); END") }
        do { _ = try await f.storage.playlistMigrations.createPlaylist(from: source(500), operationID: "rollback"); XCTFail("Injection did not fire") }
        catch { XCTAssertTrue(error is DatabaseError) }
        for table in ["playlists", "playlist_migrations", "migration_entries"] { XCTAssertEqual(try count(table, f), 0) }
        try await f.storage.database.dbQueue.write { try $0.execute(sql: "DROP TRIGGER fail_entry") }
        _ = try await f.storage.playlistMigrations.createPlaylist(from: source(500), operationID: "rollback")
        XCTAssertEqual(try count("migration_entries", f), 500)
    }

    func testOperationNormalizationIdempotencyConflictAndSeparateOperations() async throws {
        let f = try LibraryFixture(count: 0), repo = f.storage.playlistMigrations
        let first = try await repo.createPlaylist(from: source(10), operationID: "  user-operation\n")
        let retry = try await repo.createPlaylist(from: source(10), operationID: "user-operation")
        XCTAssertEqual(first, retry)
        await fails(PlaylistMigrationStorageError.operationConflict) { _ = try await repo.createPlaylist(from: self.source(11), operationID: "user-operation") }
        await fails(PlaylistMigrationStorageError.invalidOperationID) { _ = try await repo.createPlaylist(from: self.source(1), operationID: " \n") }
        let other = try await repo.createPlaylist(from: source(10), operationID: "second-operation")
        XCTAssertNotEqual(first.id, other.id); XCTAssertEqual(try count("migration_entries", f), 20)
    }

    func testConcurrentConnectionsCannotDuplicateOperation() async throws {
        let f = try LibraryFixture(count: 0), input = source(500)
        let sessions = try await withThrowingTaskGroup(of: UUID.self) { group in
            for _ in 0..<8 {
                group.addTask {
                    let connection = try DatabaseManager(url: f.paths.database)
                    return try GRDBPlaylistMigrationRepository(db: connection.dbQueue, paths: f.paths).createCommittedPlaylist(from: input, operationID: "concurrent").id
                }
            }
            var ids: [UUID] = []; for try await id in group { ids.append(id) }; return ids
        }
        XCTAssertEqual(Set(sessions).count, 1); XCTAssertEqual(try count("playlists", f), 1); XCTAssertEqual(try count("migration_entries", f), 500)
    }

    func testDiskRestartRestoresMetadataCandidatesIssuesAndProgress() async throws {
        let f = try LibraryFixture(count: 0), repo = f.storage.playlistMigrations, input = source(500)
        let session = try await repo.createPlaylist(from: input, operationID: "restart")
        let candidate = PlaylistMigrationCandidate(id: UUID(), entryID: input.entries[4].id, provider: "local", providerTrackID: "recording", title: "Candidate", artist: "Artist", durationMs: 2000, confidence: 0.9, evidence: ["reason": "Duration agrees"], decision: .pending)
        let issue = PlaylistMigrationIssue(id: UUID(), migrationID: session.id, entryID: input.entries[4].id, code: "needs_review", message: "Review this recording", technicalDetails: "Two possible recordings", severity: .warning, resolution: .open, createdAt: Date(), resolvedAt: nil)
        try await repo.saveCandidate(candidate); try await repo.saveIssue(issue)
        try await repo.updateCandidate(id: candidate.id, decision: .accepted)
        try await repo.resolveIssue(id: issue.id, resolution: .resolved)
        try await repo.updateEntryStatus(entryID: input.entries[4].id, to: .matching)
        try await repo.updateStatus(migrationID: session.id, to: .matching)
        let reopened = try StorageCoordinator(paths: f.paths).playlistMigrations
        let entries = try await reopened.entries(migrationID: session.id)
        XCTAssertEqual(entries.map(\.source), input.entries); XCTAssertEqual(entries[4].status, .matching)
        let candidates = try await reopened.candidates(entryID: input.entries[4].id)
        XCTAssertEqual(candidates.count, 1); XCTAssertEqual(candidates[0].decision, .accepted); XCTAssertEqual(candidates[0].evidence, candidate.evidence)
        let issues = try await reopened.issues(migrationID: session.id)
        XCTAssertEqual(issues[0].resolution, .resolved); XCTAssertNotNil(issues[0].resolvedAt)
        let progress = try await reopened.progress(migrationID: session.id)
        XCTAssertTrue(progress.metadataComplete); XCTAssertFalse(progress.audioComplete); XCTAssertEqual(progress.actual, 500)
        let pending = try await reopened.incompleteSessions(); XCTAssertEqual(pending.map(\.id), [session.id])
        let retried = try await reopened.createPlaylist(from: input, operationID: "restart"); XCTAssertEqual(retried.id, session.id)
    }

    func testTransitionsRejectIllegalAndUnverifiedReadyWithoutMutation() async throws {
        let f = try LibraryFixture(count: 1), repo = f.storage.playlistMigrations, input = source(1)
        let session = try await repo.createPlaylist(from: input, operationID: "states"), entryID = input.entries[0].id
        await fails(PlaylistMigrationFoundationError.illegalSessionTransition) { try await repo.updateStatus(migrationID: session.id, to: .completed) }
        await fails(PlaylistMigrationFoundationError.illegalEntryTransition) { try await repo.updateEntryStatus(entryID: entryID, to: .downloading) }
        await fails(PlaylistMigrationStorageError.invalidLocalTrack) { try await repo.updateEntryStatus(entryID: entryID, to: .ready) }
        try await repo.updateStatus(migrationID: session.id, to: .matching)
        await fails(PlaylistMigrationStorageError.invalidLocalTrack) { try await repo.updateStatus(migrationID: session.id, to: .completed) }
        let before = try await repo.entries(migrationID: session.id); XCTAssertEqual(before[0].status, .pending)
        try await repo.associateVerifiedTrack(entryID: entryID, trackID: f.ids[0])
        try await repo.updateStatus(migrationID: session.id, to: .completed)
        let done = try await repo.progress(migrationID: session.id); XCTAssertTrue(done.audioComplete)
        await fails(PlaylistMigrationFoundationError.illegalSessionTransition) { try await repo.updateStatus(migrationID: session.id, to: .matching) }
        try await repo.removeLocalAssociation(entryID: entryID)
        let lost = try await repo.progress(migrationID: session.id); XCTAssertFalse(lost.audioComplete); XCTAssertTrue(lost.metadataComplete)
    }

    func testDeletedAndMissingAudioPreserveOccurrencesAndOriginalMetadata() async throws {
        let f = try LibraryFixture(count: 2), repo = f.storage.playlistMigrations, input = source(5)
        let session = try await repo.createPlaylist(from: input, operationID: "deletion")
        for index in 0..<3 { try await repo.associateVerifiedTrack(entryID: input.entries[index].id, trackID: f.ids[0]) }
        try await repo.associateVerifiedTrack(entryID: input.entries[3].id, trackID: f.ids[1])
        try f.storage.tracks.delete(id: f.ids[0])
        try FileManager.default.removeItem(at: f.file(1))
        let rows = try repo.rows(playlistID: XCTUnwrap(session.destinationPlaylistID))
        XCTAssertTrue(rows.playbackOccurrences.isEmpty); XCTAssertEqual(rows.count, 5)
        let reopened = try StorageCoordinator(paths: f.paths).playlistMigrations
        let restored = try await reopened.entries(migrationID: session.id)
        XCTAssertEqual(restored.map(\.source), input.entries); XCTAssertTrue(restored.allSatisfy { $0.localTrackID == nil })
        XCTAssertEqual(Array(restored.prefix(4)).map(\.status), Array(repeating: .unavailable, count: 4))
        let progress = try await reopened.progress(migrationID: session.id); XCTAssertEqual(progress.unavailable, 4); XCTAssertTrue(progress.metadataComplete)
        XCTAssertEqual(try f.foreignKeys(), 0)
    }

    func testAvailabilityChangedAndInvalidFilesCannotBecomePlayable() async throws {
        let f = try LibraryFixture(count: 1), repo = f.storage.playlistMigrations, input = source(1)
        let session = try await repo.createPlaylist(from: input, operationID: "available")
        try await repo.associateVerifiedTrack(entryID: input.entries[0].id, trackID: f.ids[0])
        try f.storage.tracks.updateAvailability(id: f.ids[0], .modified)
        let changed = try await repo.entries(migrationID: session.id); XCTAssertEqual(changed[0].status, .unavailable); XCTAssertNil(changed[0].localTrackID)
        try await repo.updateEntryStatus(entryID: input.entries[0].id, to: .matching)
        await fails(PlaylistMigrationStorageError.invalidLocalTrack) { try await repo.associateVerifiedTrack(entryID: input.entries[0].id, trackID: f.ids[0]) }
        try f.storage.tracks.updateAvailability(id: f.ids[0], .available)
        try Data().write(to: f.file(0))
        await fails(PlaylistMigrationStorageError.invalidLocalTrack) { try await repo.associateVerifiedTrack(entryID: input.entries[0].id, trackID: f.ids[0]) }
        var track = try XCTUnwrap(f.storage.tracks.find(id: f.ids[0])); track.fileRelativePath = "../outside.wav"; try f.storage.tracks.save(track)
        XCTAssertFalse(MigrationLocalAudio.isAvailable(track, paths: f.paths))
    }

    func testPlaylistCascadeDeletesOnlyOwnedMetadataAndRejectsLegacyMembershipEdits() async throws {
        let f = try LibraryFixture(count: 1), repo = f.storage.playlistMigrations, input = source(2)
        let ordinary = try f.repository.createPlaylist(name: "Ordinary"); try f.repository.addTracks(f.ids, playlistID: ordinary.id)
        let session = try await repo.createPlaylist(from: input, operationID: "cascade")
        let playlistID = try XCTUnwrap(session.destinationPlaylistID)
        try await repo.associateVerifiedTrack(entryID: input.entries[0].id, trackID: f.ids[0])
        try await repo.saveCandidate(PlaylistMigrationCandidate(id: UUID(), entryID: input.entries[0].id, provider: "local", providerTrackID: nil, title: "Match", artist: nil, durationMs: nil, confidence: nil, evidence: [:], decision: .pending))
        for id in [nil, input.entries[0].id] {
            try await repo.saveIssue(PlaylistMigrationIssue(id: UUID(), migrationID: session.id, entryID: id, code: "test", message: "Issue", technicalDetails: nil, severity: .warning, resolution: .open, createdAt: Date(), resolvedAt: nil))
        }
        XCTAssertThrowsError(try f.repository.addTracks(f.ids, playlistID: playlistID))
        XCTAssertThrowsError(try f.repository.reorder([], playlistID: playlistID))
        _ = try f.repository.deletePlaylist(id: playlistID, confirmed: true)
        for table in ["playlist_migrations", "migration_entries", "migration_candidates", "migration_issues"] { XCTAssertEqual(try count(table, f), 0) }
        XCTAssertEqual(try f.repository.snapshot().playlistTracks(ordinary.id).map(\.id), f.ids)
        XCTAssertTrue(FileManager.default.fileExists(atPath: try f.file(0).path)); XCTAssertEqual(try f.foreignKeys(), 0)
        let another = try await repo.createPlaylist(from: source(1), operationID: "delete-session")
        try await repo.deleteSession(id: another.id); XCTAssertEqual(try count("tracks", f), 1); XCTAssertEqual(try count("playlists", f), 1)
    }

    func testUnsafeDiagnosticsAndCrossSessionIssuesAreRejected() async throws {
        let f = try LibraryFixture(count: 0), repo = f.storage.playlistMigrations, input = source(1)
        let first = try await repo.createPlaylist(from: input, operationID: "first")
        let second = try await repo.createPlaylist(from: source(1), operationID: "second")
        let issue = PlaylistMigrationIssue(id: UUID(), migrationID: second.id, entryID: input.entries[0].id, code: "test", message: "Mismatch", technicalDetails: nil, severity: .blocking, resolution: .open, createdAt: Date(), resolvedAt: nil)
        await fails(PlaylistMigrationStorageError.invalidCandidate) { try await repo.saveIssue(issue) }
        let candidate = PlaylistMigrationCandidate(id: UUID(), entryID: input.entries[0].id, provider: "local", providerTrackID: nil, title: "Candidate", artist: nil, durationMs: nil, confidence: 0.5, evidence: ["url": "https://example.com/audio?opaque=credential"], decision: .pending)
        await fails(PlaylistMigrationStorageError.unsafeDiagnostics) { try await repo.saveCandidate(candidate) }
        await fails(PlaylistMigrationStorageError.unsafeDiagnostics) { try await repo.updateStatus(migrationID: first.id, to: .failed, failureInformation: "Bearer secret-value") }
        XCTAssertEqual(try count("migration_candidates", f), 0); XCTAssertEqual(try count("migration_issues", f), 0)
    }

    @MainActor func testMixedFiveHundredOccurrencePlaylistQueuesTenAndNavigatesRepeatedLocalTracks() async throws {
        let f = try LibraryFixture(count: 1), repo = f.storage.playlistMigrations, input = source(500)
        let session = try await repo.createPlaylist(from: input, operationID: "mixed")
        for index in stride(from: 0, to: 500, by: 50) { try await repo.associateVerifiedTrack(entryID: input.entries[index].id, trackID: f.ids[0]) }
        let rows = try repo.rows(playlistID: XCTUnwrap(session.destinationPlaylistID)), occurrences = rows.playbackOccurrences
        XCTAssertEqual(rows.count, 500); XCTAssertEqual(occurrences.count, 10); XCTAssertEqual(Set(occurrences.map(\.id)).count, 10)
        XCTAssertEqual(occurrences.map(\.id), stride(from: 0, to: 500, by: 50).map { input.entries[$0].id.uuidString })
        let (player, _, library) = f.services()
        XCTAssertEqual(library.playlistEntryCount(try XCTUnwrap(session.destinationPlaylistID)), 500)
        try await player.playMigration(occurrences: occurrences, selected: occurrences[0].id, playlistID: XCTUnwrap(session.destinationPlaylistID), shuffle: false)
        XCTAssertEqual(player.queue.currentOccurrenceID, occurrences[0].id)
        for occurrence in occurrences.dropFirst() { await player.next(); XCTAssertEqual(player.queue.currentOccurrenceID, occurrence.id); XCTAssertEqual(player.state.currentTrackID, f.ids[0]) }
        await player.previous(); XCTAssertEqual(player.queue.currentOccurrenceID, occurrences[8].id)
        player.pause()
        let restored = PlaybackQueueManager(storage: try StorageCoordinator(paths: f.paths), makeShuffle: { $0 })
        XCTAssertEqual(restored.currentOccurrenceID, occurrences[8].id); XCTAssertEqual(restored.contextTrackIDs.count, 10)
        XCTAssertEqual(restored.nextID(), f.ids[0]); restored.didStart(f.ids[0]); XCTAssertEqual(restored.currentOccurrenceID, occurrences[9].id)
        XCTAssertEqual(try repo.rows(playlistID: XCTUnwrap(session.destinationPlaylistID)).count, 500)
        let progress = try await repo.progress(migrationID: session.id); XCTAssertEqual(progress.ready, 10); XCTAssertFalse(progress.audioComplete)
    }

    @MainActor func testShuffleAndZeroPlayableReadModelNeverFabricateTrackIDs() async throws {
        let f = try LibraryFixture(count: 1), repo = f.storage.playlistMigrations, input = source(3)
        let session = try await repo.createPlaylist(from: input, operationID: "queue")
        let (player, transport, library) = f.services()
        await library.playMigration(playlistID: try XCTUnwrap(session.destinationPlaylistID)); XCTAssertEqual(transport.replacements, 0)
        XCTAssertNil(player.state.currentTrackID)
        for entry in input.entries { try await repo.associateVerifiedTrack(entryID: entry.id, trackID: f.ids[0]) }
        let occurrences = try repo.rows(playlistID: XCTUnwrap(session.destinationPlaylistID)).playbackOccurrences
        let queue = PlaybackQueueManager(storage: f.storage, makeShuffle: { $0 })
        queue.setMigrationContext(occurrences, selected: occurrences[0].id); queue.didStart(f.ids[0]); queue.toggleShuffle()
        var visited = [try XCTUnwrap(queue.currentOccurrenceID)]
        for _ in 0..<2 { XCTAssertEqual(queue.nextID(), f.ids[0]); queue.didStart(f.ids[0]); visited.append(try XCTUnwrap(queue.currentOccurrenceID)) }
        XCTAssertEqual(visited, occurrences.map(\.id))
        try FileManager.default.removeItem(at: f.file(0))
        queue.setContext([f.ids[0]], current: f.ids[0]); XCTAssertNil(queue.nextID()); XCTAssertTrue(queue.contextTrackIDs.isEmpty)
    }

    @MainActor func testABACAPreservesPositionsAndDeletionReconcilesPersistedShuffle() async throws {
        let f = try LibraryFixture(count: 3), repo = f.storage.playlistMigrations, input = source(5)
        let session = try await repo.createPlaylist(from: input, operationID: "abaca")
        let trackIDs = [f.ids[0], f.ids[1], f.ids[0], f.ids[2], f.ids[0]]
        for (index, trackID) in trackIDs.enumerated() { try await repo.associateVerifiedTrack(entryID: input.entries[index].id, trackID: trackID) }
        let rows = try repo.rows(playlistID: XCTUnwrap(session.destinationPlaylistID))
        XCTAssertEqual(rows.playbackOccurrences.map(\.trackID), trackIDs)
        let queue = PlaybackQueueManager(storage: f.storage, makeShuffle: { $0 })
        queue.setMigrationContext(rows.playbackOccurrences, selected: input.entries[0].id.uuidString)
        queue.didStart(trackIDs[0])
        for index in 1..<5 {
            XCTAssertEqual(queue.nextID(), trackIDs[index]); queue.didStart(trackIDs[index])
            XCTAssertEqual(queue.currentOccurrenceID, input.entries[index].id.uuidString)
        }
        queue.toggleShuffle()
        queue.persistState(currentTrackID: f.ids[0], positionMs: 0, sleepDeadline: nil, sleepTimerDuration: nil, contextKind: "migrationPlaylist", contextSourceID: session.destinationPlaylistID)
        _ = try ManagedLibraryFiles.deleteTrack(f.ids[0], confirmed: true, paths: f.paths, db: f.storage.database.dbQueue)
        let restored = PlaybackQueueManager(storage: try StorageCoordinator(paths: f.paths), makeShuffle: { $0 })
        XCTAssertEqual(restored.contextTrackIDs, [f.ids[1], f.ids[2]])
        for _ in 0..<4 {
            let id = try XCTUnwrap(restored.nextID()); XCTAssertTrue([f.ids[1], f.ids[2]].contains(id)); restored.didStart(id)
        }
        let preserved = try await repo.entries(migrationID: session.id)
        XCTAssertEqual(preserved.count, 5); XCTAssertEqual(preserved.map(\.source), input.entries)
    }

    func testFailureAfterCommitAndCorruptMetadataNeverDiscardOtherSourceEntries() async throws {
        let f = try LibraryFixture(count: 0), repo = f.storage.playlistMigrations, input = source(500)
        enum ClientFailure: Error { case afterCommit }
        do {
            _ = try await repo.createPlaylist(from: input, operationID: "committed")
            throw ClientFailure.afterCommit
        } catch ClientFailure.afterCommit { }
        let reopened = try StorageCoordinator(paths: f.paths).playlistMigrations
        let session = try await reopened.createPlaylist(from: input, operationID: "committed")
        let entries = try await reopened.entries(migrationID: session.id); XCTAssertEqual(entries.map(\.source), input.entries)
        try await f.storage.database.dbQueue.write { try $0.execute(sql: "DELETE FROM migration_entries WHERE id = ?", arguments: [input.entries[200].id.uuidString]) }
        XCTAssertThrowsError(try reopened.recover()) { XCTAssertEqual($0 as? PlaylistMigrationStorageError, .corruptMetadata) }
        await fails(PlaylistMigrationStorageError.corruptMetadata) { _ = try await reopened.createPlaylist(from: input, operationID: "committed") }
        XCTAssertEqual(try count("migration_entries", f), 499); XCTAssertEqual(try count("playlists", f), 1)
    }

    @MainActor func testExplicitQueueKeepsItsOwnIdentitiesAndResumesSourceOccurrenceAfterRestart() async throws {
        let f = try LibraryFixture(count: 2), repo = f.storage.playlistMigrations, input = source(3)
        let session = try await repo.createPlaylist(from: input, operationID: "explicit")
        for entry in input.entries { try await repo.associateVerifiedTrack(entryID: entry.id, trackID: f.ids[0]) }
        let queue = PlaybackQueueManager(storage: f.storage, makeShuffle: { $0 })
        let occurrences = try repo.rows(playlistID: XCTUnwrap(session.destinationPlaylistID)).playbackOccurrences
        queue.setMigrationContext(occurrences, selected: occurrences[1].id); queue.didStart(f.ids[0])
        queue.addToQueue(trackID: f.ids[1]); queue.addToQueue(trackID: f.ids[1])
        let identities = queue.entries.map { "queue:" + $0.id }; XCTAssertEqual(Set(identities).count, 2)
        for identity in identities {
            XCTAssertEqual(queue.nextID(), f.ids[1]); queue.didStart(f.ids[1]); XCTAssertEqual(queue.currentOccurrenceID, identity)
        }
        queue.persistState(currentTrackID: f.ids[1], positionMs: 0, sleepDeadline: nil, sleepTimerDuration: nil, contextKind: "migrationPlaylist", contextSourceID: session.destinationPlaylistID)
        let restored = PlaybackQueueManager(storage: f.storage, makeShuffle: { $0 })
        XCTAssertEqual(restored.currentOccurrenceID, identities[1])
        XCTAssertEqual(restored.nextID(), f.ids[0]); restored.didStart(f.ids[0]); XCTAssertEqual(restored.currentOccurrenceID, occurrences[2].id)
    }
}
