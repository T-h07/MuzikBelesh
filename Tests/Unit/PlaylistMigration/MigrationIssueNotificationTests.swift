import Foundation
import GRDB
import XCTest
@testable import OFFLINE

/// Phase 10.7 aggregate notifications (T32–T38). One event per migration and processing
/// cycle, durable across restarts, coordinated with Phase 10.5 batch notifications.
@MainActor final class MigrationIssueNotificationTests: XCTestCase {

    /// Moves a playlist through an unsettled observation (work remaining) so that the
    /// next settled observation ends a processing cycle.
    private func begin(_ f: IssueFixture, _ p: (session: PlaylistMigrationSession, entries: [PlaylistMigrationEntry])) async throws {
        try await f.intent(p.session, "running")
        await f.reconcile()
        XCTAssertEqual(f.coordinator.states[p.session.id]?.settled, false)
    }
    private func settleWithIssues(_ f: IssueFixture, _ p: (session: PlaylistMigrationSession, entries: [PlaylistMigrationEntry])) async throws {
        for entry in p.entries { try await f.set(entry, .unavailable); try await f.checkpoint(entry, "noMatch") }
        try await f.intent(p.session, "completed")
        await f.reconcile()
    }

    // T32
    func testFullyReadyPlaylistProducesExactlyOneCompletionEvent() async throws {
        let f = try issueFixture()
        let p = try await f.playlist("Ready", count: 2)
        try await begin(f, p)
        XCTAssertTrue(f.notifier.attempts.isEmpty)
        try await f.set(p.entries[0], .ready, track: f.fixture.ids[0]); try await f.set(p.entries[1], .ready, track: f.fixture.ids[1])
        try await f.intent(p.session, "completed")
        await f.reconcile()
        for _ in 0..<3 { await f.reconcile() }
        XCTAssertEqual(f.notifier.delivered.count, 1)
        let request = try XCTUnwrap(f.notifier.delivered.first)
        XCTAssertEqual(request.title, "Playlist Ready Offline")
        XCTAssertEqual(request.body, "All 2 songs in “Ready” are available offline.")
        XCTAssertEqual(request.identifier, "playlist-ready-" + p.session.id.uuidString)
        XCTAssertFalse(request.opensIssues)
        let events = try await f.issues.events(migrationID: p.session.id)
        XCTAssertEqual(events.map(\.kind), [.fullyReady]); XCTAssertEqual(events.first?.delivery, .delivered)
        XCTAssertEqual(events.first?.cycle, 1)
    }

    // T33
    func testSettledMigrationWithManyFailuresSendsOneAggregateNotification() async throws {
        let f = try issueFixture()
        let p = try await f.playlist("Fifty", count: 52)
        try await begin(f, p)
        try await f.set(p.entries[0], .ready, track: f.fixture.ids[0])
        try await f.set(p.entries[1], .skipped)
        for entry in p.entries.dropFirst(2) { try await f.set(entry, .unavailable); try await f.checkpoint(entry, "noMatch") }
        try await f.intent(p.session, "completed")
        await f.reconcile()
        XCTAssertEqual(f.notifier.attempts.count, 1, "50 failed songs never produce 50 notifications")
        let request = try XCTUnwrap(f.notifier.delivered.first)
        XCTAssertEqual(request.title, "Playlist Needs Attention")
        XCTAssertEqual(request.body, "1 of 52 songs in “Fifty” are available offline. 50 still need your review. 1 was skipped.")
        XCTAssertTrue(request.opensIssues)
        XCTAssertEqual(request.identifier, "migration-attention-\(p.session.id.uuidString)-1")
        XCTAssertFalse(request.body.contains("All "), "Never claims completion while songs remain unresolved")
    }

    // T34
    func testRepeatedLaunchesAndObservationsNeverReplayAHandledEvent() async throws {
        let f = try issueFixture()
        let p = try await f.playlist("Relaunch", count: 3)
        try await begin(f, p)
        try await settleWithIssues(f, p)
        XCTAssertEqual(f.notifier.attempts.count, 1)
        for _ in 0..<4 {
            await f.relaunch()
            f.coordinator.applicationDidBecomeActive()
            await f.reconcile(); await f.reconcile()
        }
        XCTAssertEqual(f.notifier.attempts.count, 1, "Reopening the app never replays handled events")
        // Opening the report does not create events either.
        _ = try await f.report(p.session)
        await f.reconcile()
        XCTAssertEqual(f.notifier.attempts.count, 1)
        let events = try await f.issues.events(migrationID: p.session.id)
        XCTAssertEqual(events.count, 1)

        // A migration observed for the first time when it is already settled (for
        // example right after upgrading) is a baseline, never a surprise notification.
        let existing = try await f.playlist("Upgraded", count: 2)
        for entry in existing.entries { try await f.set(entry, .ready, track: f.fixture.ids[0]) }
        try await f.intent(existing.session, "completed")
        await f.reconcile()
        XCTAssertEqual(f.notifier.attempts.count, 1)
        let baseline = try await f.issues.events(migrationID: existing.session.id)
        XCTAssertTrue(baseline.isEmpty)
    }

