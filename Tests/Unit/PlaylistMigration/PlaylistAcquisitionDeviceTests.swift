import Foundation
import GRDB
import XCTest
@testable import OFFLINE

/// Device-reported defects (iPhone 13 Pro Max, build b549926): force-quit recovery order,
/// delayed offline availability, slot accounting. Background-URLSession mode mirrors the
/// production path: the app resolves, iOS transfers, the app verifies and associates.
@MainActor final class PlaylistAcquisitionDeviceRecoveryTests: XCTestCase {
    private let videos = (1...7).map(AcquisitionHarness.video)

    func testForceQuitRestartsInterruptedSongsBeforeNewerOnesWithoutDuplicates() async throws {
        let h = try harness(limit: 3, systemTransfers: true)
        let p = try await h.playlist("Force quit", videos)
        try await h.until("Three background transfers") { h.system?.tasks.count == 3 }
        let original = try XCTUnwrap(h.system).tasks
        XCTAssertEqual(Set(try original.compactMap { try h.video(of: $0) }), Set(videos[0..<3]))

        // Force quit: iOS cancels the transfers. On relaunch the sessions enumerate no
        // tasks, and the cancellation callbacks (reason: force quit) arrive while the
        // relaunched app is still reconciling.
        let next = AcquisitionTestSystem(); next.holdInventory = true
        await h.relaunch(system: next)
        for task in original { h.downloads.backgroundEnded(task, failure: .terminated) }
        next.holdInventory = false
        try await h.until("Three restarted transfers") { next.tasks.count == 3 }
        await h.settle()
        XCTAssertEqual(Set(try next.tasks.compactMap { try h.video(of: $0) }), Set(videos[0..<3]),
                       "Interrupted songs keep their queue position ahead of newer songs")
        XCTAssertEqual(next.created, 3, "The configured limit is respected after recovery")
        XCTAssertTrue(try h.jobs().filter { videos[3...].contains($0.sourceIdentifier ?? "") }.allSatisfy { $0.state == .queued })
        // A late callback from the superseded generation never touches the new transfer.
        h.downloads.backgroundEnded(original[0], failure: .connection)
        XCTAssertEqual(try h.jobs().first { $0.sourceIdentifier == videos[0] }?.state, .downloading)
        XCTAssertEqual(h.downloads.transferSlotsInUse, 3, "No stale reservation holds a slot")

        // Finish everything in arbitrary order; each song becomes playable as it completes.
        var finished = Set<String>()
        while finished.count < videos.count {
            try await h.until("Next transfer") { !next.tasks.isEmpty }
            let task = next.tasks[next.tasks.count - 1]
            let video = try XCTUnwrap(try h.video(of: task))
            try h.finishSystemTransfer(video)
            finished.insert(video)
            let index = try XCTUnwrap(videos.firstIndex(of: video))
            try await h.until("\(video) available offline") { try await h.entries(p.session)[index].status == .ready }
        }
        try await h.until("Playlist offline") { try await h.allReady(p.session) }
        // Repeated launches: no duplicated jobs, files or transfers.
        for _ in 0..<2 {
            let fresh = AcquisitionTestSystem()
            await h.relaunch(system: fresh)
            await h.settle()
            XCTAssertEqual(fresh.created, 0, "Completed audio is never transferred again")
        }
        XCTAssertEqual(try h.jobs().count, videos.count)
        let tracks = try await h.trackCount()
        XCTAssertEqual(tracks, videos.count)
        let positions = try await h.entries(p.session).map(\.position)
        XCTAssertEqual(positions, Array(0..<videos.count))
    }

    func testForceQuitCancellationIsClassifiedAsTerminationNotConnectionLoss() {
        let forceQuit = NSError(domain: NSURLErrorDomain, code: NSURLErrorCancelled,
                                userInfo: [NSURLErrorBackgroundTaskCancelledReasonKey: NSURLErrorCancelledReasonUserForceQuitApplication])
        XCTAssertEqual(DownloadFailure.background(forceQuit), .terminated)
        let refreshDisabled = NSError(domain: NSURLErrorDomain, code: NSURLErrorCancelled,
                                      userInfo: [NSURLErrorBackgroundTaskCancelledReasonKey: NSURLErrorCancelledReasonBackgroundUpdatesDisabled])
        XCTAssertEqual(DownloadFailure.background(refreshDisabled), .terminated)
        XCTAssertEqual(DownloadFailure.background(NSError(domain: NSURLErrorDomain, code: NSURLErrorCancelled)), .connection, "An app-initiated cancel is not a termination")
        XCTAssertEqual(DownloadFailure.background(URLError(.networkConnectionLost)), .connection)
        XCTAssertNil(DownloadFailure.background(nil))
    }

