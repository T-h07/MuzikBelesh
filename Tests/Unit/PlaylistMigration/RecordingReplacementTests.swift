import Foundation
import GRDB
import XCTest
@testable import OFFLINE

/// Staged "Change Video" for occurrences that are already ready with verified audio.
/// The original recording stays associated and playable until the replacement is
/// downloaded through DownloadManager, verified and switched in one transaction.
@MainActor final class RecordingReplacementTests: XCTestCase {
    private let x = AcquisitionHarness.video(1), y = AcquisitionHarness.video(2), z = AcquisitionHarness.video(3)

    private func entry(_ h: AcquisitionHarness, _ id: UUID) async throws -> PlaylistMigrationEntry { try await h.repo.entry(id: id) }
    private func track(_ h: AcquisitionHarness, _ id: UUID, file: StaticString = #filePath, line: UInt = #line) async throws -> String {
        let value = try await h.repo.entry(id: id).localTrackID
        return try XCTUnwrap(value, file: file, line: line)
    }
    private func request(_ h: AcquisitionHarness, _ id: UUID) async throws -> RecordingReplacementRecord {
        let value = try await h.repo.replacement(entryID: id)
        return try XCTUnwrap(value)
    }
    private func stage(_ h: AcquisitionHarness, _ id: UUID, _ video: String) async throws {
        let fresh = try await h.repo.entry(id: id)
        try await h.coordinator.stageReplacement(for: fresh, video: YouTubeVideo(id: video, title: "Replacement \(video)"), metadataVerified: true)
    }
    private func accepted(_ h: AcquisitionHarness, _ id: UUID) async throws -> [String] {
        try await h.repo.candidates(entryID: id).filter { $0.decision == .accepted }.compactMap(\.providerTrackID)
    }
    private func playable(_ h: AcquisitionHarness, _ session: PlaylistMigrationSession) throws -> [UUID: String] {
        let rows = try h.repo.rows(playlistID: try XCTUnwrap(session.destinationPlaylistID))
        return Dictionary(uniqueKeysWithValues: rows.compactMap { row in row.playableTrack.map { (row.id, $0.id) } })
    }
    private func ready(_ h: AcquisitionHarness, _ session: PlaylistMigrationSession) async throws {
        try await h.until("Original recordings offline") { try await h.allReady(session) }
        await h.settle()
    }

    func testReplacementKeepsOriginalPlayableThenSwitchesAtomically() async throws {
        let h = try harness(limit: 1, holding: true)
        await h.transfer.seed(y, 77)
        let p = try await h.playlist("Swap", [x])
        try await h.until("Original transfer") { await h.transfer.waitingIDs == [self.x] }
        await h.transfer.release(x)
        try await ready(h, p.session)
        let id = p.entries[0].id
        let original = try await track(h, id)
        let oldCandidate = try await h.repo.candidates(entryID: id).first { $0.decision == .accepted }
        // The pre-existing path still refuses a verified occurrence; staging is the fix.
        do { try await h.repo.rejectYouTubeSelection(entryID: id, candidateID: try XCTUnwrap(oldCandidate).id); XCTFail("Expected stale") }
        catch SongMatchingError.staleAttempt {}
        let audioBefore = try h.repo.hybridPlaybackOccurrences(playlistID: try XCTUnwrap(p.session.destinationPlaylistID))

        try await stage(h, id, y)
        try await h.until("Replacement downloading") { await h.transfer.waitingIDs == [self.y] }
        // While the replacement downloads, nothing about the occurrence has changed.
        let during = try await entry(h, id)
        XCTAssertEqual(during.status, .ready); XCTAssertEqual(during.localTrackID, original)
        XCTAssertEqual(try playable(h, p.session)[id], original, "The current recording stays playable")
        let acceptedDuring = try await accepted(h, id)
        XCTAssertEqual(acceptedDuring, [x])
        XCTAssertNotNil(h.coordinator.replacement(for: id))
        XCTAssertEqual(h.coordinator.replacementStates[id]?.isPending, true)

        await h.transfer.release(y)
        try await h.until("Switched to the verified replacement") { try await self.entry(h, id).localTrackID != original }
        await h.settle()
        let after = try await entry(h, id)
        XCTAssertEqual(after.status, .ready)
        XCTAssertEqual(after.source, p.entries[0].source, "Source position and metadata are preserved")
        let acceptedAfter = try await accepted(h, id)
        XCTAssertEqual(acceptedAfter, [y], "Exactly one accepted decision: the replacement")
        let replaced = try await h.repo.candidates(entryID: id).first { $0.providerTrackID == x }
        XCTAssertEqual(replaced?.decision, .rejected); XCTAssertNotNil(replaced?.evidence["replacedBy"])
        let request = try await h.repo.replacement(entryID: id)
        XCTAssertNil(request)
        let links = try await h.links()
        let link = try XCTUnwrap(links.first { $0.entryID == id.uuidString })
        XCTAssertEqual(link.providerIdentity, y); XCTAssertEqual(link.state, .ready); XCTAssertEqual(link.trackID, after.localTrackID)
        let tracks = try await h.trackCount()
        XCTAssertEqual(tracks, 2, "The previous recording stays in the library")
        let audioAfter = try h.repo.hybridPlaybackOccurrences(playlistID: try XCTUnwrap(p.session.destinationPlaylistID))
        XCTAssertEqual(audioAfter.map(\.id), audioBefore.map(\.id), "Playback identity (the occurrence) is unchanged")
        XCTAssertEqual(audioAfter.first?.trackID, after.localTrackID)
        XCTAssertEqual(try h.fixture.foreignKeys(), 0)
    }

