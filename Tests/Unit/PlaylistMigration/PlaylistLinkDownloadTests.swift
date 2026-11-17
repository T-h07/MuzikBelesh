import Foundation
import GRDB
import XCTest
@testable import OFFLINE

/// "Add Songs → From YouTube Links": many links in one submission become ordered
/// playlist entries, are queued in the shared DownloadManager queue and turn into
/// ordinary playlist occurrences once their audio is verified.
@MainActor final class PlaylistLinkDownloadTests: XCTestCase {
    private func id(_ n: Int) -> String { AcquisitionHarness.video(n) }

    private func added(_ h: AcquisitionHarness, _ playlistID: String) async throws -> [PlaylistLinkDownloadRecord] {
        try await h.storage.database.dbQueue.read { db in
            try PlaylistLinkDownloadRecord.fetchAll(db, sql: "SELECT * FROM playlist_link_downloads WHERE playlistID = ? ORDER BY sequence", arguments: [playlistID])
        }
    }
    private func order(_ h: AcquisitionHarness, _ playlistID: String) async throws -> [String] {
        try await h.storage.database.dbQueue.read { db in
            try String.fetchAll(db, sql: "SELECT trackID FROM playlist_tracks WHERE playlistID = ? ORDER BY position", arguments: [playlistID])
        }
    }

    func testParserAcceptsSupportedFormatsRejectsMalformedAndFlagsDuplicates() {
        let lines = ParsedYouTubeLink.split("""
            https://www.youtube.com/watch?v=aaaaaaaaaa1&si=tracking&feature=share
            https://youtu.be/aaaaaaaaaa2?si=abc, https://music.youtube.com/watch?v=aaaaaaaaaa3
            https://www.youtube.com/shorts/aaaaaaaaaa4
            http://www.youtube.com/watch?v=aaaaaaaaaa5
            https://example.com/watch?v=aaaaaaaaaa6
            not-a-link
            https://youtu.be/aaaaaaaaaa1
            https://www.youtube.com/watch?v=aaaaaaaaaa7
            """)
        let parsed = ParsedYouTubeLink.parse(lines, existing: ["aaaaaaaaaa7"])
        XCTAssertEqual(parsed.count, 9, "Every pasted link is listed, in order")
        XCTAssertEqual(parsed.prefix(4).map(\.status), [.valid("aaaaaaaaaa1"), .valid("aaaaaaaaaa2"), .valid("aaaaaaaaaa3"), .valid("aaaaaaaaaa4")])
        XCTAssertEqual(parsed[4].status, .invalid("Use a secure https:// YouTube link."))
        XCTAssertEqual(parsed[5].status, .invalid("This isn't a YouTube link."))
        if case .invalid = parsed[6].status {} else { XCTFail("Malformed text is rejected") }
        XCTAssertEqual(parsed[7].status, .duplicate("aaaaaaaaaa1", inPlaylist: false), "A duplicate is flagged, never silently dropped")
        XCTAssertEqual(parsed[8].status, .duplicate("aaaaaaaaaa7", inPlaylist: true))
        XCTAssertEqual(ParsedYouTubeLink.parse(Array(repeating: "https://youtu.be/aaaaaaaaaa9", count: 1), existing: []).first?.videoID, "aaaaaaaaaa9")
    }

