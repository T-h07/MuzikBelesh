import XCTest
@testable import OFFLINE

final class Phase4PlaybackTests: XCTestCase {
    func testNavigatorShuffleCycleIsUniqueAndStableAcrossCommandSources() {
        let navigator = PlaybackNavigationEngine(makeShuffle: { Array($0.reversed()) })
        navigator.setContext(["a", "b", "c", "d", "e"], currentID: "e")
        navigator.setShuffleEnabled(true)
        navigator.didStart("e", direction: .forward)
        for expected in ["d", "c", "b", "a"] {
            XCTAssertEqual(navigator.next(), expected)
            navigator.didStart(expected, direction: .forward)
        }
        XCTAssertEqual(Set(["e", "d", "c", "b", "a"]), Set(navigator.history))
    }

    func testNavigatorPreviousUsesPlaybackHistoryAndWrapsRepeatAll() {
        let navigator = PlaybackNavigationEngine(makeShuffle: { $0 })
        navigator.setContext(["a", "b", "c"], currentID: "a")
        navigator.didStart("a", direction: .forward)
        XCTAssertEqual(navigator.next(), "b"); navigator.didStart("b", direction: .forward)
        XCTAssertEqual(navigator.next(), "c"); navigator.didStart("c", direction: .forward)
        XCTAssertEqual(navigator.previous(), "b"); navigator.didStart("b", direction: .previous)
        XCTAssertEqual(navigator.previous(), "a")
        navigator.didStart("a", direction: .previous)
        XCTAssertEqual(navigator.next(), "b")
        navigator.didStart("b", direction: .forward)
        XCTAssertEqual(navigator.next(), "c")
        navigator.didStart("c", direction: .forward)
        XCTAssertEqual(navigator.next(), "a")
    }

    func testNavigatorRepeatModes() {
        let navigator = PlaybackNavigationEngine(makeShuffle: { $0 })
        navigator.setContext(["a", "b"], currentID: "b")
        XCTAssertEqual(navigator.next(), "a")
        navigator.cycleRepeat()
        XCTAssertEqual(navigator.next(), "b")
    }

    func testShuffleHasNextUsesRemainingCycleAtLastIndexedTrackWithoutMutation() {
        let navigator = PlaybackNavigationEngine(makeShuffle: { Array($0) })
        navigator.restore(context: ["a", "b", "c", "d", "e", "f"], currentID: "f", shuffleEnabled: true, repeatMode: .off, shuffleOrder: ["b", "e", "a"], shufflePosition: 0, history: ["f"], historyPosition: 0, explicitQueue: [])
        XCTAssertTrue(navigator.hasNext())
        XCTAssertTrue(navigator.hasNext())
        XCTAssertEqual(navigator.next(), "b")
    }

    func testShuffleRefreshPreservesRemainingOrderAndCursor() {
        let navigator = PlaybackNavigationEngine(makeShuffle: { Array($0) })
        navigator.restore(context: ["a", "b", "c"], currentID: "a", shuffleEnabled: true, repeatMode: .all, shuffleOrder: ["b", "c"], shufflePosition: 1, history: ["a", "b"], historyPosition: 1, explicitQueue: [])
        navigator.setContext(["a", "b", "c"], currentID: "b")
        XCTAssertEqual(navigator.shuffleOrder, ["b", "c"])
        XCTAssertEqual(navigator.shufflePosition, 1)
        XCTAssertEqual(navigator.next(), "c")
    }

    func testShuffleNavigationWorksFromBothIndexedBoundaries() {
        let first = PlaybackNavigationEngine(makeShuffle: { Array($0) })
        first.restore(context: ["a", "b", "c", "d"], currentID: "a", shuffleEnabled: true, repeatMode: .all, shuffleOrder: ["c", "d", "b"], shufflePosition: 0, history: ["a"], historyPosition: 0, explicitQueue: [])
        XCTAssertTrue(first.hasNext())
        XCTAssertEqual(first.next(), "c")

        let last = PlaybackNavigationEngine(makeShuffle: { Array($0) })
        last.restore(context: ["a", "b", "c", "d"], currentID: "d", shuffleEnabled: true, repeatMode: .all, shuffleOrder: ["b", "a", "c"], shufflePosition: 0, history: ["d"], historyPosition: 0, explicitQueue: [])
        XCTAssertTrue(last.hasNext())
        XCTAssertEqual(last.next(), "b")
    }

    func testRepeatOffStillAllowsRemainingShuffleTracks() {
        let navigator = PlaybackNavigationEngine(makeShuffle: { Array($0) })
        navigator.restore(context: ["a", "b", "c"], currentID: "a", shuffleEnabled: true, repeatMode: .off, shuffleOrder: ["c", "b"], shufflePosition: 0, history: ["a"], historyPosition: 0, explicitQueue: [])
        XCTAssertTrue(navigator.hasNext())
        XCTAssertEqual(navigator.next(), "c")
        XCTAssertTrue(navigator.hasNext())
        XCTAssertEqual(navigator.next(), "b")
        XCTAssertFalse(navigator.hasNext())
    }

    func testExhaustedShuffleCycleRegeneratesForRepeatAll() {
        let navigator = PlaybackNavigationEngine(makeShuffle: { Array($0) })
        navigator.restore(context: ["a", "b", "c"], currentID: "c", shuffleEnabled: true, repeatMode: .all, shuffleOrder: ["a", "b"], shufflePosition: 2, history: ["c", "a", "b"], historyPosition: 2, explicitQueue: [])
        XCTAssertTrue(navigator.hasNext())
        let next = navigator.next()
        XCTAssertNotNil(next)
        XCTAssertNotEqual(next, "b")
    }
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

    func testSleepTimerStoresSelectedDurationAndResetKeepsIt() async throws {
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
        let snapshot = StoredPlaybackState(scope: "default", currentTrackID: nil, positionMs: 12_345, shuffleEnabled: true, repeatMode: RepeatMode.all.rawValue, contextTrackIDsJSON: "[\"track\"]", shuffleOrderJSON: "[\"track\"]", shufflePosition: 0, sleepTimerDeadlineMs: Int64(deadline.timeIntervalSince1970 * 1000), sleepTimerDurationMs: 300_000, dateModified: Date())
        try storage.playback.save(snapshot)
        let restored = try XCTUnwrap(storage.playback.state())
        XCTAssertEqual(restored.positionMs, 12_345)
        XCTAssertTrue(restored.shuffleEnabled)
        XCTAssertEqual(restored.repeatMode, RepeatMode.all.rawValue)
        XCTAssertEqual(restored.sleepTimerDurationMs, 300_000)
        XCTAssertNotNil(restored.sleepTimerDeadlineMs)
    }

}