    func testFailedOrCancelledReplacementKeepsTheOriginalRecording() async throws {
        let h = try harness(limit: 1)
        h.preparer.fail(y, with: .noCompatibleAudio)
        let p = try await h.playlist("Rollback", [x])
        try await ready(h, p.session)
        let id = p.entries[0].id
        let original = try await track(h, id)
        try await stage(h, id, y)
        try await h.until("Replacement failed") { h.coordinator.replacement(for: id)?.state == .failed }
        let failed = try await entry(h, id)
        XCTAssertEqual(failed.status, .ready); XCTAssertEqual(failed.localTrackID, original)
        XCTAssertEqual(try playable(h, p.session)[id], original)
        let acceptedAfterFailure = try await accepted(h, id)
        XCTAssertEqual(acceptedAfterFailure, [x], "A failed replacement never changes the decision")
        XCTAssertEqual(h.coordinator.replacementStates[id]?.needsAttention, true)

        try await h.coordinator.cancelReplacement(entryID: id)
        let request = try await h.repo.replacement(entryID: id)
        XCTAssertNil(request)
        let staged = try await h.repo.candidates(entryID: id).first { $0.providerTrackID == y }
        XCTAssertEqual(staged?.decision, .pending, "The cancelled choice is kept as evidence only")
        XCTAssertEqual(staged?.evidence["replacementOutcome"], "cancelled")
        let kept = try await entry(h, id)
        XCTAssertEqual(kept.localTrackID, original); XCTAssertEqual(kept.status, .ready)
        XCTAssertNil(h.coordinator.replacementStates[id])
    }

    func testVerificationFailureRetriesThenExplicitRetrySwitches() async throws {
        let h = try harness(limit: 1)
        let p = try await h.playlist("Verify", [x])
        try await ready(h, p.session)
        let id = p.entries[0].id
        let original = try await track(h, id)
        await h.transfer.corrupt(z)
        try await stage(h, id, z)
        try await h.until("Corrupt replacement failed after its bounded retry") { h.coordinator.replacement(for: id)?.state == .failed }
        let unchanged = try await entry(h, id)
        XCTAssertEqual(unchanged.localTrackID, original, "Unverified audio is never associated")
        let started = await h.transfer.started
        XCTAssertEqual(started.filter { $0 == z }.count, 2, "One automatic retry, then the user decides")
        await h.transfer.heal(z); await h.transfer.seed(z, 5)
        try await h.coordinator.retryReplacement(entryID: id)
        try await h.until("Retried replacement switched") { try await self.entry(h, id).localTrackID != original }
        let acceptedAfter = try await accepted(h, id)
        XCTAssertEqual(acceptedAfter, [z])
    }

    func testPendingReplacementSurvivesRestartAndCompletesOnce() async throws {
        let h = try harness(limit: 1, holding: true)
        await h.transfer.seed(y, 31)
        let p = try await h.playlist("Restart", [x])
        try await h.until("Original transfer") { await h.transfer.waitingIDs == [self.x] }
        await h.transfer.release(x)
        try await ready(h, p.session)
        let id = p.entries[0].id
        let original = try await track(h, id)
        try await stage(h, id, y)
        try await h.until("Replacement in flight") { await h.transfer.waitingIDs == [self.y] }
        // The process dies mid-transfer; the new instance recovers from SQLite alone.
        let fresh = GatedAcquisitionTransfer()
        await fresh.seed(y, 31)
        await h.relaunch(transfer: fresh)
        let restored = try await h.repo.replacement(entryID: id)
        XCTAssertNotNil(restored, "The staged request is durable")
        let afterRestart = try await entry(h, id).localTrackID
        XCTAssertEqual(afterRestart, original, "Still on the original after restart")
        try await h.until("Recovered replacement switched") { try await self.entry(h, id).localTrackID != original }
        for _ in 0..<2 { await h.relaunch(transfer: fresh); await h.settle() }
        XCTAssertEqual(try h.jobs().filter { $0.sourceIdentifier == y }.count, 1, "Recovery never duplicates the job")
        let restarted = await fresh.started
        XCTAssertEqual(restarted.filter { $0 == y }.count, 1, "The recording is downloaded once after the restart")
        let acceptedAfter = try await accepted(h, id)
        XCTAssertEqual(acceptedAfter, [y])
        let request = try await h.repo.replacement(entryID: id)
        XCTAssertNil(request)
    }

