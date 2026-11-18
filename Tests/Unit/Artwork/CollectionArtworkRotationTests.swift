import Foundation
import XCTest
@testable import OFFLINE

/// Phase 11.5 rotation: one shared epoch from an injectable clock, one scheduled task for the
/// whole app, foreground only.
@MainActor
final class CollectionArtworkRotationTests: XCTestCase {
    private let interval: TimeInterval = 1800
    private let start = Date(timeIntervalSince1970: 1800 * 944_444 + 600) // 10 minutes into an epoch

    private func service(_ clock: ArtworkTestClock, foreground: Bool = true,
                         sleep: @escaping @Sendable (Duration) async throws -> Void = suspendedArtworkSleeper) -> CollectionArtworkService {
        CollectionArtworkService(library: nil, database: nil, paths: nil, store: MemoryArtworkDefaults(), images: ArtworkImagePipeline(),
                                 interval: interval, clock: { clock.now }, foreground: foreground, sleep: sleep)
    }

    func testNoRotationBeforeTheIntervalElapses() {
        let clock = ArtworkTestClock(start)
        let artwork = service(clock)
        let initial = artwork.epoch
        XCTAssertEqual(initial, 944_444)
        clock.advance(interval - 600 - 1)
        artwork.reconcileEpoch()
        XCTAssertEqual(artwork.epoch, initial, "Stable for the whole interval")
        clock.advance(1)
        artwork.reconcileEpoch()
        XCTAssertEqual(artwork.epoch, initial + 1)
        XCTAssertEqual(artwork.secondsUntilNextEpoch(), interval, accuracy: 0.001)
    }

    func testOneSharedSchedulerSleepsUntilTheNextBoundaryAndAdvances() async {
        let clock = ArtworkTestClock(start)
        let requests = ArtworkSleepRecorder()
        let artwork = service(clock, sleep: { duration in
            let first = await requests.record(duration)
            if first { clock.advance(1200) } // The requested sleep "elapses".
            else { while true { try await Task.sleep(for: .seconds(3600)) } }
        })
        XCTAssertTrue(artwork.isRotationScheduled)
        await libraryEventually { artwork.epoch == 944_445 }
        let recorded = await requests.durations
        XCTAssertEqual(recorded.first, .seconds(1200), "Sleeps exactly until the next epoch, not per row or per second")
        artwork.setForeground(false)
        XCTAssertFalse(artwork.isRotationScheduled)
    }

    func testRotationIsSuspendedInTheBackgroundAndReconciledOnReturn() {
        let clock = ArtworkTestClock(start)
        let artwork = service(clock)
        artwork.setForeground(false)
        XCTAssertFalse(artwork.isForeground)
        XCTAssertFalse(artwork.isRotationScheduled, "Nothing is scheduled to wake the app")
        let before = artwork.epoch
        clock.advance(interval * 5)
        artwork.reconcileEpoch()
        XCTAssertEqual(artwork.epoch, before, "No artwork work while in the background")
        artwork.setForeground(true)
        XCTAssertEqual(artwork.epoch, before + 5, "The current epoch is applied on return")
        XCTAssertTrue(artwork.isRotationScheduled)
        artwork.setForeground(true)
        XCTAssertTrue(artwork.isRotationScheduled, "Repeated activation keeps one scheduler")
        artwork.setForeground(false)
    }

    func testReturningWithinTheSameIntervalKeepsTheSelection() {
        let clock = ArtworkTestClock(start)
        let artwork = service(clock)
        let epoch = artwork.epoch
        artwork.setForeground(false)
        clock.advance(300)
        artwork.setForeground(true)
        XCTAssertEqual(artwork.epoch, epoch)
        artwork.setForeground(false)
    }

    func testAColdLaunchRecomputesTheEpochWithoutRestoredState() {
        let clock = ArtworkTestClock(start)
        let first = service(clock, foreground: false)
        let relaunched = service(clock, foreground: false)
        XCTAssertEqual(first.epoch, relaunched.epoch, "Force-quit and relaunch: same epoch from the clock alone")
        XCTAssertFalse(relaunched.isRotationScheduled, "A launch in the background schedules nothing")
    }

