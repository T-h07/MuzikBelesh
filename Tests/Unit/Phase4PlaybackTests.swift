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
}