    func testManyLinksQueueTogetherKeepSubmittedOrderAndOneFailureDoesNotStopTheRest() async throws {
        let h = try harness(limit: 3, holding: true)
        let playlist = try h.fixture.repository.createPlaylist(name: "Links")
        h.preparer.fail(id(4), with: .noCompatibleAudio) // Permanently unsupported.
        let videos = (1...6).map(id)
        let result = try await h.coordinator.submitLinks(videos, playlistID: playlist.id)
        XCTAssertEqual(result.accepted.map(\.videoID), videos, "All links are accepted at once, in submitted order")
        let pending = try await h.storage.database.dbQueue.read { try LibraryRepository.pendingLinks($0, playlistID: playlist.id) }
        XCTAssertEqual(pending.map(\.videoID), videos)
        try await h.until("Downloads started under the global limit") { await h.transfer.waiting == 3 }
        // Finish out of order: the playlist still follows the submitted order.
        for video in [id(3), id(1), id(2)] { await h.transfer.release(video) }
        await h.transfer.releaseAll()
        try await h.until("Healthy links added") { try await self.added(h, playlist.id).filter { $0.state == .added }.count == 5 }
        try await h.until("Unsupported link failed") { try await self.added(h, playlist.id).first { $0.videoID == self.id(4) }?.state == .failed }
        let rows = try await added(h, playlist.id)
        let expected = rows.filter { $0.state == .added }.sorted { $0.sequence < $1.sequence }.compactMap(\.trackID)
        let actual = try await order(h, playlist.id)
        XCTAssertEqual(actual, expected, "Playlist order matches the submitted order")
        XCTAssertEqual(actual.count, 5)
        let failed = try XCTUnwrap(rows.first { $0.videoID == id(4) })
        XCTAssertNotNil(failed.failure, "The failed entry stays with its reason")
        XCTAssertEqual(try h.jobs().count, 6, "Every link was queued exactly once")
        let maxActive = await h.transfer.maxActive
        XCTAssertLessThanOrEqual(maxActive, 3, "Existing concurrency limits apply")
    }

    func testImportedPlaylistAcceptsRepeatsAsSeparateOccurrencesAtReservedPositions() async throws {
        let h = try harness(limit: 1, holding: true)
        let p = try await h.playlist("Hybrid", [nil])
        let playlistID = try XCTUnwrap(p.session.destinationPlaylistID)
        let result = try await h.coordinator.submitLinks([id(7), id(7), id(8)], playlistID: playlistID)
        XCTAssertEqual(result.accepted.count, 3, "Imported playlists keep repeated occurrences")
        XCTAssertEqual(result.accepted.map(\.slot), [0, 1, 2], "Positions are reserved in submitted order")
        let next = try await h.storage.database.dbQueue.read { try LibraryRepository.nextManualPosition($0, playlistID: playlistID) }
        XCTAssertEqual(next, 3, "A song added from the library meanwhile never takes a reserved position")
        await h.transfer.releaseAll()
        try await h.until("All link entries added") { try await self.added(h, playlistID).allSatisfy { $0.state == .added } }
        let occurrences = try await h.storage.database.dbQueue.read { db in
            try LocalPlaylistOccurrence.filter(Column("playlistID") == playlistID).order(Column("position")).fetchAll(db)
        }
        XCTAssertEqual(occurrences.count, 3)
        XCTAssertEqual(occurrences[0].trackID, occurrences[1].trackID, "The repeated video is two occurrences of one recording")
        XCTAssertNotEqual(occurrences[1].trackID, occurrences[2].trackID)
        XCTAssertEqual(try h.jobs().filter { $0.sourceIdentifier == id(7) }.count, 1, "A repeated video is downloaded once")
        let entries = try await h.entries(p.session)
        XCTAssertEqual(entries.count, 1, "Spotify source entries are not inflated by user additions")
        let paths = h.fixture.paths
        let snapshot = try await h.storage.database.dbQueue.read { try LibraryRepository.observedSnapshot($0, paths: paths) }
        XCTAssertEqual(snapshot.localPlaylistRows[playlistID]?.count, 3)
        XCTAssertEqual(snapshot.migrationPresentations[playlistID]?.rows.count, 1)
    }

