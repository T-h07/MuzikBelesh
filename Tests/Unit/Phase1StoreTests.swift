import XCTest
@testable import OFFLINE

final class Phase1StoreTests: XCTestCase {
    func testFixturesHaveStableUniqueIDs() { let ids = MockMusicCatalog.tracks.map(\.id); XCTAssertEqual(ids.count, Set(ids).count); XCTAssertEqual(ids.first, "track-neon") }
    func testLibrarySearchIsCaseInsensitive() { let store = MockMusicStore(); XCTAssertEqual(store.search("LUNA").count, 2); XCTAssertEqual(store.search("").count, MockMusicCatalog.tracks.count) }
    func testLikePlaylistAndMetadataMutations() { let store = MockMusicStore(); store.toggleLiked("track-slow"); XCTAssertTrue(store.likedTrackIDs.contains("track-slow")); store.add("track-slow", to: "playlist-drive"); XCTAssertTrue(store.playlists.first { $0.id == "playlist-drive" }!.trackIDs.contains("track-slow")); store.editTrack("track-slow", title: "Edited", artist: "Artist"); XCTAssertEqual(store.track("track-slow")?.title, "Edited") }
    func testPlaybackQueueAndPositionClamp() { let playback = MockPlaybackStore(); playback.select("track-neon"); playback.seek(999, duration: 214); XCTAssertEqual(playback.position, 214); playback.addToQueue("track-golden"); XCTAssertEqual(playback.queueIDs.last, "track-golden"); playback.next(); XCTAssertTrue(playback.isPlaying) }
    func testRepeatCyclesAndDownloadsTransition() { let playback = MockPlaybackStore(); playback.cycleRepeat(); XCTAssertEqual(playback.repeatMode, .all); let downloads = MockDownloadStore(); downloads.advance("job-0"); XCTAssertEqual(downloads.jobs.first { $0.id == "job-0" }?.progress ?? 0, 0.62, accuracy: 0.001); downloads.cancel("job-0"); XCTAssertEqual(downloads.jobs.first { $0.id == "job-0" }?.state, .cancelled) }
    func testSettingsMutateInMemory() { let settings = MockSettingsStore(); settings.audioQuality = "Standard"; settings.wifiOnly = true; XCTAssertEqual(settings.audioQuality, "Standard"); XCTAssertTrue(settings.wifiOnly) }
}