    // T35
    func testDeniedPermissionIsRecordedOnceAndReportingStillWorks() async throws {
        let f = try issueFixture()
        f.notifier.permitted = false
        let p = try await f.playlist("Denied", count: 2)
        try await begin(f, p)
        try await settleWithIssues(f, p)
        for _ in 0..<3 { f.clock.advance(600); await f.reconcile() }
        XCTAssertEqual(f.notifier.attempts.count, 1, "No retry loop when notifications are not allowed")
        XCTAssertTrue(f.notifier.delivered.isEmpty)
        let events = try await f.issues.events(migrationID: p.session.id)
        XCTAssertEqual(events.first?.delivery, .notPermitted)
        let open = try await f.open(p.session)
        XCTAssertEqual(open.count, 2, "Issue persistence never depends on notifications")
        XCTAssertEqual(f.coordinator.summaries[p.session.id]?.outcome, .finishedWithIssues)

        // Transient failures retry with backoff, then stop at the bound.
        let g = try issueFixture()
        g.notifier.transientFailures = 10
        let q = try await g.playlist("Flaky", count: 1)
        try await begin(g, q)
        try await settleWithIssues(g, q)
        for _ in 0..<6 { g.clock.advance(1); await g.reconcile() }
        XCTAssertEqual(g.notifier.attempts.count, MigrationIssueRepository.maximumDeliveryAttempts)
        let flaky = try await g.issues.events(migrationID: q.session.id)
        XCTAssertEqual(flaky.first?.delivery, .abandoned)
        XCTAssertEqual(flaky.first?.attempts, MigrationIssueRepository.maximumDeliveryAttempts)
    }

    // T36
    func testFinalBatchNotificationIsNotDuplicatedByTheMigrationNotification() async throws {
        let f = try issueFixture()
        let p = try await f.playlist("Batch", count: 2)
        try await f.set(p.entries[0], .matched)
        try await f.link(p.entries[0], .waiting, jobState: .downloading)
        try await f.set(p.entries[1], .unavailable); try await f.checkpoint(p.entries[1], "noMatch")
        try await f.intent(p.session, "completed")
        let id = p.session.id.uuidString
        try await f.db.write { db in
            try AcquisitionControlRecord(migrationID: id, userPaused: false, readyNotifiedAt: nil, partialNotifiedSummary: nil, updatedAt: Date(),
                                         currentBatch: 1).save(db)
        }
        await f.reconcile()
        XCTAssertEqual(f.coordinator.states[p.session.id]?.settled, false, "A download in flight is not settled")
        // The download fails permanently and Phase 10.5 reports the finished batch.
        try await f.db.write { db in
            try db.execute(sql: "UPDATE migration_acquisitions SET state = 'unsupported', failure = ? WHERE entryID = ?",
                           arguments: [AcquisitionFailureCategory.unsupportedFormat.message, p.entries[0].id.uuidString])
            try db.execute(sql: "UPDATE migration_acquisition_controls SET resolvedBatch = 1, batchOutcome = 'delivered' WHERE migrationID = ?", arguments: [id])
        }
        await f.reconcile()
        XCTAssertTrue(f.notifier.attempts.isEmpty, "The batch notification already reported what needs attention")
        let events = try await f.issues.events(migrationID: p.session.id)
        XCTAssertEqual(events.first?.delivery, .coalesced)

        // A full-playlist completion for a playlist Phase 10.5 downloaded is its event.
        let r = try await f.playlist("Downloaded", count: 1)
        try await f.set(r.entries[0], .matched)
        try await f.link(r.entries[0], .waiting, jobState: .downloading)
        try await f.intent(r.session, "completed")
        await f.reconcile()
        try await f.set(r.entries[0], .ready, track: f.fixture.ids[1])
        try await f.db.write { db in try db.execute(sql: "UPDATE migration_acquisitions SET state = 'ready' WHERE entryID = ?", arguments: [r.entries[0].id.uuidString]) }
        await f.reconcile()
        XCTAssertTrue(f.notifier.attempts.isEmpty, "Never two near-identical Ready notifications")
        let ready = try await f.issues.events(migrationID: r.session.id)
        XCTAssertEqual(ready.map(\.kind), [.fullyReady]); XCTAssertEqual(ready.first?.delivery, .coalesced)

        // A batch resolved long before settling does not suppress the attention event,
        // and a batch that never resolves only delays it for a bounded time.
        let s = try await f.playlist("Later", count: 1)
        try await f.set(s.entries[0], .matched)
        try await f.link(s.entries[0], .waiting, jobState: .downloading)
        try await f.intent(s.session, "completed")
        try await f.db.write { db in
            try AcquisitionControlRecord(migrationID: s.session.id.uuidString, userPaused: false, readyNotifiedAt: nil, partialNotifiedSummary: nil,
                                         updatedAt: Date(), currentBatch: 2, resolvedBatch: 1, batchOutcome: .delivered).save(db)
        }
        await f.reconcile()
        try await f.db.write { db in
            try db.execute(sql: "UPDATE migration_acquisitions SET state = 'failed', failure = ? WHERE entryID = ?",
                           arguments: [AcquisitionFailureCategory.network.message, s.entries[0].id.uuidString])
        }
        await f.reconcile()
        XCTAssertTrue(f.notifier.attempts.isEmpty, "Waits briefly for the pending batch notification")
        f.clock.advance(1)
        await f.reconcile()
        XCTAssertEqual(f.notifier.attempts.map(\.title), ["Playlist Needs Attention"])
    }