    func testCompletedTransferIsVerifiedAndAssociatedWithoutWaitingForATransferSlot() async throws {
        let h = try harness(limit: 1, systemTransfers: true)
        let a = videos[0], b = videos[1]
        let p = try await h.playlist("Order", [a, b])
        try await h.until("First transfer") { try h.systemTask(for: a) != nil }
        // a's connection drops; b takes the only slot.
        let first = try XCTUnwrap(try h.systemTask(for: a))
        h.system?.tasks.removeAll { $0.number == first.number }
        h.downloads.backgroundEnded(first, failure: .connection)
        try await h.until("Second song takes the slot") { try h.systemTask(for: b) != nil }
        // Back in the foreground, a is pending again and is ahead of b in queue order.
        h.downloads.setForeground(true)
        try await h.until("a requeued") { try h.jobs().first { $0.sourceIdentifier == a }?.state == .queued }
        // b's bytes arrive while a waits for the slot. b must not wait for a's transfer.
        try h.finishSystemTransfer(b)
        try await h.until("b available offline immediately") { try await h.entries(p.session)[1].status == .ready }
        let rows = try h.repo.rows(playlistID: try XCTUnwrap(p.session.destinationPlaylistID))
        XCTAssertNotNil(rows[1].playableTrack, "Offline availability is in the database the UI observes")
        try await h.until("a transfers in the freed slot") { try h.systemTask(for: a) != nil }
        let aEntry = try await h.entries(p.session)[0]
        XCTAssertEqual(aEntry.status, .matched, "a is not marked ready before its audio is verified")
        XCTAssertEqual(h.downloads.transferSlotsInUse, 1)
        try h.finishSystemTransfer(a)
        try await h.until("Playlist offline") { try await h.allReady(p.session) }
    }

    func testOutOfOrderCompletionsAssociateIndependently() async throws {
        let h = try harness(limit: 3, holding: true)
        let p = try await h.playlist("Out of order", Array(videos[0..<3]))
        try await h.until("Three transfers") { await h.transfer.waiting == 3 }
        await h.transfer.release(videos[2])
        try await h.until("Third song offline first") { try await h.entries(p.session)[2].status == .ready }
        var entries = try await h.entries(p.session)
        XCTAssertEqual(entries[0].status, .matched); XCTAssertEqual(entries[1].status, .matched)
        let stillWaiting = await h.transfer.waitingIDs
        XCTAssertEqual(stillWaiting, Array(videos[0..<2]), "Unrelated transfers continue concurrently")
        await h.transfer.release(videos[0])
        try await h.until("First song offline") { try await h.entries(p.session)[0].status == .ready }
        entries = try await h.entries(p.session)
        XCTAssertEqual(entries[1].status, .matched)
        await h.transfer.releaseAll()
        try await h.until("Playlist offline") { try await h.allReady(p.session) }
    }

    func testEveryFreeSlotIsFilledPromptlyForLimitsOneTwoAndThree() async throws {
        for limit in 1...3 {
            let h = try harness(limit: limit, systemTransfers: true)
            let p = try await h.playlist("Limit \(limit)", Array(videos[0..<5]))
            let system = try XCTUnwrap(h.system)
            try await h.until("\(limit) transfers start together", timeout: 5) { system.tasks.count == limit }
            await h.settle()
            XCTAssertEqual(system.created, limit, "Never more than the configured limit")
            XCTAssertEqual(h.downloads.transferSlotsInUse, limit, "Each transfer is counted exactly once")
            // A finished transfer frees exactly one slot, which is refilled.
            let video = try XCTUnwrap(try h.video(of: system.tasks[0]))
            try h.finishSystemTransfer(video)
            try await h.until("Freed slot refilled", timeout: 5) { system.created == limit + 1 }
            await h.settle()
            XCTAssertEqual(system.tasks.count, limit)
            XCTAssertLessThanOrEqual(h.downloads.transferSlotsInUse, limit)
            _ = p
            await h.terminate()
        }
    }
}