    func testReplacingOneOccurrenceLeavesSharedRecordingsAndDuplicatesIntact() async throws {
        let h = try harness(limit: 1)
        await h.transfer.seed(y, 11)
        let a = try await h.playlist("Dup", [x, x])
        let b = try await h.playlist("Other", [x])
        try await ready(h, a.session); try await ready(h, b.session)
        let shared = try await track(h, a.entries[0].id)
        let all = try await h.entries(a.session) + h.entries(b.session)
        XCTAssertTrue(all.allSatisfy { $0.localTrackID == shared }, "One shared verified recording")

        try await stage(h, a.entries[0].id, y)
        try await h.until("First occurrence switched") { try await self.entry(h, a.entries[0].id).localTrackID != shared }
        let replacement = try await track(h, a.entries[0].id)
        let duplicate = try await entry(h, a.entries[1].id)
        let other = try await entry(h, b.entries[0].id)
        XCTAssertEqual(duplicate.localTrackID, shared, "The duplicate occurrence keeps its recording")
        XCTAssertEqual(other.localTrackID, shared, "Another playlist's occurrence keeps the shared recording")
        XCTAssertEqual(try playable(h, a.session)[a.entries[1].id], shared)
        XCTAssertEqual(try playable(h, b.session)[b.entries[0].id], shared)
        let firstPosition = try await entry(h, a.entries[0].id).position
        XCTAssertEqual(duplicate.position, 1); XCTAssertEqual(firstPosition, 0)

        // The duplicate may choose the same replacement: the completed job is reused.
        try await stage(h, a.entries[1].id, y)
        try await h.until("Duplicate switched") { try await self.entry(h, a.entries[1].id).localTrackID == replacement }
        XCTAssertEqual(try h.jobs().filter { $0.sourceIdentifier == y }.count, 1)
        let started = await h.transfer.started
        XCTAssertEqual(started.filter { $0 == y }.count, 1, "A completed replacement recording is never downloaded again")
        let otherAfter = try await entry(h, b.entries[0].id).localTrackID
        XCTAssertEqual(otherAfter, shared)
        let tracks = try await h.trackCount()
        XCTAssertEqual(tracks, 2)
    }

    func testStaleCompletionsCannotSwitchACancelledOrSupersededRequest() async throws {
        let h = try harness(limit: 1, holding: true)
        await h.transfer.seed(y, 3); await h.transfer.seed(z, 4)
        let p = try await h.playlist("Stale", [x])
        try await h.until("Original transfer") { await h.transfer.waitingIDs == [self.x] }
        await h.transfer.release(x)
        try await ready(h, p.session)
        let id = p.entries[0].id
        let original = try await track(h, id)

        // Re-staging supersedes an in-flight request; its download no longer applies.
        try await stage(h, id, y)
        try await h.until("First replacement in flight") { await h.transfer.waitingIDs == [self.y] }
        let first = try await request(h, id)
        try await stage(h, id, z)
        await h.transfer.releaseAll()
        try await h.until("Second replacement switched") { try await self.accepted(h, id) == [self.z] }
        let candidates = try await h.repo.candidates(entryID: id)
        XCTAssertEqual(candidates.first { $0.providerTrackID == y }?.decision, .pending, "The superseded choice never became accepted")
        XCTAssertEqual(candidates.first { $0.providerTrackID == y }?.evidence["replacementOutcome"], "superseded")
        let switched = try await track(h, id)
        XCTAssertNotEqual(switched, original)

        // A late completion for the superseded request is refused, even with valid audio.
        let late = try await h.repo.commitReplacement(entryID: id, candidateID: try XCTUnwrap(UUID(uuidString: first.candidateID)), trackID: original)
        XCTAssertEqual(late, .stale)
        let unchangedAfterLate = try await entry(h, id).localTrackID
        XCTAssertEqual(unchangedAfterLate, switched)

        // A request whose occurrence lost its original audio meanwhile can never apply.
        await h.transfer.hold(true) // Keep the new download in flight while the occurrence changes.
        try await stage(h, id, y)
        let staged = try await request(h, id)
        try await h.repo.removeLocalAssociation(entryID: id)
        let gone = try await h.repo.commitReplacement(entryID: id, candidateID: try XCTUnwrap(UUID(uuidString: staged.candidateID)), trackID: original)
        XCTAssertEqual(gone, .stale)
        let leftover = try await h.repo.replacement(entryID: id)
        XCTAssertNil(leftover, "An unappliable request is discarded, never retried forever")
        let final = try await entry(h, id)
        XCTAssertNotEqual(final.localTrackID, original); XCTAssertEqual(final.status, .unavailable)
    }
}