    // T37
    func testAttentionNotificationRoutesToTheMigrationIssues() async throws {
        let f = try issueFixture()
        let p = try await f.playlist("Route", count: 1)
        try await begin(f, p)
        try await settleWithIssues(f, p)
        let request = try XCTUnwrap(f.notifier.delivered.first)
        XCTAssertTrue(request.opensIssues)
        XCTAssertNil(f.coordinator.requestedIssuesPlaylistID)
        f.notifier.tap(request)
        XCTAssertEqual(f.coordinator.requestedIssuesPlaylistID, p.session.destinationPlaylistID)
        XCTAssertEqual(AppSheet.migrationIssues(request.playlistID).id, "migration-issues-" + request.playlistID)
        // The delegate distinguishes the destination from the playlist-ready payload.
        XCTAssertEqual(UserNotificationAcquisitionNotifier.destinationKey, "destination")
        XCTAssertEqual(UserNotificationAcquisitionNotifier.issuesDestination, "issues")
        // After invalidation (e.g. a deleted playlist's sheet closing) no stale handler remains.
        await f.coordinator.invalidate()
        XCTAssertNil(f.notifier.onOpenIssues)
    }

    // T38
    func testEventsAreDeduplicatedPerMigrationAndProcessingCycle() async throws {
        let f = try issueFixture()
        let a = try await f.playlist("Alpha", count: 2), b = try await f.playlist("Beta", count: 2)
        try await begin(f, a); try await begin(f, b)
        for entry in a.entries + b.entries { try await f.set(entry, .unavailable); try await f.checkpoint(entry, "noMatch") }
        try await f.intent(a.session, "completed"); try await f.intent(b.session, "completed")
        await f.reconcile(); await f.reconcile()
        XCTAssertEqual(f.notifier.delivered.count, 2)
        XCTAssertEqual(Set(f.notifier.delivered.map(\.identifier)), ["migration-attention-\(a.session.id.uuidString)-1", "migration-attention-\(b.session.id.uuidString)-1"])
        XCTAssertEqual(Set(f.notifier.delivered.map(\.playlistID)), [a.session.destinationPlaylistID!, b.session.destinationPlaylistID!])

        // A new processing cycle of Alpha (retry → work → settled again) is a new event;
        // Beta is unaffected.
        try await f.intent(a.session, "running")
        try await f.set(a.entries[0], .pending)
        await f.reconcile()
        try await f.set(a.entries[0], .ready, track: f.fixture.ids[0])
        try await f.intent(a.session, "completed")
        await f.reconcile(); await f.reconcile()
        XCTAssertEqual(f.notifier.delivered.count, 3)
        XCTAssertEqual(f.notifier.delivered.last?.identifier, "migration-attention-\(a.session.id.uuidString)-2")
        XCTAssertEqual(f.notifier.delivered.last?.body, "1 of 2 songs in “Alpha” are available offline. 1 still needs your review.")
        let alpha = try await f.issues.events(migrationID: a.session.id)
        let beta = try await f.issues.events(migrationID: b.session.id)
        XCTAssertEqual(alpha.map(\.cycle), [1, 2]); XCTAssertEqual(beta.map(\.cycle), [1])
    }
}
