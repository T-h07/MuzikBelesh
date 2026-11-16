import Foundation
import GRDB
import XCTest
@testable import OFFLINE

/// Remove from Playlist works on the occurrence (not the track) for every playlist kind,
/// never deletes audio, survives restarts and cannot be undone by late callbacks.
@MainActor final class PlaylistOccurrenceRemovalTests: XCTestCase {
    private func playlistID(_ session: PlaylistMigrationSession) throws -> String { try XCTUnwrap(session.destinationPlaylistID) }
    private func positions(_ f: IssueFixture, _ session: PlaylistMigrationSession) throws -> [Int] {
        try f.repo.rows(playlistID: try playlistID(session)).map(\.entry.position)
    }
    private func until(_ message: String, timeout: Double = 10, _ condition: () async throws -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline { if try await condition() { return }; try await Task.sleep(for: .milliseconds(25)) }
        XCTFail("\(message) did not happen within \(timeout)s"); throw CancellationError()
    }

    // T05, T09, T10 (ordinary playlists)
    func testRemovingFromAManualPlaylistKeepsTheSongElsewhereAndUndoRestoresItsPlace() async throws {
        let f = try issueFixture()
        let library = MusicLibraryService(storage: f.storage, player: nil)
        let a = try f.fixture.repository.createPlaylist(name: "A"), b = try f.fixture.repository.createPlaylist(name: "B")
        try f.fixture.repository.addTracks(Array(f.fixture.ids.prefix(3)), playlistID: a.id)
        try f.fixture.repository.addTracks([f.fixture.ids[1]], playlistID: b.id)
        try await until("Snapshot loaded") { library.playlistTracks(a.id).count == 3 }
        library.removeFromOrdinaryPlaylist(f.fixture.ids[1], playlistID: a.id)
        try await until("Removal visible") { library.playlistTracks(a.id).map(\.id) == [f.fixture.ids[0], f.fixture.ids[2]] }
        XCTAssertEqual(library.playlistTracks(b.id).map(\.id), [f.fixture.ids[1]], "Other playlists keep the song")
        XCTAssertNotNil(library.track(f.fixture.ids[1]), "The library track stays")
        XCTAssertTrue(FileManager.default.fileExists(atPath: try f.fixture.file(1).path), "The audio file stays")
        XCTAssertEqual(library.pendingUndo?.title, "Song 1")
        await library.undoRemoval()
        try await until("Undo restores the original order") { library.playlistTracks(a.id).map(\.id) == Array(f.fixture.ids.prefix(3)) }
        XCTAssertNil(library.pendingUndo)
    }

