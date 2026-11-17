import Foundation
import XCTest
@testable import OFFLINE

/// Device-reported queue stall (48-song playlist, final song "Queued" with nothing
/// downloading until Pause → Continue). Background-URLSession mode, as on device.
@MainActor final class PlaylistAcquisitionQueueStallTests: XCTestCase {
    private let a = AcquisitionHarness.video(1), b = AcquisitionHarness.video(2), c = AcquisitionHarness.video(3)

    /// Root cause: a task created during a background execution window is discretionary
    /// and may never start; it held the last slot, so the final song stayed queued.
    func testBackgroundCreatedTransferThatNeverStartsIsRecreatedOnForegroundReturn() async throws {
        let h = try harness(limit: 1, systemTransfers: true, backgroundExecution: true)
        let system = try XCTUnwrap(h.system)
        let p = try await h.playlist("Stall", [a, b])
        try await h.until("First transfer") { try h.systemTask(for: a) != nil }
        h.downloads.setForeground(false)
        // iOS wakes the app for a's finished transfer; the bounded window verifies a and
        // creates b's task while the app is still in the background.
        try h.finishSystemTransfer(a)
        try await h.until("Final song's task created in the background") { try h.systemTask(for: b) != nil }
        try await h.until("First song offline") { try await h.entries(p.session)[0].status == .ready }
        let deferred = try XCTUnwrap(try h.systemTask(for: b))
        XCTAssertEqual(h.downloads.transferSlotsInUse, 1, "The deferred task holds the only slot")

        // The user returns. No Pause/Continue: the zero-byte background task is recreated
        // as a foreground task, once, at the same queue position.
        h.downloads.setForeground(true)
        try await h.until("Recreated in the foreground") { try h.systemTask(for: b) != nil && system.cancelled.contains(deferred.number) }
        let recreated = try XCTUnwrap(try h.systemTask(for: b))
        XCTAssertNotEqual(recreated.number, deferred.number)
        XCTAssertEqual(system.created, 3, "a, b in the background, b again in the foreground")
        // Repeated health checks never restart it again or duplicate anything.
        for _ in 0..<3 { h.downloads.checkQueueHealth() }
        await h.settle()
        XCTAssertEqual(system.created, 3)
        XCTAssertEqual(try h.jobs().count, 2)

        // Pause/Continue still behave as user controls after automatic recovery.
        await h.coordinator.pause(migrationID: p.session.id.uuidString)
        try await h.until("Paused") { try h.jobs().first { $0.sourceIdentifier == b }?.state == .paused }
        XCTAssertTrue(system.cancelled.contains(recreated.number))
        h.downloads.checkQueueHealth()
        await h.settle()
        XCTAssertEqual(system.created, 3, "Recovery never resumes a user-paused playlist")
        await h.coordinator.continueDownloads(migrationID: p.session.id.uuidString)
        try await h.until("Resumed") { system.created == 4 }
        try h.finishSystemTransfer(b)
        try await h.until("Playlist offline") { try await h.allReady(p.session) }
        let tracks = try await h.trackCount()
        XCTAssertEqual(tracks, 2)
    }

    /// A background task that disappears without any callback must not hold a slot.
    func testVanishedTransferIsReleasedByTheForegroundHealthCheckWithoutDuplicates() async throws {
        let h = try harness(limit: 1, systemTransfers: true)
        let system = try XCTUnwrap(h.system)
        let p = try await h.playlist("Vanish", [a, b])
        try await h.until("First transfer") { try h.systemTask(for: a) != nil }
        let lost = try XCTUnwrap(try h.systemTask(for: a))
        system.vanish(lost.number)
        // No callback, no lifecycle event: the health check detects the non-progressing
        // reservation, refreshes the inventory and restarts a at its position.
        try await h.until("Lost transfer restarted") { (try h.systemTask(for: a))?.number != nil && system.created == 2 }
        if case .waitingForSlot(limited: false)? = h.coordinator.displayStates[p.entries[1].id] {} else {
            XCTFail("b explains it is waiting for a slot, got \(String(describing: h.coordinator.displayStates[p.entries[1].id]))")
        }
        // Repeated recovery with a healthy (merely slow) task creates nothing new.
        try await Task.sleep(for: .milliseconds(500))
        XCTAssertEqual(system.created, 2, "No duplicate downloads")
        try h.finishSystemTransfer(a)
        try await h.until("Final song starts automatically") { try h.systemTask(for: b) != nil }
        try h.finishSystemTransfer(b)
        try await h.until("Playlist offline") { try await h.allReady(p.session) }
        XCTAssertEqual(try h.jobs().count, 2)
        let tracks = try await h.trackCount()
        XCTAssertEqual(tracks, 2)
    }

