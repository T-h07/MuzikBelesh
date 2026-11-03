import XCTest
@testable import OFFLINE

final class AuditRegressionTests: XCTestCase {
    func testSingleTrackShuffleCapabilityAgreesWithSelection() {
        let engine = PlaybackNavigationEngine(makeShuffle: { $0 })
        engine.setContext(["a"], currentID: "a")
        engine.setShuffleEnabled(true)
        XCTAssertTrue(engine.hasNext())
        XCTAssertEqual(engine.next(), "a")
    }

    func testRemovingConsumedShuffleEntryPreservesRemainingSuccessor() {
        let engine = PlaybackNavigationEngine(makeShuffle: { $0 })
        engine.restore(context: ["a", "b", "c", "d"], currentID: "c", shuffleEnabled: true, repeatMode: .off, shuffleOrder: ["b", "c", "d"], shufflePosition: 2, history: ["a", "b", "c"], historyPosition: 2, explicitQueue: [])
        engine.setContext(["a", "c", "d"], currentID: "c")
        XCTAssertTrue(engine.hasNext())
        XCTAssertEqual(engine.next(), "d")
    }

    func testPreviousFiltersUnavailableHistory() {
        let engine = PlaybackNavigationEngine(makeShuffle: { $0 })
        engine.restore(context: ["a", "b", "c"], currentID: "c", shuffleEnabled: true, repeatMode: .all, shuffleOrder: ["b", "c"], shufflePosition: 2, history: ["a", "b", "c"], historyPosition: 2, explicitQueue: [])
        engine.setContext(["a", "c"], currentID: "c")
        XCTAssertEqual(engine.previous(), "a")
    }

    func testMalformedRestoredOrderDropsUnknownIDsWithoutResettingCursor() {
        let engine = PlaybackNavigationEngine(makeShuffle: { $0 })
        engine.restore(context: ["a", "b", "c"], currentID: "a", shuffleEnabled: true, repeatMode: .off, shuffleOrder: ["unknown", "b", "c"], shufflePosition: 1, history: ["a"], historyPosition: 0, explicitQueue: [])
        engine.setContext(["a", "b", "c"], currentID: "a")
        XCTAssertTrue(engine.hasNext())
        XCTAssertEqual(engine.next(), "b")
    }
}