    // T06, T08, T10, T13 (imported playlists)
    func testRemovingOneImportedOccurrenceKeepsDuplicatesSharedAudioOrderAndCounts() async throws {
        let f = try issueFixture()
        let p = try await f.playlist("Imported", count: 4, duplicate: { $0 == 1 ? 0 : nil })
        let other = try await f.playlist("Other", count: 1)
        try await f.intent(p.session, "completed")
        try await f.set(p.entries[0], .ready, track: f.fixture.ids[0])
        try await f.set(p.entries[1], .ready, track: f.fixture.ids[0]) // Duplicate occurrence, shared audio.
        try await f.set(p.entries[2], .ready, track: f.fixture.ids[1])
        try await f.set(p.entries[3], .unavailable); try await f.checkpoint(p.entries[3], "noMatch")
        try await f.set(other.entries[0], .ready, track: f.fixture.ids[0])
        let id = try playlistID(p.session)
        let before = try f.repo.hybridPlaybackOccurrences(playlistID: id)

        try await f.repo.removeOccurrence(entryID: p.entries[0].id, playlistID: id)
        XCTAssertEqual(try positions(f, p.session), [1, 2, 3], "Only the selected occurrence leaves; order is preserved")
        let duplicate = try await f.repo.entry(id: p.entries[1].id)
        XCTAssertEqual(duplicate.status, .ready); XCTAssertEqual(duplicate.localTrackID, f.fixture.ids[0], "The duplicate keeps its audio")
        let elsewhere = try await f.repo.entry(id: other.entries[0].id)
        XCTAssertEqual(elsewhere.localTrackID, f.fixture.ids[0], "Another playlist is unaffected")
        XCTAssertTrue(FileManager.default.fileExists(atPath: try f.fixture.file(0).path), "Shared audio is never deleted")
        let tracks = try await f.count("tracks")
        XCTAssertEqual(tracks, 4)
        let after = try f.repo.hybridPlaybackOccurrences(playlistID: id)
        XCTAssertEqual(after.map(\.id), Array(before.map(\.id).dropFirst()), "Playback order follows the remaining occurrences")

        let progress = try await f.repo.progress(migrationID: p.session.id)
        XCTAssertEqual(progress.expected, 3); XCTAssertEqual(progress.actual, 3); XCTAssertEqual(progress.ready, 2)
        XCTAssertTrue(progress.metadataComplete)
        let paths = f.fixture.paths
        let snapshot = try await f.db.read { try LibraryRepository.observedSnapshot($0, paths: paths) }
        let presentation = try XCTUnwrap(snapshot.migrationPresentations[id])
        XCTAssertEqual(presentation.rows.map(\.entry.position), [1, 2, 3])
        XCTAssertTrue(presentation.progress.metadataComplete, "Gaps left by removal are not an incomplete import")
        let overview = try await MigrationCoordinatorRepository(db: f.db).overview(algorithm: CandidateScoringEngine.algorithmVersion, now: Date())
        XCTAssertEqual(overview.first { $0.migrationID == p.session.id }?.total, 3)
        // The same removal again is a no-op.
        try await f.repo.removeOccurrence(entryID: p.entries[0].id, playlistID: id)
        XCTAssertEqual(try positions(f, p.session), [1, 2, 3])
    }

    // T07, T12 (unresolved placeholder, stale matching callbacks)
    func testRemovedPlaceholderCannotBeRestoredByMatchingOrRetries() async throws {
        let f = try issueFixture()
        let p = try await f.playlist("Placeholder", count: 3)
        let id = try playlistID(p.session)
        try await f.intent(p.session, "running")
        let lease = try await f.repo.beginMatching(migrationID: p.session.id)
        let current = try await f.repo.entry(id: p.entries[1].id)
        let claimed = try await f.repo.claimMatchingEntry(current, session: lease, retryFailed: true)
        let claim = try XCTUnwrap(claimed)
        try await f.retryRecord(p.entries[1], failures: 1, eligible: true, next: Date())

        try await f.repo.removeOccurrence(entryID: p.entries[1].id, playlistID: id)
        // The in-flight attempt finishes late: it can neither commit nor fail the occurrence.
        let decision = SongMatchDecision(outcome: .noMatch, ranked: [], explanation: "No match", margin: 0)
        do { try await f.repo.commitMatching(claim, decision: decision); XCTFail("A removed occurrence must reject a stale commit") }
        catch SongMatchingError.staleAttempt {}
        try await f.repo.recordMatchingFailure(claim, category: .provider)
        let entry = try await f.repo.entry(id: p.entries[1].id)
        XCTAssertEqual(entry.status, .skipped); XCTAssertNil(entry.localTrackID)
        XCTAssertEqual(try positions(f, p.session), [0, 2])
        let reclaim = try await f.repo.claimMatchingEntry(entry, session: lease, retryFailed: true)
        XCTAssertNil(reclaim, "Matching never claims a removed occurrence")
        do { try await f.repo.markRetryable(entryID: entry.id); XCTFail("Retry must not apply") } catch {}
        do { try await f.repo.updateEntryStatus(entryID: entry.id, to: .pending); XCTFail("Only Undo restores a removed occurrence") } catch {}
        let store = MigrationCoordinatorRepository(db: f.db)
        let retry = try await store.retryRecord(entryID: entry.id)
        XCTAssertNil(retry, "Pending retries are dropped")
        let slice = try await store.nextSlice(migrationID: p.session.id, after: -1, limit: 10, algorithm: CandidateScoringEngine.algorithmVersion)
        XCTAssertFalse(slice.map(\.id).contains(entry.id))
        let audit = try await f.repo.issues(migrationID: p.session.id).filter { $0.code == "user.remove" }
        XCTAssertEqual(audit.count, 1, "The removal is recorded durably")
    }

