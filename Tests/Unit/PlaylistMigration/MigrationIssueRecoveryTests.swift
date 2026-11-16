import Foundation
import GRDB
import XCTest
@testable import OFFLINE

/// Phase 10.7 recovery actions (T18–T25) and the Phase 10.5/10.6 regressions they touch
/// (T40, T41). Every action is delegated to its owning subsystem, wired as in the app.
@MainActor final class MigrationIssueRecoveryTests: XCTestCase {
    private func title(_ name: String, _ index: Int) -> String { CoordinatorHarness.title(name, index) }

    /// The issue coordinator over a harness's store, delegating to its coordinators.
    private func makeIssues(storage: StorageCoordinator, paths: AppStoragePaths, coordinator: PlaylistMigrationCoordinator?,
                        acquisition: PlaylistAcquisitionCoordinator?, clock: CoordinatorTestClock) -> MigrationIssueCoordinator {
        let value = MigrationIssueCoordinator(repository: MigrationIssueRepository(db: storage.database.dbQueue, paths: paths),
            migrations: storage.playlistMigrations, coordinator: coordinator, acquisition: acquisition, notifier: RecordingIssueNotifier(),
            configuration: IssueFixture.configuration, now: { clock.now }, capacity: { nil })
        addTeardownBlock { await value.invalidate() }
        return value
    }
    private func makeIssues(_ h: CoordinatorHarness) -> MigrationIssueCoordinator {
        makeIssues(storage: h.storage, paths: h.base.fixture.paths, coordinator: h.coordinator, acquisition: h.base.coordinator, clock: h.clock)
    }
    private func row(_ issues: MigrationIssueCoordinator, _ session: PlaylistMigrationSession, _ entry: PlaylistMigrationEntry,
                     file: StaticString = #filePath, line: UInt = #line) throws -> MigrationOccurrenceReport {
        try XCTUnwrap(issues.reports[session.id]?.occurrence(entry.id), file: file, line: line)
    }

    // T18
    func testRetryThisSongRetriesOnlyThatOccurrenceThroughTheScheduler() async throws {
        let h = try await coordinatorHarness()
        let a = try await h.importPlaylist("One", count: 4)
        for index in [1, 2] { await h.discovery.set(title("One", index), [.empty]) }
        try await h.coordinator.startMigration(a.id)
        try await h.complete(a)
        let issues = makeIssues(h)
        await issues.reconcileNow()
        let entries = try await h.entries(a)
        let target = try row(issues, a, entries[1])
        XCTAssertEqual(target.assessment.category, .noReliableMatch)
        XCTAssertTrue(target.assessment.actions.contains(.retrySong))

        let message = try await issues.retry(target)
        XCTAssertEqual(message, "Search queued for retry.", "Reports scheduling, never success")
        try await h.idle()
        for (index, expected) in [(0, 1), (1, 2), (2, 1), (3, 1)] {
            let calls = await h.discovery.calls(for: title("One", index))
            XCTAssertEqual(calls, expected, "Song \(index)")
        }
        await issues.reconcileNow()
        let retried = try row(issues, a, entries[1])
        XCTAssertEqual(retried.assessment.disposition, .needsReview, "The retry found candidates for review")
        let rows = try await issues.repository.issueRows(migrationID: a.id).filter { $0.entryID == entries[1].id }
        let open = rows.filter { $0.resolution == .open }
        XCTAssertEqual(open.count, 1)
        XCTAssertEqual(open.first?.category, retried.assessment.category?.rawValue)
        let review: [MigrationIssueCategory?] = [.ambiguousMatches, .needsConfirmation]
        XCTAssertTrue(review.contains(retried.assessment.category))
        XCTAssertEqual(rows.first { $0.resolution != .open }?.closeReason, MigrationIssueCloseReason.superseded.rawValue)
        XCTAssertEqual(try row(issues, a, entries[2]).assessment.category, .noReliableMatch, "Other songs are unaffected")
        XCTAssertTrue(issues.busyEntries.isEmpty, "No command is left in flight")
    }

