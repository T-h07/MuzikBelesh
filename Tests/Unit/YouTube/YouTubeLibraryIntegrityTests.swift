import XCTest
import GRDB
@testable import OFFLINE

final class YouTubeLibraryIntegrityTests: XCTestCase {
    func testProvenanceRequiresExactYouTubeIdentityAndAvailableFile() async throws {
        let fixture = try LibraryFixture(count: 2)
        let lookup = YouTubeLibraryLookup(database: fixture.storage.database.dbQueue, paths: fixture.paths)
        var status = try await lookup.status(videoID: YTFixture.id); XCTAssertEqual(status, .notDownloaded)
        try fixture.repository.editMetadata(trackID: fixture.ids[0], draft: TrackMetadataDraft(title: YTFixture.video.title, artist: "", album: ""))
        status = try await lookup.status(videoID: YTFixture.id); XCTAssertEqual(status, .notDownloaded, "Titles never prove provenance")
        try await fixture.storage.database.dbQueue.write { db in
            try LibraryRepository.recordSource(trackID: fixture.ids[0], type: "file", identifier: YTFixture.id, db: db)
            try LibraryRepository.recordSource(trackID: fixture.ids[1], type: "youtube", identifier: YTFixture.id, db: db)
        }
        status = try await lookup.status(videoID: YTFixture.id); XCTAssertEqual(status, .downloaded(trackID: fixture.ids[1]))
        let reopened = try DatabaseManager(url: fixture.paths.database)
        let reopenedStatus = try await YouTubeLibraryLookup(database: reopened.dbQueue, paths: fixture.paths).status(videoID: YTFixture.id)
        XCTAssertEqual(reopenedStatus, status)
        try FileManager.default.removeItem(at: fixture.file(1))
        status = try await lookup.status(videoID: YTFixture.id); XCTAssertEqual(status, .fileUnavailable)
        XCTAssertEqual(try fixture.storage.tracks.all().count, 2); XCTAssertEqual(try fixture.foreignKeys(), 0)
    }
    @MainActor func testSearchResolutionAndFailuresPreservePlaybackAndPersistedLibrary() async throws {
        let fixture = try LibraryFixture(count: 3), (player, transport, library) = fixture.services()
        try await player.play(trackID: fixture.ids[0], contextTrackIDs: fixture.ids)
        await player.seek(to: 0.5); player.queue.toggleShuffle(); player.queue.cycleRepeat()
        player.queue.playNext(trackID: fixture.ids[2]); player.sleepTimer.start(minutes: 15)
        let current = player.state.currentTrackID, position = player.state.elapsedTime, deadline = player.sleepTimer.deadline
        let context = player.queue.contextTrackIDs, shuffle = player.queue.shuffleEnabled, repeatMode = player.queue.repeatMode
        let replacements = transport.replacements, generation = player.activeItemGeneration
        let snapshot = try fixture.repository.snapshot()
        let before = try await fixture.storage.database.dbQueue.read { db in
            try ["playback_state", "playback_queue_entries", "playback_history", "download_jobs", "track_sources"].map { try Row.fetchAll(db, sql: "SELECT * FROM \($0) ORDER BY rowid") }
        }
        let hash = try fixture.storage.audio.sha256(url: fixture.file(0))
        let search = YouTubeSearchService(provider: YTSearchStub([.success(YouTubeSearchPage(videos: [YTFixture.video], continuationToken: nil))]))
        _ = try await search.search(query: "song", continuationToken: nil)
        _ = try await YouTubeDownloadPreparer(resolver: YTResolverStub()).prepare(video: YTFixture.video, quality: .high)
        do { _ = try await YTResolverStub(error: .extractionFailed).resolve(video: YTFixture.video, quality: .high); XCTFail() } catch { }
        let after = try await fixture.storage.database.dbQueue.read { db in
            try ["playback_state", "playback_queue_entries", "playback_history", "download_jobs", "track_sources"].map { try Row.fetchAll(db, sql: "SELECT * FROM \($0) ORDER BY rowid") }
        }
        XCTAssertEqual(before, after); XCTAssertEqual(try fixture.repository.snapshot(), snapshot)
        XCTAssertEqual(player.state.currentTrackID, current); XCTAssertEqual(player.state.elapsedTime, position)
        XCTAssertEqual(player.queue.contextTrackIDs, context); XCTAssertEqual(player.queue.shuffleEnabled, shuffle); XCTAssertEqual(player.queue.repeatMode, repeatMode)
        XCTAssertEqual(player.sleepTimer.deadline, deadline); XCTAssertTrue(transport.isPlaying)
        XCTAssertEqual(transport.replacements, replacements); XCTAssertEqual(player.activeItemGeneration, generation)
        XCTAssertEqual(try fixture.storage.audio.sha256(url: fixture.file(0)), hash)
        XCTAssertEqual(library.snapshot.tracks.count, 3)
        player.stop(); player.sleepTimer.cancel()
    }
}