    // T11 (restart) and Undo of an imported occurrence
    func testRemovalPersistsAcrossRestartAndUndoRestoresTheVerifiedRecording() async throws {
        let f = try issueFixture()
        let p = try await f.playlist("Persist", count: 3)
        let id = try playlistID(p.session)
        try await f.set(p.entries[1], .ready, track: f.fixture.ids[2])
        try await f.repo.removeOccurrence(entryID: p.entries[1].id, playlistID: id)

        let reopened = try DatabaseManager(url: f.fixture.paths.database)
        let repo = GRDBPlaylistMigrationRepository(db: reopened.dbQueue, paths: f.fixture.paths)
        let rows = try repo.rows(playlistID: id)
        XCTAssertEqual(rows.map(\.entry.position), [0, 2], "Still removed after a restart")
        let entries = try await repo.entries(migrationID: p.session.id)
        XCTAssertFalse(entries.contains { $0.id == p.entries[1].id })

        try await repo.restoreOccurrence(entryID: p.entries[1].id, playlistID: id)
        let restored = try repo.rows(playlistID: id)
        XCTAssertEqual(restored.map(\.entry.position), [0, 1, 2], "Undo returns it to its original position")
        let row = try XCTUnwrap(restored.first { $0.id == p.entries[1].id })
        XCTAssertEqual(row.playableTrack?.id, f.fixture.ids[2], "The verified recording plays again")
        XCTAssertEqual(row.entry.source, p.entries[1].source)
    }

    // T13, T18 (issue report and migration totals follow membership)
    func testIssueReportAndSummaryFollowTheNewMembership() async throws {
        let f = try issueFixture()
        let p = try await f.playlist("Report", count: 3)
        try await f.intent(p.session, "completed")
        try await f.set(p.entries[0], .ready, track: f.fixture.ids[0])
        try await f.set(p.entries[1], .unavailable); try await f.checkpoint(p.entries[1], "noMatch")
        try await f.set(p.entries[2], .ready, track: f.fixture.ids[1])
        await f.reconcile()
        XCTAssertEqual(f.coordinator.summaries[p.session.id]?.attention, 1)
        try await f.repo.removeOccurrence(entryID: p.entries[1].id, playlistID: try playlistID(p.session))
        await f.reconcile()
        let summary = try XCTUnwrap(f.coordinator.summaries[p.session.id])
        XCTAssertEqual(summary.total, 2); XCTAssertEqual(summary.playable, 2); XCTAssertEqual(summary.outcome, .fullyReady)
        XCTAssertTrue(summary.accountedFor)
        let open = try await f.open(p.session)
        XCTAssertTrue(open.isEmpty, "The removed song's issue is closed")
        let closed = try await f.rows(p.session)
        XCTAssertEqual(closed.first?.closeReason, MigrationIssueCloseReason.userAction.rawValue)
    }

    // T14/T15 interplay: removal cancels a staged replacement, never the audio
    func testRemovingAnOccurrenceCancelsItsStagedReplacementOnly() async throws {
        let f = try issueFixture()
        let p = try await f.playlist("Staged", count: 1)
        try await f.set(p.entries[0], .ready, track: f.fixture.ids[0])
        let entry = try await f.repo.entry(id: p.entries[0].id)
        try await f.repo.stageReplacement(for: entry, video: YouTubeVideo(id: "rplc0000001", title: "Replacement"), metadataVerified: true)
        let staged = try await f.repo.replacement(entryID: entry.id)
        XCTAssertNotNil(staged)
        try await f.repo.removeOccurrence(entryID: entry.id, playlistID: try playlistID(p.session))
        let gone = try await f.repo.replacement(entryID: entry.id)
        XCTAssertNil(gone, "No replacement keeps downloading for a removed occurrence")
        let candidate = try await f.repo.candidates(entryID: entry.id).first { $0.providerTrackID == "rplc0000001" }
        XCTAssertEqual(candidate?.evidence["replacementOutcome"], "removed")
        XCTAssertTrue(FileManager.default.fileExists(atPath: try f.fixture.file(0).path))
    }