    // T18 (downloads) and T41
    func testRetryDownloadIsOwnedByAcquisitionAndCompletedSongsAreReused() async throws {
        let h = try harness(limit: 1)
        let x = AcquisitionHarness.video(1), y = AcquisitionHarness.video(2)
        await h.transfer.corrupt(x)
        let p = try await h.playlist("Download", [x, y])
        try await h.until("Healthy song offline") { try await h.entries(p.session)[1].status == .ready }
        try await h.until("Corrupt audio failed after its bounded retry") { h.coordinator.link(for: p.entries[0].id)?.state == .failed }
        await h.settle()
        let clock = CoordinatorTestClock()
        let issues = makeIssues(storage: h.storage, paths: h.fixture.paths, coordinator: nil, acquisition: h.coordinator, clock: clock)
        await issues.reconcileNow()
        let failed = try row(issues, p.session, p.entries[0])
        XCTAssertEqual(failed.assessment.disposition, .failed)
        XCTAssertEqual(failed.assessment.category, .audioValidationFailed)
        XCTAssertEqual(failed.assessment.stage, .acquisition)
        XCTAssertEqual(failed.assessment.actions.first, .retryDownload)
        let startedBefore = await h.transfer.started

        await h.transfer.heal(x); await h.transfer.seed(x, 9)
        let message = try await issues.retry(failed)
        XCTAssertEqual(message, "Download queued for retry.")
        try await h.until("Retried song offline") { try await h.allReady(p.session) }
        await issues.reconcileNow()
        XCTAssertEqual(try row(issues, p.session, p.entries[0]).assessment.disposition, .playable)
        let rows = try await issues.repository.issueRows(migrationID: p.session.id)
        XCTAssertEqual(rows.count, 1); XCTAssertEqual(rows.first?.resolution, .resolved)
        XCTAssertEqual(rows.first?.closeReason, MigrationIssueCloseReason.conditionCleared.rawValue)
        let started = await h.transfer.started
        XCTAssertEqual(started.filter { $0 == y }.count, startedBefore.filter { $0 == y }.count, "A completed song is never downloaded again")
        XCTAssertEqual(started.filter { $0 == x }.count, startedBefore.filter { $0 == x }.count + 1)
        XCTAssertEqual(issues.reports[p.session.id]?.summary.outcome, .fullyReady)
    }

    // T19
    func testRetryAllEligibleQueuesOnlyTemporaryFailuresWithinLimits() async throws {
        let h = try await coordinatorHarness(limit: 1)
        let a = try await h.importPlaylist("Bulk", count: 6)
        for index in [1, 2] { await h.discovery.set(title("Bulk", index), [.empty]) }
        let unsupported = ["a", "b"].map { CoordinatorDiscovery.videoID(title("Bulk", 4), Character($0)) }
        let corrupt = ["a", "b"].map { CoordinatorDiscovery.videoID(title("Bulk", 5), Character($0)) }
        for video in unsupported { h.base.preparer.fail(video, with: .noCompatibleAudio) }
        for video in corrupt { await h.base.transfer.corrupt(video) }
        try await h.coordinator.startMigration(a.id)
        try await h.complete(a)
        var entries = try await h.entries(a)
        try await h.confirmTop(entries[4]); try await h.confirmTop(entries[5])
        try await h.until("Unsupported and failed downloads settled") {
            h.base.coordinator.link(for: entries[4].id)?.state == .unsupported && h.base.coordinator.link(for: entries[5].id)?.state == .failed
        }
        await h.base.settle()
        let issues = makeIssues(h)
        await issues.reconcileNow()
        let preparedBefore = h.base.preparer.prepared
        for video in corrupt { await h.base.transfer.heal(video) }

        let result = try await issues.retryAllEligible(migrationID: a.id)
        XCTAssertEqual(result.searches, 2, "The two songs without a match")
        XCTAssertEqual(result.downloads, 1, "Only the retryable download failure")
        XCTAssertEqual(result.manual, 3, "Two reviews and one unsupported recording still need the user")
        XCTAssertEqual(result.message, "3 songs queued for retry. 3 still require manual review.")
        try await h.idle()
        try await h.until("Retried download offline") { try await h.entries(a)[5].status == .ready }
        for (index, expected) in [(0, 1), (1, 2), (2, 2), (3, 1), (4, 1), (5, 1)] {
            let calls = await h.discovery.calls(for: title("Bulk", index))
            XCTAssertEqual(calls, expected, "Song \(index)")
        }
        let preparedAfter = h.base.preparer.prepared
        for video in unsupported {
            XCTAssertEqual(preparedAfter.filter { $0 == video }.count, preparedBefore.filter { $0 == video }.count, "Unsupported recordings are never retried blindly")
        }
        let maxSearches = await h.discovery.maxActive
        XCTAssertEqual(maxSearches, 1, "The single matching worker is preserved")
        let maxTransfers = await h.base.transfer.maxActive
        XCTAssertLessThanOrEqual(maxTransfers, 1, "The global download limit is preserved")
        entries = try await h.entries(a)
        let rejected = try await h.repo.candidates(entryID: entries[4].id).filter { $0.decision == .accepted }
        XCTAssertEqual(rejected.count, 1, "The unsupported decision is kept, not re-approved or cleared")
    }