    func testFailedLinkCanBeRetriedOrRemovedWithoutAffectingOthers() async throws {
        let h = try harness(limit: 1)
        let playlist = try h.fixture.repository.createPlaylist(name: "Retry")
        await h.transfer.corrupt(id(11)); await h.transfer.corrupt(id(12))
        try await h.coordinator.submitLinks([id(10), id(11), id(12)], playlistID: playlist.id)
        try await h.until("Two links failed after their bounded retry") {
            try await self.added(h, playlist.id).filter { $0.state == .failed }.count == 2
        }
        let rows = try await added(h, playlist.id)
        XCTAssertEqual(rows.first { $0.videoID == id(10) }?.state, .added)
        await h.transfer.heal(id(11)); await h.transfer.seed(id(11), 5)
        let retried = try XCTUnwrap(rows.first { $0.videoID == id(11) })
        await h.coordinator.retryLink(id: retried.id)
        try await h.until("Retried link added") { try await self.added(h, playlist.id).first { $0.id == retried.id }?.state == .added }
        let removed = try XCTUnwrap(rows.first { $0.videoID == id(12) })
        await h.coordinator.removeLink(id: removed.id)
        let after = try await added(h, playlist.id)
        XCTAssertNil(after.first { $0.id == removed.id }, "Removed from the playlist")
        let songs = try await order(h, playlist.id)
        XCTAssertEqual(songs.count, 2, "Successfully downloaded songs are kept")
    }

    func testPendingLinksSurviveRestartWithoutDuplicateDownloads() async throws {
        let h = try harness(limit: 1, holding: true)
        let playlist = try h.fixture.repository.createPlaylist(name: "Restart")
        try await h.coordinator.submitLinks([id(20), id(21)], playlistID: playlist.id)
        try await h.until("First transfer in flight") { await h.transfer.waiting == 1 }
        let fresh = GatedAcquisitionTransfer()
        await h.relaunch(transfer: fresh)
        try await h.until("Both links added after the restart") { try await self.added(h, playlist.id).allSatisfy { $0.state == .added } }
        for _ in 0..<2 { await h.relaunch(transfer: fresh); await h.settle() }
        XCTAssertEqual(try h.jobs().count, 2, "Recovery never duplicates jobs")
        let started = await fresh.started
        XCTAssertEqual(started.sorted(), [id(20), id(21)], "Each recording is downloaded once after the restart")
        let songs = try await order(h, playlist.id)
        XCTAssertEqual(songs.count, 2)
    }

    func testRemovedPendingLinkPausesItsOwnDownloadAndALateCompletionIsIgnored() async throws {
        let h = try harness(limit: 1, holding: true)
        let playlist = try h.fixture.repository.createPlaylist(name: "Remove")
        let result = try await h.coordinator.submitLinks([id(30)], playlistID: playlist.id)
        let link = try XCTUnwrap(result.accepted.first)
        try await h.until("Transfer in flight") { await h.transfer.waiting == 1 }
        await h.coordinator.removeLink(id: link.id)
        await h.settle()
        let job = try XCTUnwrap(try h.jobs().first { $0.sourceIdentifier == id(30) })
        XCTAssertEqual(job.state, .paused, "A download only this entry needed is paused, not deleted")
        // A stale completion for the removed entry changes nothing.
        let library = LibraryRepository(db: h.storage.database.dbQueue)
        let outcome = try library.completeLink(id: link.id, trackID: "missing-track", paths: h.fixture.paths)
        XCTAssertEqual(outcome, .gone)
        let songs = try await order(h, playlist.id)
        XCTAssertTrue(songs.isEmpty)
    }

    func testOrdinaryPlaylistReportsVideosItAlreadyContains() async throws {
        let h = try harness(limit: 1)
        let playlist = try h.fixture.repository.createPlaylist(name: "Set")
        try await h.coordinator.submitLinks([id(40)], playlistID: playlist.id)
        try await h.until("Added") { try await self.order(h, playlist.id).count == 1 }
        let again = try await h.coordinator.submitLinks([id(40), id(41), id(41)], playlistID: playlist.id)
        XCTAssertEqual(again.accepted.map(\.videoID), [id(41)])
        XCTAssertEqual(again.alreadyInPlaylist, [id(40), id(41)], "Duplicates are reported, not silently dropped")
        let known = try LibraryRepository(db: h.storage.database.dbQueue).youtubeVideoIDs(inPlaylist: playlist.id)
        XCTAssertTrue(known.contains(id(40)))
    }
}