    /// The final remaining job after earlier ones complete starts on its own.
    func testFinalRemainingJobStartsAfterEarlierRecordingsComplete() async throws {
        let h = try harness(limit: 2, systemTransfers: true)
        let system = try XCTUnwrap(h.system)
        let p = try await h.playlist("Final", [a, b, c])
        try await h.until("Two transfers") { system.tasks.count == 2 }
        try h.finishSystemTransfer(a)
        try h.finishSystemTransfer(b)
        try await h.until("Final job started without interaction") { try h.systemTask(for: c) != nil }
        try h.finishSystemTransfer(c)
        try await h.until("Playlist offline") { try await h.allReady(p.session) }
        XCTAssertEqual(system.created, 3)
    }

    func testPendingWorkStartsWhenTheAppReturnsToTheForeground() async throws {
        let h = try harness(limit: 2, systemTransfers: true)
        let system = try XCTUnwrap(h.system)
        h.downloads.setForeground(false)
        let p = try await h.playlist("Foreground", [a])
        try await h.until("Waiting for iOS") { h.coordinator.displayStates[p.entries[0].id] == .waitingForExecution }
        XCTAssertEqual(system.created, 0, "No transfer is created while iOS gives no execution window")
        h.downloads.setForeground(true)
        try await h.until("Started on return") { try h.systemTask(for: a) != nil }
    }

    func testNetworkLossAndRestorationRestartTheQueueAutomatically() async throws {
        let h = try harness(limit: 2, systemTransfers: true)
        let system = try XCTUnwrap(h.system)
        h.downloads.setPath(connected: false, wifi: false)
        let p = try await h.playlist("Network", [a])
        try await h.until("Waiting for a connection") { h.coordinator.displayStates[p.entries[0].id] == .waitingForConnection }
        XCTAssertEqual(system.created, 0)
        h.downloads.setPath(connected: true, wifi: true)
        try await h.until("Started on reconnect") { try h.systemTask(for: a) != nil }
    }

    func testLiftingResourceRestrictionsRestartsTheQueue() async throws {
        let h = try harness(limit: 2, systemTransfers: true)
        let system = try XCTUnwrap(h.system)
        h.downloads.setResourcePolicy(ResourcePolicy(thermal: .serious))
        let p = try await h.playlist("Thermal", [a, b])
        try await h.until("Deferred by temperature") { h.coordinator.displayStates[p.entries[0].id] == .waitingForDevice }
        XCTAssertEqual(system.created, 0)
        h.downloads.setResourcePolicy(ResourcePolicy(lowPower: true))
        try await h.until("One transfer under Low Power Mode") { system.created == 1 }
        try await h.until("Second song explains the limit") {
            h.coordinator.displayStates[p.entries[1].id] == .waitingForSlot(limited: true)
        }
        h.downloads.setResourcePolicy(ResourcePolicy())
        try await h.until("Full concurrency restored") { system.created == 2 }
    }

    func testUnsupportedRecordingNeverBlocksTheNextEligibleRecording() async throws {
        let h = try harness(limit: 1, systemTransfers: true)
        h.preparer.fail(a, with: .noCompatibleAudio)
        let p = try await h.playlist("Unsupported first", [a, b])
        try await h.until("Next recording transfers") { try h.systemTask(for: b) != nil }
        try h.finishSystemTransfer(b)
        try await h.until("Eligible song offline") { try await h.entries(p.session)[1].status == .ready }
        try await h.until("Unsupported shown") {
            if case .unsupported? = h.coordinator.displayStates[p.entries[0].id] { return true }
            return false
        }
    }
}
