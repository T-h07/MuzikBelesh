import XCTest
@testable import OFFLINE

final class PlaybackPreviousPolicyTests: XCTestCase {
    private func restored(shuffle: Bool, current: String = "future", history: [String] = ["peso", "future"], position: Int = 1) -> PlaybackNavigationEngine {
        let engine = PlaybackNavigationEngine(makeShuffle: { $0 })
        engine.restore(context: ["future", "peso", "c", "d"], currentID: current, shuffleEnabled: shuffle, repeatMode: .off, shuffleOrder: ["peso", "c", "d"], shufflePosition: 0, history: history, historyPosition: position, explicitQueue: [])
        return engine
    }

    func testSequentialFirstIndexedSongIgnoresHistoryFromSecondSong() {
        let engine = restored(shuffle: false)
        XCTAssertNil(engine.previous(), "The first indexed song has no predecessor with Repeat Off")
        XCTAssertFalse(engine.hasPrevious())
        XCTAssertEqual(engine.history, ["peso", "future"], "Keep history for Shuffle and restoration")
    }

    func testSequentialSecondIndexedSongUsesLibraryPredecessor() {
        let engine = restored(shuffle: false, current: "peso", history: ["d", "peso"])
        XCTAssertEqual(engine.previous(), "future", "History cannot override sequential order")
    }

    func testShuffleFirstIndexedSongUsesActualHistory() {
        let engine = restored(shuffle: true)
        XCTAssertEqual(engine.previous(), "peso")
        XCTAssertTrue(engine.hasPrevious())
    }

    func testShuffleWithoutHistoryDoesNotInventAnIndexedPredecessor() {
        let engine = restored(shuffle: true, current: "peso", history: [], position: -1)
        XCTAssertNil(engine.previous())
        XCTAssertFalse(engine.hasPrevious())
    }

    func testSwitchingShuffleOffIgnoresBothHistoryDirectionsWithoutErasingThem() {
        let engine = restored(shuffle: true, history: ["peso", "future", "c"])
        engine.setShuffleEnabled(false)
        engine.setContext(["future", "peso", "c", "d"], currentID: "future")
        XCTAssertNil(engine.previous())
        XCTAssertFalse(engine.hasPrevious())
        XCTAssertEqual(engine.next(), "peso", "Sequential Next also ignores a shuffled forward branch")
        XCTAssertEqual(engine.history, ["peso", "future", "c"])
        XCTAssertEqual(engine.historyPosition, 1)
        engine.setShuffleEnabled(true)
        XCTAssertEqual(engine.previous(), "peso")
        XCTAssertEqual(engine.next(), "c", "Enabling Shuffle restores its valid history branch")
    }

    func testSequentialPreviousCommitsActualSongBeforeEnablingShuffle() {
        let engine = restored(shuffle: false, current: "peso", history: ["d", "peso"])
        XCTAssertEqual(engine.previous(), "future")
        engine.didStart("future", direction: .previous)
        XCTAssertEqual(engine.history, ["d", "peso", "future"])
        XCTAssertEqual(engine.history[engine.historyPosition], engine.currentID)
        engine.setShuffleEnabled(true)
        XCTAssertEqual(engine.previous(), "peso", "Must not decrement the cursor to a different song")
        engine.didStart("peso", direction: .previous)
        XCTAssertEqual(engine.previous(), "d")
    }

    func testRestorationRepairsMismatchedHistoryCursorWithoutDeletingHistory() {
        let engine = restored(shuffle: true, history: ["peso", "future", "c"], position: 2)
        XCTAssertEqual(engine.historyPosition, 1)
        XCTAssertEqual(engine.previous(), "peso")
        XCTAssertEqual(engine.history, ["peso", "future", "c"])
        let absent = restored(shuffle: true, current: "d", history: ["peso", "future"], position: 1)
        XCTAssertNil(absent.previous())
        XCTAssertEqual(absent.history, ["peso", "future"])
    }

    func testContextFilteringKeepsTheCurrentHistoryEntryAndLinearBoundary() {
        let engine = restored(shuffle: true, current: "c", history: ["peso", "future", "c"], position: 2)
        engine.setContext(["future", "c", "d"], currentID: "c")
        XCTAssertEqual(engine.history, ["future", "c"])
        XCTAssertEqual(engine.historyPosition, 1)
        XCTAssertEqual(engine.previous(), "future")
        engine.setShuffleEnabled(false)
        engine.didStart("future", direction: .previous)
        engine.setContext(["future", "c", "d"], currentID: "future")
        XCTAssertNil(engine.previous())
        XCTAssertFalse(engine.hasPrevious())
    }

    func testRepeatOffNeverWrapsButRepeatAllWrapsInLibraryOrder() {
        let engine = restored(shuffle: false)
        XCTAssertNil(engine.previous())
        engine.cycleRepeat() // Off -> All
        XCTAssertEqual(engine.previous(), "d")
        engine.didStart("d", direction: .previous)
        XCTAssertEqual(engine.previous(), "c")
        XCTAssertEqual(engine.next(), "future")
        engine.didStart("future", direction: .forward)
        XCTAssertEqual(engine.next(), "peso")
        engine.cycleRepeat(); engine.cycleRepeat() // All -> One -> Off
        XCTAssertNil(engine.previous())
        XCTAssertFalse(engine.hasPrevious())
    }

    func testRepeatAllShuffleStillTraversesHistoryBothWays() {
        let engine = restored(shuffle: true, current: "c", history: ["peso", "future", "c"], position: 2)
        engine.cycleRepeat()
        XCTAssertEqual(engine.previous(), "future")
        engine.didStart("future", direction: .previous)
        XCTAssertEqual(engine.previous(), "peso")
        XCTAssertEqual(engine.next(), "c")
        engine.didStart("c", direction: .forward)
        XCTAssertTrue(engine.hasNext())
        XCTAssertNotNil(engine.next())
    }
}