    // T20
    func testManualCandidateConfirmationPreservesSourceAndResolvesOnlyMatching() async throws {
        let f = try issueFixture()
        let p = try await f.playlist("Choose", count: 1)
        try await f.intent(p.session, "completed")
        try await f.set(p.entries[0], .needsReview)
        let candidates = try await f.candidates(p.entries[0], 3)
        try await f.checkpoint(p.entries[0], "review")
        await f.reconcile()
        let open = try await f.open(p.session)
        XCTAssertEqual(open.map(\.category), [MigrationIssueCategory.ambiguousMatches.rawValue])

        let current = try await f.repo.entry(id: p.entries[0].id)
        let chosen = try await f.repo.selectCandidate(for: current, candidateID: candidates[1].id)
        await f.reconcile()
        let entry = try await f.repo.entry(id: p.entries[0].id)
        XCTAssertEqual(entry.source, p.entries[0].source, "Original Spotify metadata and position are preserved")
        XCTAssertEqual(entry.status, .matched)
        XCTAssertEqual(chosen.id, candidates[1].id); XCTAssertEqual(chosen.providerTrackID, candidates[1].providerTrackID)
        let rows = try await f.rows(p.session)
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows.first?.resolution, .resolved, "Confirmation resolves the matching issue")
        let report = try await f.report(p.session)
        XCTAssertEqual(report.occurrence(p.entries[0].id)?.assessment.disposition, .waiting, "Confirmed is not yet offline")
        XCTAssertEqual(report.summary.playable, 0)
        XCTAssertNotEqual(report.summary.outcome, .fullyReady)
    }

    // T21
    func testExistingLibraryRecordingResolvesTheOccurrence() async throws {
        let f = try issueFixture()
        let p = try await f.playlist("Attach", count: 2)
        try await f.intent(p.session, "completed")
        try await f.set(p.entries[0], .ready, track: f.fixture.ids[0])
        try await f.set(p.entries[1], .unavailable); try await f.checkpoint(p.entries[1], "noMatch")
        await f.reconcile()
        let target = try XCTUnwrap(f.coordinator.reports[p.session.id]?.occurrence(p.entries[1].id))
        XCTAssertTrue(target.assessment.actions.contains(.attachLocalRecording))
        let entry = try await f.coordinator.prepareReassociation(target)
        try await f.repo.confirmLocalRecording(for: entry, trackID: f.fixture.ids[2])
        await f.reconcile()
        let report = try XCTUnwrap(f.coordinator.reports[p.session.id])
        XCTAssertEqual(report.occurrence(p.entries[1].id)?.assessment.disposition, .playable)
        XCTAssertEqual(report.occurrence(p.entries[1].id)?.position, 1)
        XCTAssertEqual(report.summary.outcome, .fullyReady)
        let open = try await f.open(p.session)
        XCTAssertTrue(open.isEmpty)
    }

    // T22
    func testImportedFileIsAssociatedOnlyAfterValidationAndConfirmation() async throws {
        let f = try issueFixture()
        let p = try await f.playlist("Import", count: 2)
        try await f.intent(p.session, "completed")
        for entry in p.entries { try await f.set(entry, .unavailable); try await f.checkpoint(entry, "noMatch") }
        await f.reconcile()
        let file = try f.fixture.sources().appendingPathComponent("chosen.wav")
        try LibraryFixture.wav(seed: 9).write(to: file)
        let imported = try await f.storage.importAudio(from: file)
        // Importing alone associates nothing.
        await f.reconcile()
        XCTAssertEqual(f.coordinator.summaries[p.session.id]?.playable, 0)
        let target = try XCTUnwrap(f.coordinator.reports[p.session.id]?.occurrence(p.entries[1].id))
        let entry = try await f.coordinator.prepareReassociation(target)
        try await f.repo.confirmImportedRecording(for: entry, trackID: imported.track.id)
        // A stale snapshot of the occurrence is refused.
        do { try await f.repo.confirmImportedRecording(for: entry, trackID: imported.track.id); XCTFail("Stale confirmation must fail") }
        catch {}
        await f.reconcile()
        let after = try await f.repo.entries(migrationID: p.session.id)
        XCTAssertEqual(after.count, 2, "No new Spotify occurrence is created")
        XCTAssertEqual(after[1].localTrackID, imported.track.id); XCTAssertEqual(after[1].position, 1)
        XCTAssertNil(after[0].localTrackID)
        let manual = try await f.count("playlist_local_occurrences")
        XCTAssertEqual(manual, 0, "Resolution never appends a manual playlist item")
        let report = try XCTUnwrap(f.coordinator.reports[p.session.id])
        XCTAssertEqual(report.summary.playable, 1); XCTAssertEqual(report.summary.attention, 1)
    }

    // T23
    func testSkipIsDurableStopsSchedulingAndCanBeRestored() async throws {
        let f = try issueFixture()
        let p = try await f.playlist("Skip", count: 3)
        try await f.intent(p.session, "running")
        try await f.set(p.entries[0], .pending)
        try await f.set(p.entries[1], .failed); try await f.checkpoint(p.entries[1], "provider", retryable: true)
        try await f.retryRecord(p.entries[1], failures: 4, eligible: false, next: nil)
        try await f.set(p.entries[2], .ready, track: f.fixture.ids[0])
        await f.reconcile()
        let store = MigrationCoordinatorRepository(db: f.db)
        var eligible = try await store.eligibleCount(migrationID: p.session.id, algorithm: CandidateScoringEngine.algorithmVersion)
        XCTAssertEqual(eligible, 1)
        let target = try XCTUnwrap(f.coordinator.reports[p.session.id]?.occurrence(p.entries[1].id))
        XCTAssertEqual(target.assessment.disposition, .failed)
        try await f.coordinator.skip(target)
        await f.reconcile()

        let entry = try await f.repo.entry(id: p.entries[1].id)
        XCTAssertEqual(entry.status, .skipped); XCTAssertEqual(entry.source, p.entries[1].source)
        let retry = try await store.retryRecord(entryID: p.entries[1].id)
        XCTAssertNil(retry, "No further automatic work is scheduled")
        let due = try await store.dueRetries(migrationID: p.session.id, now: .distantFuture, limit: 10, automatic: true)
        XCTAssertFalse(due.contains(p.entries[1].id))
        let report = try XCTUnwrap(f.coordinator.reports[p.session.id])
        XCTAssertEqual(report.rows(.skipped).map(\.id), [p.entries[1].id], "Skipped songs stay visible")
        XCTAssertEqual(report.summary.skipped, 1)
        let rows = try await f.rows(p.session)
        XCTAssertEqual(rows.first?.closeReason, MigrationIssueCloseReason.skipped.rawValue)
        let audit = try await f.repo.issues(migrationID: p.session.id).filter { $0.code == "user.skip" }
        XCTAssertEqual(audit.count, 1, "The user action is recorded durably")
        // Ready songs cannot be skipped.
        let ready = try XCTUnwrap(report.occurrence(p.entries[2].id))
        do { try await f.coordinator.skip(ready); XCTFail("A verified song must not be skipped") }
        catch let error as MigrationIssueCommandError { XCTAssertEqual(error, .notApplicable) }

        await f.relaunch(); await f.reconcile()
        let restored = try XCTUnwrap(f.coordinator.reports[p.session.id]?.occurrence(p.entries[1].id))
        XCTAssertEqual(restored.assessment.disposition, .skipped, "Skip survives restart")
        try await f.coordinator.restore(restored)
        let back = try await f.repo.entry(id: p.entries[1].id)
        XCTAssertEqual(back.status, .pending)
        eligible = try await store.eligibleCount(migrationID: p.session.id, algorithm: CandidateScoringEngine.algorithmVersion)
        XCTAssertEqual(eligible, 2, "A restored song is matched again")
    }

    // T24
    func testSkippingOneOccurrenceKeepsASharedDownloadForAnotherPlaylist() async throws {
        let h = try harness(limit: 2, holding: true)
        let video = AcquisitionHarness.video(42)
        let a = try await h.playlist("Shared A", [video]), b = try await h.playlist("Shared B", [video])
        try await h.until("Shared transfer in flight") { await h.transfer.waiting == 1 }
        let clock = CoordinatorTestClock()
        let issues = makeIssues(storage: h.storage, paths: h.fixture.paths, coordinator: nil, acquisition: h.coordinator, clock: clock)
        await issues.reconcileNow()
        let target = try row(issues, a.session, a.entries[0])
        XCTAssertEqual(target.assessment.disposition, .waiting)
        XCTAssertTrue(target.assessment.actions.contains(.skip))
        try await issues.skip(target)
        await h.settle()
        let job = try XCTUnwrap(try h.jobs().first { $0.sourceIdentifier == video })
        XCTAssertFalse([.paused, .cancelled].contains(job.state), "B still needs the shared download")
        await h.transfer.releaseAll()
        try await h.until("B offline") { try await h.allReady(b.session) }
        let skipped = try await h.entries(a.session)[0]
        XCTAssertEqual(skipped.status, .skipped); XCTAssertNil(skipped.localTrackID)
        XCTAssertEqual(try h.jobs().count, 1)
        let tracks = try await h.trackCount()
        XCTAssertEqual(tracks, 1, "The downloaded recording stays in the library")
        let started = await h.transfer.started
        XCTAssertEqual(started, [video])
        let superseded = try await h.repo.candidates(entryID: a.entries[0].id).filter { $0.evidence["supersededBy"] == "skip" }
        XCTAssertEqual(superseded.count, 1, "The earlier decision is kept as evidence")
    }

    // T25
    func testExhaustedRetriesSettleWithoutLooping() async throws {
        let f = try issueFixture()
        let p = try await f.playlist("Exhausted", count: 1)
        try await f.intent(p.session, "completed")
        try await f.set(p.entries[0], .failed); try await f.checkpoint(p.entries[0], "provider", retryable: true)
        try await f.retryRecord(p.entries[0], failures: 4, eligible: false, next: nil)
        let store = MigrationCoordinatorRepository(db: f.db)
        let record = try await store.retryRecord(entryID: p.entries[0].id)
        for _ in 0..<3 { f.clock.advance(100_000); await f.reconcile() }
        let report = try XCTUnwrap(f.coordinator.reports[p.session.id])
        let value = try XCTUnwrap(report.occurrence(p.entries[0].id)).assessment
        XCTAssertEqual(value.disposition, .failed)
        XCTAssertEqual(value.status, "Automatic retries exhausted")
        XCTAssertEqual(value.retryCount, 4)
        XCTAssertEqual(report.summary.outcome, .finishedWithIssues, "Settled, not looping")
        let due = try await store.dueRetries(migrationID: p.session.id, now: .distantFuture, limit: 10, automatic: true)
        XCTAssertTrue(due.isEmpty, "Nothing is rescheduled automatically")
        let after = try await store.retryRecord(entryID: p.entries[0].id)
        XCTAssertEqual(after, record, "Issue reconciliation never resets retry counters")
    }

    // T40
    func testBulkRetryNeverOverridesAUserPause() async throws {
        let h = try await coordinatorHarness()
        let a = try await h.importPlaylist("Hold", count: 3)
        await h.discovery.setDefault(.empty)
        try await h.coordinator.startMigration(a.id)
        try await h.complete(a)
        try await h.coordinator.pauseMigration(a.id)
        let issues = makeIssues(h)
        let calls = await h.discovery.total
        let result = try await issues.retryAllEligible(migrationID: a.id)
        XCTAssertEqual(result.searches, 3); XCTAssertTrue(result.paused)
        XCTAssertTrue(result.message.contains("resume"))
        await h.coordinator.reconcileAll(); try await h.idle()
        let paused = await h.discovery.total
        XCTAssertEqual(paused, calls, "Paused playlists stay paused")
        let intent = try await h.intent(a)
        XCTAssertEqual(intent, "userPaused")
        try await h.relaunch()
        await h.coordinator.reconcileAll(); try await h.idle()
        let relaunched = await h.discovery.total
        XCTAssertEqual(relaunched, calls, "Still paused after a restart")
        try await h.coordinator.resumeMigration(a.id)
        try await h.idle()
        let resumed = await h.discovery.total
        XCTAssertEqual(resumed, calls + 3, "The queued retries run once the user resumes")
    }
}