    // T12, T10, T18 (late download completion; shared job for another playlist)
    func testLateDownloadNeverRestoresARemovedOccurrenceAndSharedWorkContinues() async throws {
        let h = try harness(limit: 1, holding: true)
        let video = AcquisitionHarness.video(9)
        let a = try await h.playlist("Removed A", [video]), b = try await h.playlist("Kept B", [video])
        try await h.until("Shared transfer in flight") { await h.transfer.waiting == 1 }
        try await h.repo.removeOccurrence(entryID: a.entries[0].id, playlistID: try XCTUnwrap(a.session.destinationPlaylistID))
        await h.settle()
        let job = try XCTUnwrap(try h.jobs().first { $0.sourceIdentifier == video })
        XCTAssertFalse([.paused, .cancelled].contains(job.state), "B still needs the shared download")
        await h.transfer.releaseAll()
        try await h.until("B offline") { try await h.allReady(b.session) }
        await h.settle()
        let removed = try await h.repo.entry(id: a.entries[0].id)
        XCTAssertEqual(removed.status, .skipped); XCTAssertNil(removed.localTrackID, "The completion never re-associates the removed occurrence")
        let rows = try h.repo.rows(playlistID: try XCTUnwrap(a.session.destinationPlaylistID))
        XCTAssertTrue(rows.isEmpty)
        let tracks = try await h.trackCount()
        XCTAssertEqual(tracks, 1)
        // A direct stale association attempt is refused as well.
        let candidate = try await h.repo.candidates(entryID: a.entries[0].id).first { $0.decision == .accepted }
        let bEntries = try await h.entries(b.session)
        let trackID = try XCTUnwrap(bEntries.first?.localTrackID)
        let outcome = try await h.repo.associateAcquiredTrack(trackID: trackID, occurrences: [(a.entries[0].id, try XCTUnwrap(candidate).id)])
        XCTAssertEqual(outcome[a.entries[0].id], .stale)
    }

    // T17 (Delete Download respects shared ownership; Download Again)
    func testDeletingADownloadKeepsOccurrencesAndCanDownloadAgain() async throws {
        let h = try harness(limit: 1)
        let video = AcquisitionHarness.video(4)
        let p = try await h.playlist("Download", [video, video])
        try await h.until("Downloaded") { try await h.allReady(p.session) }
        await h.settle()
        let downloaded = try await h.entries(p.session)
        let trackID = try XCTUnwrap(downloaded.first?.localTrackID)
        _ = try ManagedLibraryFiles.deleteTrack(trackID, confirmed: true, paths: h.fixture.paths, db: h.storage.database.dbQueue)
        let after = try await h.entries(p.session)
        XCTAssertEqual(after.count, 2, "Deleting the download never removes playlist occurrences")
        XCTAssertTrue(after.allSatisfy { $0.status == .unavailable && $0.localTrackID == nil })
        let accepted = try await h.repo.candidates(entryID: after[0].id).filter { $0.decision == .accepted }.compactMap(\.providerTrackID)
        XCTAssertEqual(accepted, [video], "The confirmed recording is remembered")

        let issues = MigrationIssueRepository(db: h.storage.database.dbQueue, paths: h.fixture.paths)
        let built = try await issues.report(migrationID: p.session.id, now: Date(), capacity: nil)
        let report = try XCTUnwrap(built)
        let occurrence = try XCTUnwrap(report.occurrence(after[0].id))
        XCTAssertEqual(occurrence.assessment.category, .missingLocalAudio)
        XCTAssertEqual(occurrence.assessment.actions.first, .downloadAgain)
        try await issues.downloadAgain(entryID: after[0].id, migrationID: p.session.id, now: Date())
        try await h.until("Downloaded again") { try await h.entries(p.session)[0].status == .ready }
        let second = try await h.entries(p.session)[1]
        XCTAssertEqual(second.status, .unavailable, "Only the occurrence the user asked for is downloaded again")
    }
}