/// Confirmed-download batch notifications and the full-playlist notification.
@MainActor final class PlaylistAcquisitionNotificationTests: XCTestCase {
    private func control(_ h: AcquisitionHarness, _ session: PlaylistMigrationSession) async throws -> AcquisitionControlRecord? {
        try await h.storage.database.dbQueue.read { try AcquisitionControlRecord.fetchOne($0, key: session.id.uuidString) }
    }

    func testSixteenConfirmedSongsInATwoHundredSongPlaylistNotifyOnce() async throws {
        let h = try harness()
        let videos: [String?] = (1...16).map(AcquisitionHarness.video) + Array(repeating: nil, count: 184)
        let p = try await h.playlist("My Spotify Favorites", videos)
        try await h.until("Confirmed downloads notification") { h.notifier.batches.count == 1 }
        XCTAssertEqual(h.notifier.batchTitles, ["Confirmed Downloads Complete"])
        XCTAssertEqual(h.notifier.batches[0], "All 16 confirmed songs in “My Spotify Favorites” are available offline. 184 songs still need attention.")
        XCTAssertTrue(h.notifier.ready.isEmpty, "Never claims the whole 200-song playlist is offline")
        let entries = try await h.entries(p.session)
        XCTAssertEqual(entries.filter { $0.status == .ready }.count, 16)
        try await Task.sleep(for: .milliseconds(500))
        await h.settle()
        XCTAssertEqual(h.notifier.batches.count, 1, "Not repeated after the batch")
        await h.relaunch()
        await h.settle()
        XCTAssertEqual(h.notifier.batches.count, 1, "Not repeated after relaunch")
        let state = try await control(h, p.session)
        XCTAssertEqual(state?.batchOutcome, .delivered)
        XCTAssertEqual(state?.resolvedBatch, state?.currentBatch)
    }

    func testConfirmationsDuringABatchJoinItAndALaterBatchNotifiesAgain() async throws {
        let h = try harness(holding: true, quiet: 1)
        let videos = (1...3).map(AcquisitionHarness.video)
        let p = try await h.playlist("Gaps", [videos[0], nil, nil, nil, nil])
        try await h.until("First download in progress") { await h.transfer.waiting == 1 }
        // The user confirms another song while the first is still downloading.
        try await h.confirm(p.entries[1], video: videos[1])
        try await h.until("Second download in progress") { await h.transfer.waiting == 2 }
        await h.transfer.releaseAll()
        try await h.until("One notification for the whole batch") { h.notifier.batches.count == 1 }
        XCTAssertEqual(h.notifier.batches[0], "All 2 confirmed songs in “Gaps” are available offline. 3 songs still need attention.")
        try await Task.sleep(for: .milliseconds(1300))
        await h.settle()
        XCTAssertEqual(h.notifier.batches.count, 1, "No notification per individual download")
        // A new confirmation after the batch was reported starts a new batch.
        try await h.confirm(p.entries[2], video: videos[2])
        try await h.until("Second batch notification") { h.notifier.batches.count == 2 }
        XCTAssertEqual(h.notifier.batches[1], "1 confirmed song in “Gaps” is available offline. 2 songs still need attention.")
        let state = try await control(h, p.session)
        XCTAssertEqual(state?.currentBatch, 1)
        XCTAssertEqual(state?.resolvedBatch, 1)
    }

    func testAllTwoHundredVerifiedSendsOnlyThePlaylistReadyNotification() async throws {
        // A wider quiet period: 200 sequential confirmations must stay one batch.
        let h = try harness(quiet: 3)
        // 200 occurrences sharing 10 recordings (repeats across the playlist).
        let videos: [String?] = (0..<200).map { AcquisitionHarness.video(1 + $0 % 10) }
        let p = try await h.playlist("Full", videos)
        try await h.until("Playlist ready notification", timeout: 60) { h.notifier.ready.count == 1 }
        XCTAssertEqual(h.notifier.ready, ["All 200 songs in “Full” are available offline."])
        let ready = try await h.allReady(p.session)
        XCTAssertTrue(ready)
        await h.settle()
        XCTAssertTrue(h.notifier.batches.isEmpty, "The full-playlist notification concludes the batch; no second notification")
        XCTAssertEqual(try h.jobs().count, 10)
        let state = try await control(h, p.session)
        XCTAssertEqual(state?.readyOutcome, .delivered)
        XCTAssertNotNil(state?.readyNotifiedAt)
    }

