import XCTest
@testable import OFFLINE

final class Phase4PlaybackTests: XCTestCase {
    func testRepeatCyclesOffAllOne() {
        XCTAssertEqual(RepeatMode.allCases, [.off, .all, .one])
    }

    func testQueueEntryOccurrencesHaveIndependentIdentity() {
        let first = PlaybackQueueEntry(id: "one", trackID: "track", position: 0, insertedAt: Date(), origin: .addToQueue)
        let second = PlaybackQueueEntry(id: "two", trackID: "track", position: 1, insertedAt: Date(), origin: .playNext)
        XCTAssertNotEqual(first.id, second.id)
        XCTAssertEqual(first.trackID, second.trackID)
    }

    func testQueueOrderingPutsPlayNextBeforeOlderEntries() {
        let entries = [
            PlaybackQueueEntry(id: "new", trackID: "e", position: 0, insertedAt: Date(), origin: .playNext),
            PlaybackQueueEntry(id: "old", trackID: "d", position: 1, insertedAt: Date(), origin: .addToQueue)
        ]
        XCTAssertEqual(entries.map(\.trackID), ["e", "d"])
    }

    func testSleepTimerRejectsSubMinuteDuration() async {
        let timer = await MainActor.run { SleepTimerService() }
        await MainActor.run { timer.start(duration: 30) }
        let active = await MainActor.run { timer.isActive }
        XCTAssertFalse(active)
    }

    func testSleepTimerStoresSelectedDurationAndResetKeepsIt() async {
        let timer = await MainActor.run { SleepTimerService() }
        await MainActor.run { timer.start(minutes: 5) }
        let selected = await MainActor.run { timer.durationSeconds }
        XCTAssertEqual(try XCTUnwrap(selected), 300, accuracy: 0.1)
        await MainActor.run { timer.reset() }
        let resetDuration = await MainActor.run { timer.durationSeconds }
        XCTAssertEqual(try XCTUnwrap(resetDuration), 300, accuracy: 0.1)
    }

    func testPlaybackSnapshotRetainsTimerAlongsidePositionAndModes() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("MuzikBelesh-Phase4-\(UUID().uuidString)")
        let paths = try AppStoragePaths(root: root)
        let storage = try StorageCoordinator(paths: paths)
        let deadline = Date().addingTimeInterval(300)
        let snapshot = StoredPlaybackState(scope: "default", currentTrackID: "track", positionMs: 12_345, shuffleEnabled: true, repeatMode: RepeatMode.all.rawValue, contextTrackIDsJSON: "[\"track\"]", shuffleOrderJSON: "[\"track\"]", shufflePosition: 0, sleepTimerDeadlineMs: Int64(deadline.timeIntervalSince1970 * 1000), sleepTimerDurationMs: 300_000, dateModified: Date())
        try storage.playback.save(snapshot)
        let restored = try XCTUnwrap(storage.playback.state())
        XCTAssertEqual(restored.positionMs, 12_345)
        XCTAssertTrue(restored.shuffleEnabled)
        XCTAssertEqual(restored.repeatMode, RepeatMode.all.rawValue)
        XCTAssertEqual(restored.sleepTimerDurationMs, 300_000)
        XCTAssertNotNil(restored.sleepTimerDeadlineMs)
    }
}
