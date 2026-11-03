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
}