    func testAnEpochChangeChangesTheMosaicOfLargeCollectionsOnly() async throws {
        let fixture = try LibraryFixture(count: 6); retainUntilTeardown(fixture)
        for index in 0..<6 { try fixture.setTrackArtwork("cover-\(index).jpg", index) }
        let (_, _, library) = fixture.services()
        let large = try fixture.repository.createPlaylist(name: "Large")
        let four = try fixture.repository.createPlaylist(name: "Four")
        try fixture.repository.addTracks(fixture.ids, playlistID: large.id)
        try fixture.repository.addTracks(Array(fixture.ids.prefix(4)), playlistID: four.id)
        let clock = ArtworkTestClock(start)
        let artwork = fixture.artworkService(library: library, clock: clock)
        await libraryEventually { artwork.entry(for: .playlist(four.id)).candidates.count == 4 && artwork.entry(for: .playlist(large.id)).candidates.count == 6 }
        let largeBefore = artwork.presentation(for: .playlist(large.id))
        let fourBefore = artwork.presentation(for: .playlist(four.id))
        XCTAssertEqual(artwork.presentation(for: .playlist(large.id)), largeBefore, "Re-resolving (a recreated row, a scroll) never reshuffles")
        clock.advance(interval)
        artwork.reconcileEpoch()
        XCTAssertNotEqual(artwork.presentation(for: .playlist(large.id)), largeBefore)
        XCTAssertEqual(artwork.presentation(for: .playlist(four.id)), fourBefore, "Exactly four covers are not reshuffled for motion")
        artwork.setForeground(false)
    }

    func testRefreshMosaicSelectsADifferentSetOnlyWhenAlternativesExist() async throws {
        let fixture = try LibraryFixture(count: 5); retainUntilTeardown(fixture)
        for index in 0..<5 { try fixture.setTrackArtwork("cover-\(index).jpg", index) }
        let (_, _, library) = fixture.services()
        let five = try fixture.repository.createPlaylist(name: "Five")
        let three = try fixture.repository.createPlaylist(name: "Three")
        try fixture.repository.addTracks(fixture.ids, playlistID: five.id)
        try fixture.repository.addTracks(Array(fixture.ids.prefix(3)), playlistID: three.id)
        let artwork = fixture.artworkService(library: library)
        await libraryEventually { artwork.entry(for: .playlist(five.id)).candidates.count == 5 && artwork.entry(for: .playlist(three.id)).candidates.count == 3 }
        guard case .mosaic(let before) = artwork.presentation(for: .playlist(five.id)) else { return XCTFail("Mosaic expected") }
        XCTAssertTrue(artwork.canRefresh(.playlist(five.id)))
        artwork.refresh(.playlist(five.id))
        guard case .mosaic(let after) = artwork.presentation(for: .playlist(five.id)) else { return XCTFail("Mosaic expected") }
        XCTAssertNotEqual(Set(before.tiles), Set(after.tiles))
        let threeBefore = artwork.presentation(for: .playlist(three.id))
        XCTAssertFalse(artwork.canRefresh(.playlist(three.id)))
        artwork.refresh(.playlist(three.id))
        XCTAssertEqual(artwork.presentation(for: .playlist(three.id)), threeBefore)
        XCTAssertEqual(try fixture.repository.snapshot().memberships.filter { $0.playlistID == five.id }.map(\.trackID), fixture.ids, "Refreshing never changes membership or order")
        artwork.setForeground(false)
    }
}

/// Records requested sleep durations across the sleeper's concurrency domain.
actor ArtworkSleepRecorder {
    private(set) var durations: [Duration] = []
    /// Returns true for the first request.
    func record(_ duration: Duration) -> Bool {
        durations.append(duration)
        return durations.count == 1
    }
}
