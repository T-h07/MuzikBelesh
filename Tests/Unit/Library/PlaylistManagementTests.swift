import XCTest
import GRDB
@testable import OFFLINE

final class PlaylistManagementTests: XCTestCase {
    func testCreateTrimsUnicodeNameAndPersistsDescription() throws {
        let f = try LibraryFixture(); let p = try f.repository.createPlaylist(name: "  Écoute  夜  ", description: "Local favourites")
        XCTAssertEqual(p.name, "Écoute 夜"); XCTAssertEqual(p.description, "Local favourites")
        XCTAssertEqual(try StorageCoordinator(paths: f.paths).playlists.all().first?.id, p.id)
    }
    func testRejectsEmptyWhitespaceAndOverlongNames() throws {
        let f = try LibraryFixture()
        for name in ["", " \n\t ", String(repeating: "x", count: 121)] { XCTAssertThrowsError(try f.repository.createPlaylist(name: name)) }
        XCTAssertTrue(try f.storage.playlists.all().isEmpty)
    }
    func testDuplicateNamesHaveIndependentIdentity() throws {
        let f = try LibraryFixture(); let a = try f.repository.createPlaylist(name: "Road"); let b = try f.repository.createPlaylist(name: "Road")
        XCTAssertNotEqual(a.id, b.id); XCTAssertEqual(try f.storage.playlists.all().count, 2)
    }
    func testRenameAndDescriptionPreserveMembershipIdentityAndDateCreated() throws {
        let f = try LibraryFixture(); let p = try f.repository.createPlaylist(name: "Before")
        try f.repository.addTracks(f.ids, playlistID: p.id)
        try f.repository.updatePlaylist(id: p.id, name: "After", description: "New description")
        let saved = try XCTUnwrap(f.storage.playlists.all().first)
        XCTAssertEqual(saved.id, p.id); XCTAssertEqual(saved.dateAdded.timeIntervalSince1970, p.dateAdded.timeIntervalSince1970, accuracy: 0.001); XCTAssertGreaterThanOrEqual(saved.dateModified.timeIntervalSince(p.dateModified), -0.001)
        XCTAssertEqual(saved.name, "After"); XCTAssertEqual(saved.description, "New description")
        XCTAssertEqual(try f.storage.playlists.tracks(playlistID: p.id).map(\.id), f.ids)
    }
    func testInvalidRenameRollsBackAllFields() throws {
        let f = try LibraryFixture(); let p = try f.repository.createPlaylist(name: "Before", description: "Keep")
        let before = try f.storage.playlists.all().first
        XCTAssertThrowsError(try f.repository.updatePlaylist(id: p.id, name: " ", description: "Discard"))
        XCTAssertEqual(try f.storage.playlists.all().first, before)
    }
    func testAddOneAndMultipleTracksWithoutDuplicateMembership() throws {
        let f = try LibraryFixture(); let p = try f.repository.createPlaylist(name: "Road")
        try f.repository.addTracks([f.ids[0]], playlistID: p.id)
        try f.repository.addTracks([f.ids[1], f.ids[1], f.ids[0], f.ids[2]], playlistID: p.id)
        XCTAssertEqual(try f.storage.playlists.tracks(playlistID: p.id).map(\.id), Array(f.ids.prefix(3)))
    }
    func testSameTrackMayBelongToDifferentPlaylists() throws {
        let f = try LibraryFixture(); let a = try f.repository.createPlaylist(name: "A"); let b = try f.repository.createPlaylist(name: "B")
        try f.repository.addTracks([f.ids[0]], playlistID: a.id); try f.repository.addTracks([f.ids[0]], playlistID: b.id)
        XCTAssertEqual(try f.storage.playlists.tracks(playlistID: a.id).map(\.id), [f.ids[0]])
        XCTAssertEqual(try f.storage.playlists.tracks(playlistID: b.id).map(\.id), [f.ids[0]])
    }
    func testFailedMultiAddIsAtomic() throws {
        let f = try LibraryFixture(); let p = try f.repository.createPlaylist(name: "A")
        try f.repository.addTracks([f.ids[0]], playlistID: p.id)
        XCTAssertThrowsError(try f.repository.addTracks([f.ids[1], "missing"], playlistID: p.id))
        XCTAssertEqual(try f.storage.playlists.tracks(playlistID: p.id).map(\.id), [f.ids[0]])
    }
    func testRemoveMembershipPreservesOtherPlaylistLikesAndBytes() throws {
        let f = try LibraryFixture(); let a = try f.repository.createPlaylist(name: "A"); let b = try f.repository.createPlaylist(name: "B")
        let bytes = try Data(contentsOf: f.file(0)); try f.repository.setLiked(true, trackID: f.ids[0])
        try f.repository.addTracks(f.ids, playlistID: a.id); try f.repository.addTracks(f.ids, playlistID: b.id)
        try f.repository.removeTrack(f.ids[0], playlistID: a.id)
        XCTAssertEqual(try f.storage.playlists.tracks(playlistID: a.id).map(\.id), Array(f.ids.dropFirst()))
        XCTAssertEqual(try f.storage.playlists.tracks(playlistID: b.id).map(\.id), f.ids)
        XCTAssertTrue(try f.repository.snapshot().likedIDs.contains(f.ids[0])); XCTAssertEqual(try Data(contentsOf: f.file(0)), bytes)
    }
    func testReorderSurvivesRestartWithContiguousPositions() throws {
        let f = try LibraryFixture(); let p = try f.repository.createPlaylist(name: "A"); try f.repository.addTracks(f.ids, playlistID: p.id)
        let order = [f.ids[0], f.ids[3], f.ids[1], f.ids[2]]; try f.repository.reorder(order, playlistID: p.id)
        let reopened = try StorageCoordinator(paths: f.paths)
        XCTAssertEqual(try reopened.playlists.tracks(playlistID: p.id).map(\.id), order)
        XCTAssertEqual(try f.repository.snapshot().memberships.map(\.position), [0, 1, 2, 3])
    }
    func testFailedReorderPreservesCanonicalOrder() throws {
        let f = try LibraryFixture(); let p = try f.repository.createPlaylist(name: "A"); try f.repository.addTracks(f.ids, playlistID: p.id)
        for invalid in [[f.ids[0]], [f.ids[0], f.ids[0], f.ids[2], f.ids[3]], [f.ids[0], f.ids[1], f.ids[2], "absent"]] {
            XCTAssertThrowsError(try f.repository.reorder(invalid, playlistID: p.id))
            XCTAssertEqual(try f.storage.playlists.tracks(playlistID: p.id).map(\.id), f.ids)
        }
    }
    func testDatabaseFailureDuringReorderRollsBackDeletionAndPositions() throws {
        let f = try LibraryFixture(); let p = try f.repository.createPlaylist(name: "A"); try f.repository.addTracks(f.ids, playlistID: p.id)
        try f.storage.database.dbQueue.write { try $0.execute(sql: "CREATE TRIGGER reject_membership BEFORE INSERT ON playlist_tracks BEGIN SELECT RAISE(ABORT, 'injected'); END") }
        XCTAssertThrowsError(try f.repository.reorder(Array(f.ids.reversed()), playlistID: p.id))
        XCTAssertEqual(try f.storage.playlists.tracks(playlistID: p.id).map(\.id), f.ids)
    }
    func testDeletePlaylistRequiresConfirmationAndPreservesSongsLikesOtherPlaylist() throws {
        let f = try LibraryFixture(); let a = try f.repository.createPlaylist(name: "A"); let b = try f.repository.createPlaylist(name: "B")
        try f.repository.addTracks(f.ids, playlistID: a.id); try f.repository.addTracks(f.ids, playlistID: b.id); try f.repository.setLiked(true, trackID: f.ids[0])
        XCTAssertThrowsError(try f.repository.deletePlaylist(id: a.id, confirmed: false))
        _ = try f.repository.deletePlaylist(id: a.id, confirmed: true)
        XCTAssertEqual(try f.storage.tracks.all().count, 4); XCTAssertEqual(try f.storage.playlists.all().map(\.id), [b.id])
        XCTAssertEqual(try f.storage.playlists.tracks(playlistID: b.id).map(\.id), f.ids)
        XCTAssertTrue(try f.repository.snapshot().likedIDs.contains(f.ids[0])); XCTAssertEqual(try f.foreignKeys(), 0)
        for index in f.ids.indices { XCTAssertTrue(FileManager.default.fileExists(atPath: try f.file(index).path)) }
    }
    func testLongPlaylistReordersBothDirectionsWithoutChangingLibrarySort() throws {
        let f = try LibraryFixture(count: 150); let p = try f.repository.createPlaylist(name: "Long")
        try f.repository.addTracks(f.ids, playlistID: p.id); try f.repository.setSort(.nameDescending)
        let order = [f.ids.last!] + Array(f.ids.dropLast()); try f.repository.reorder(order, playlistID: p.id)
        XCTAssertEqual(try f.storage.playlists.tracks(playlistID: p.id).map(\.id), order)
        try f.repository.reorder(f.ids, playlistID: p.id)
        XCTAssertEqual(try f.repository.snapshot().sort, .nameDescending)
    }
}
