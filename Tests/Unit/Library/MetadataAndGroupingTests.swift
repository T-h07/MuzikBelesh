import XCTest
import GRDB
@testable import OFFLINE

final class MetadataAndGroupingTests: XCTestCase {
    func testTitleEditPreservesIdentityHashPathAndAudioBytes() throws {
        let f = try LibraryFixture(); let before = try XCTUnwrap(f.storage.tracks.find(id: f.ids[0])); let bytes = try Data(contentsOf: f.file(0))
        try f.repository.editMetadata(trackID: before.id, draft: TrackMetadataDraft(title: "  Étoile — 夜  ", artist: "Artist", album: "Album"))
        let after = try XCTUnwrap(f.storage.tracks.find(id: before.id))
        XCTAssertEqual(after.title, "Étoile — 夜"); XCTAssertEqual(after.id, before.id); XCTAssertEqual(after.contentSHA256, before.contentSHA256)
        XCTAssertEqual(after.fileRelativePath, before.fileRelativePath); XCTAssertEqual(after.originalFilename, before.originalFilename)
        XCTAssertEqual(try Data(contentsOf: f.file(0)), bytes); XCTAssertEqual(try f.foreignKeys(), 0)
    }
    func testArtistAndAlbumParentsExistBeforeTrackUpdate() throws {
        let f = try LibraryFixture()
        try f.repository.editMetadata(trackID: f.ids[0], draft: TrackMetadataDraft(title: "Title", artist: " New Artist ", album: " New Album "))
        let snapshot = try f.repository.snapshot(); let track = try XCTUnwrap(snapshot.trackByID[f.ids[0]])
        XCTAssertEqual(snapshot.artistName(track.artistID), "New Artist"); XCTAssertEqual(snapshot.albumTitle(track.albumID), "New Album")
        XCTAssertEqual(try f.foreignKeys(), 0)
    }
    func testCanonicalArtistIdentityReusesCaseWhitespaceAndUnicodeNormalization() throws {
        let f = try LibraryFixture()
        for (index, name) in ["  Beyoncé ", "BEYONCE\u{301}"].enumerated() {
            try f.repository.editMetadata(trackID: f.ids[index], draft: TrackMetadataDraft(title: "Song", artist: name, album: "Record"))
        }
        let a = try XCTUnwrap(f.storage.tracks.find(id: f.ids[0])); let b = try XCTUnwrap(f.storage.tracks.find(id: f.ids[1]))
        XCTAssertEqual(a.artistID, b.artistID); XCTAssertEqual(a.albumID, b.albumID)
    }
    func testDistinctAccentedArtistNamesAreNotBlindlyMerged() throws {
        let f = try LibraryFixture()
        for (index, name) in ["Jose", "José"].enumerated() { try f.repository.editMetadata(trackID: f.ids[index], draft: TrackMetadataDraft(title: "Song", artist: name, album: "Record")) }
        XCTAssertNotEqual(try f.storage.tracks.find(id: f.ids[0])?.artistID, try f.storage.tracks.find(id: f.ids[1])?.artistID)
    }
    func testSameAlbumTitleByDifferentArtistsHasDifferentIdentity() throws {
        let f = try LibraryFixture()
        for index in 0..<2 { try f.repository.editMetadata(trackID: f.ids[index], draft: TrackMetadataDraft(title: "Song", artist: "Artist \(index)", album: "Greatest Hits")) }
        let snapshot = try f.repository.snapshot()
        XCTAssertEqual(snapshot.albumGroups.filter { $0.title == "Greatest Hits" }.count, 2)
        XCTAssertNotEqual(snapshot.trackByID[f.ids[0]]?.albumID, snapshot.trackByID[f.ids[1]]?.albumID)
    }
    func testCompilationAlbumArtistGroupsDifferentTrackArtists() throws {
        let f = try LibraryFixture()
        for index in 0..<2 { try f.repository.editMetadata(trackID: f.ids[index], draft: TrackMetadataDraft(title: "Song", artist: "Guest \(index)", album: "Compilation", albumArtist: "Various Artists")) }
        let snapshot = try f.repository.snapshot()
        XCTAssertEqual(snapshot.trackByID[f.ids[0]]?.albumID, snapshot.trackByID[f.ids[1]]?.albumID)
        XCTAssertNotEqual(snapshot.trackByID[f.ids[0]]?.artistID, snapshot.trackByID[f.ids[1]]?.artistID)
        XCTAssertEqual(snapshot.albumGroups.first { $0.title == "Compilation" }?.count, 2)
    }
    func testUnknownMetadataUsesVirtualGroupsWithoutUnknownParentRows() throws {
        let f = try LibraryFixture(); let snapshot = try f.repository.snapshot()
        XCTAssertTrue(snapshot.artists.isEmpty); XCTAssertTrue(snapshot.albums.isEmpty)
        XCTAssertEqual(snapshot.artistGroups.count, 1); XCTAssertEqual(snapshot.artistGroups.first?.title, "Unknown Artist")
        XCTAssertEqual(snapshot.albumGroups.count, 1); XCTAssertEqual(snapshot.albumGroups.first?.title, "Unassigned Songs")
        XCTAssertEqual(snapshot.albumGroups.first?.id, LibrarySnapshot.unassignedAlbumID)
    }
    func testEditingRelationshipsRefreshesGroupsWithoutDeletingReferencedOldParents() throws {
        let f = try LibraryFixture()
        for id in f.ids.prefix(2) { try f.repository.editMetadata(trackID: id, draft: TrackMetadataDraft(title: "Song", artist: "Old", album: "Old Album")) }
        let before = try f.repository.snapshot()
        try f.repository.editMetadata(trackID: f.ids[0], draft: TrackMetadataDraft(title: "Moved", artist: "New", album: "New Album"))
        let after = try f.repository.snapshot()
        XCTAssertEqual(after.artistGroups.first { $0.title == "Old" }?.trackIDs, [f.ids[1]])
        XCTAssertEqual(after.artistGroups.first { $0.title == "New" }?.trackIDs, [f.ids[0]])
        XCTAssertTrue(after.artists.contains { $0.id == before.trackByID[f.ids[1]]?.artistID }); XCTAssertEqual(try f.foreignKeys(), 0)
    }
    func testInvalidTitleOrArtistDoesNotPartiallyChangeRelationships() throws {
        let f = try LibraryFixture(); let before = try f.repository.snapshot()
        for title in ["", " \n ", String(repeating: "a", count: 301)] {
            XCTAssertThrowsError(try f.repository.editMetadata(trackID: f.ids[0], draft: TrackMetadataDraft(title: title, artist: "Never Created", album: "Never Created")))
        }
        XCTAssertThrowsError(try f.repository.editMetadata(trackID: f.ids[0], draft: TrackMetadataDraft(title: "Valid", artist: String(repeating: "x", count: 301), album: "Invalid Parent")))
        XCTAssertEqual(try f.repository.snapshot(), before)
    }
    func testMetadataDatabaseFailureRollsBackNewParents() throws {
        let f = try LibraryFixture(); let before = try f.repository.snapshot()
        try f.storage.database.dbQueue.write { try $0.execute(sql: "CREATE TRIGGER reject_metadata BEFORE UPDATE ON tracks BEGIN SELECT RAISE(ABORT, 'injected'); END") }
        XCTAssertThrowsError(try f.repository.editMetadata(trackID: f.ids[0], draft: TrackMetadataDraft(title: "New", artist: "New", album: "New")))
        XCTAssertEqual(try f.repository.snapshot(), before)
    }
    func testCancelledDraftDoesNotWriteAnything() throws {
        let f = try LibraryFixture(); let before = try f.repository.snapshot()
        var draft = TrackMetadataDraft(title: "Song", artist: "", album: ""); draft.title = "Unsaved"
        XCTAssertEqual(try f.repository.snapshot(), before)
        XCTAssertEqual(draft.title, "Unsaved")
    }
    func testMetadataPersistsAcrossStorageReopenAndPreservesLikesMembershipAndHistory() throws {
        let f = try LibraryFixture(); let p = try f.repository.createPlaylist(name: "A")
        try f.repository.addTracks(f.ids, playlistID: p.id); try f.repository.setLiked(true, trackID: f.ids[0])
        try f.storage.playback.addHistory(StoredHistoryEntry(id: "history", trackID: f.ids[0], startedAt: Date(), completedAt: nil, durationListenedMs: nil, source: "test"))
        try f.repository.editMetadata(trackID: f.ids[0], draft: TrackMetadataDraft(title: "Saved", artist: "Artist", album: "Album"))
        let reopened = try StorageCoordinator(paths: f.paths); let snapshot = try LibraryRepository(db: reopened.database.dbQueue).snapshot()
        XCTAssertEqual(snapshot.trackByID[f.ids[0]]?.title, "Saved"); XCTAssertTrue(snapshot.likedIDs.contains(f.ids[0]))
        XCTAssertEqual(snapshot.playlistTracks(p.id).map(\.id), f.ids); XCTAssertEqual(try reopened.playback.history(limit: 10).first?.trackID, f.ids[0])
        let exported = f.paths.exports.appendingPathComponent("export.wav")
        try reopened.exportAudio(track: try XCTUnwrap(snapshot.trackByID[f.ids[0]]), to: exported)
        XCTAssertEqual(try Data(contentsOf: exported), try Data(contentsOf: f.file(0)))
    }
}