    func testDeniedPermissionNeverRecordsADeliveryAndIsNotRetried() async throws {
        let h = try harness()
        h.notifier.permitted = false
        let full = try await h.playlist("Denied full", [AcquisitionHarness.video(1)])
        let part = try await h.playlist("Denied part", [AcquisitionHarness.video(2), nil])
        try await h.until("Downloads finish regardless of permission") {
            let a = try await h.allReady(full.session), b = try await h.entries(part.session)[0].status == .ready
            return a && b
        }
        try await h.until("Both events evaluated") { h.notifier.attempts.count == 2 }
        await h.settle()
        XCTAssertTrue(h.notifier.delivered.isEmpty)
        let fullState = try await control(h, full.session), partState = try await control(h, part.session)
        XCTAssertNil(fullState?.readyNotifiedAt, "No false delivered marker")
        XCTAssertEqual(fullState?.readyOutcome, .notPermitted)
        XCTAssertEqual(partState?.batchOutcome, .notPermitted)
        await h.relaunch()
        await h.settle()
        XCTAssertEqual(h.notifier.attempts.count, 2, "A denied event is not retried or spammed")
    }

    func testTransientDeliveryFailureIsRetriedBoundedThenDelivered() async throws {
        let h = try harness(quiet: 0.1)
        h.notifier.transientFailures = 2
        let p = try await h.playlist("Transient", [AcquisitionHarness.video(1), nil])
        try await h.until("Delivered after retries") { h.notifier.batches.count == 1 }
        XCTAssertEqual(h.notifier.attempts.count, 3, "Two transient failures, then one delivery")
        let state = try await control(h, p.session)
        XCTAssertEqual(state?.batchOutcome, .delivered)
    }

    func testFailedRecordingsAreReportedAsPartialCompletion() async throws {
        let h = try harness()
        let ok = AcquisitionHarness.video(1), gone = AcquisitionHarness.video(2), corrupt = AcquisitionHarness.video(3)
        h.preparer.fail(gone, with: .videoUnavailable)
        await h.transfer.corrupt(corrupt)
        _ = try await h.playlist("Fail", [ok, gone, corrupt, nil, nil])
        try await h.until("Partial batch result") { h.notifier.batches.count == 1 }
        XCTAssertEqual(h.notifier.batchTitles, ["Confirmed Downloads Finished"])
        XCTAssertEqual(h.notifier.batches[0], "1 of 3 confirmed songs in “Fail” are available offline. 2 could not be downloaded. 4 songs still need attention.")
        XCTAssertTrue(h.notifier.ready.isEmpty)
    }

    func testFilesImportCompletesThePlaylistAndSendsTheReadyNotification() async throws {
        let h = try harness()
        let x = AcquisitionHarness.video(1), z = AcquisitionHarness.video(3)
        h.preparer.fail(z, with: .videoUnavailable)
        let p = try await h.playlist("Files", [x, z])
        try await h.until("Partial result") { h.notifier.batches.count == 1 }
        let entry = try await h.entries(p.session)[1]
        let file = h.fixture.root.appendingPathComponent("My Local Copy.m4a")
        try AcquisitionToneAudio.write(to: file, seed: 99)
        let imported = try await h.storage.importAudio(from: file)
        try await h.repo.confirmImportedRecording(for: entry, trackID: imported.track.id)
        try await h.until("Playlist ready notification") { h.notifier.ready.count == 1 }
        XCTAssertEqual(h.notifier.ready, ["All 2 songs in “Files” are available offline."])
        let resolved = try await h.entries(p.session)
        XCTAssertEqual(resolved.map(\.id), p.entries.map(\.id), "No new occurrence is created")
        XCTAssertEqual(resolved[1].localTrackID, imported.track.id)
        let candidates = try await h.repo.candidates(entryID: entry.id)
        XCTAssertEqual(candidates.filter { $0.decision == .accepted }.map(\.provider), ["local"])
        XCTAssertEqual(candidates.first { $0.provider == "youtube" }?.evidence["supersededBy"], "local-file", "The YouTube decision is kept as evidence")
        await h.relaunch()
        await h.settle()
        XCTAssertEqual(h.notifier.ready.count, 1)
    }
}
