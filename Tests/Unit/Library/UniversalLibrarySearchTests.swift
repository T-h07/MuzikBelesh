import XCTest
@testable import OFFLINE

final class UniversalLibrarySearchTests: XCTestCase {
    private func populated() throws -> LibraryFixture {
        let f = try LibraryFixture()
        try f.repository.editMetadata(trackID: f.ids[0], draft: TrackMetadataDraft(title: "Écoute 夜 100%_", artist: "Beyoncé", album: "Café 夜", albumArtist: "Various Café"))
        try f.repository.editMetadata(trackID: f.ids[1], draft: TrackMetadataDraft(title: "Écoute encore", artist: "Beyoncé", album: "Other"))
        _ = try f.repository.createPlaylist(name: "Écoute 夜 100%_", description: "Café compilation")
        try f.repository.setLiked(true, trackID: f.ids[0])
        return f
    }
    private func search(_ query: String, _ f: LibraryFixture) throws -> LibrarySearchResults { LibrarySearchEngine.search(query, in: try f.repository.snapshot()) }

    func testNewRenameAndDeletePlaylistImmediatelyChangeMatches() throws {
        let f = try LibraryFixture(); let p = try f.repository.createPlaylist(name: "Road", description: "Evening drive")
        XCTAssertEqual(try search("road", f).playlists.map(\.id), [p.id])
        XCTAssertEqual(try search("evening", f).playlists.map(\.id), [p.id])
        try f.repository.updatePlaylist(id: p.id, name: "Night", description: "Changed")
        XCTAssertTrue(try search("road", f).playlists.isEmpty)
        XCTAssertEqual(try search("NIGHT", f).playlists.map(\.id), [p.id])
        _ = try f.repository.deletePlaylist(id: p.id, confirmed: true)
        XCTAssertTrue(try search("night", f).playlists.isEmpty)
    }
    func testSongsArtistsAlbumsAndAlbumArtistsUsePersistedMetadata() throws {
        let f = try populated()
        XCTAssertEqual(try search("encore", f).songs.map(\.id), [f.ids[1]])
        XCTAssertEqual(Set(try search("beyonce", f).songs.map(\.id)), Set(f.ids.prefix(2)))
        XCTAssertEqual(try search("beyonce", f).artists.map(\.title), ["Beyoncé"])
        XCTAssertEqual(try search("cafe 夜", f).albums.map(\.title), ["Café 夜"])
        XCTAssertEqual(try search("various cafe", f).albums.map(\.title), ["Café 夜"])
        XCTAssertEqual(try search("various cafe", f).songs.map(\.id), [f.ids[0]])
    }
    func testAllContainsFourCorrectGroupsWithStableIDs() throws {
        let f = try populated()
        let value = try search("", f)
        XCTAssertEqual(value.songs.count, 4); XCTAssertEqual(value.albums.count, 3)
        XCTAssertEqual(value.artists.count, 2); XCTAssertEqual(value.playlists.count, 1)
        XCTAssertFalse(value.isEmpty)
        XCTAssertEqual(value, try search(" \n\t", f))
        XCTAssertEqual(value.albums.map(\.id), try f.repository.snapshot().albumGroups.map(\.id))
    }
    func testCategoryScopesAndLikedSongsRestrictOnlyTheResults() throws {
        let f = try populated(); let value = try search("", f)
        for scope in LibrarySearchScope.allCases where scope != .all {
            let matches = value.restricted(to: scope)
            if scope != .songs && scope != .likedSongs { XCTAssertTrue(matches.songs.isEmpty) }
            if scope != .albums { XCTAssertTrue(matches.albums.isEmpty) }
            if scope != .artists { XCTAssertTrue(matches.artists.isEmpty) }
            if scope != .playlists { XCTAssertTrue(matches.playlists.isEmpty) }
        }
        XCTAssertEqual(value.restricted(to: .likedSongs).songs.map(\.id), [f.ids[0]])
        XCTAssertTrue(try search("encore", f).restricted(to: .likedSongs).isEmpty)
    }
    func testUnicodeDiacriticsWhitespaceAndCaseUseIdenticalSemantics() throws {
        let f = try populated()
        XCTAssertEqual(try search("  E\u{301}COUTE   夜  ", f), try search("ecoute 夜", f))
        XCTAssertEqual(try search("CAFE", f).playlists.count, 1)
        XCTAssertEqual(try search("夜", f).albums.count, 1)
    }
    func testPercentUnderscoreAndBackslashAreLiteralsAcrossEntities() throws {
        let f = try populated()
        for term in ["%", "_"] {
            XCTAssertEqual(try search(term, f).songs.map(\.id), [f.ids[0]])
            XCTAssertEqual(try search(term, f).playlists.count, 1)
        }
        XCTAssertTrue(try search("\\", f).isEmpty)
        XCTAssertTrue(try search("%' OR 1=1 --", f).isEmpty)
    }
    func testMetadataEditsReplaceArtistAlbumAndSongMatches() throws {
        let f = try populated()
        try f.repository.editMetadata(trackID: f.ids[0], draft: TrackMetadataDraft(title: "Replacement", artist: "New Artist", album: "New Album"))
        XCTAssertEqual(try search("new artist", f).artists.map(\.title), ["New Artist"])
        XCTAssertEqual(try search("new album", f).songs.map(\.id), [f.ids[0]])
        XCTAssertTrue(try search("cafe 夜", f).albums.isEmpty)
    }
    func testSortOrdersSongsAndNeverChangesPersistedPlaylistOrder() throws {
        let f = try populated(); let p = try XCTUnwrap(f.storage.playlists.all().first)
        let order = Array(f.ids.reversed()); try f.repository.addTracks(order, playlistID: p.id)
        for sort in LibrarySort.allCases {
            try f.repository.setSort(sort)
            let snapshot = try f.repository.snapshot()
            XCTAssertEqual(LibrarySearchEngine.search("", in: snapshot).songs.map(\.id), snapshot.tracks.map(\.id))
            XCTAssertEqual(try f.storage.playlists.tracks(playlistID: p.id).map(\.id), order)
        }
    }
    func testAllEntityMatchesSurviveDatabaseReopen() throws {
        let f = try populated(); let before = try search("夜", f)
        let reopened = try StorageCoordinator(paths: f.paths)
        let snapshot = try LibraryRepository(db: reopened.database.dbQueue).snapshot()
        XCTAssertEqual(LibrarySearchEngine.search("夜", in: snapshot), before)
    }
    @MainActor func testObservedPlaylistChangesRefreshSearchWithoutRelaunch() async throws {
        let f = try LibraryFixture(); let (_, _, library) = f.services(); let session = LibrarySearchSession()
        let p = try f.repository.createPlaylist(name: "Reactive Road")
        await libraryEventually { library.snapshot.playlists.contains { $0.id == p.id } }
        await session.update(query: "Reactive", snapshot: library.snapshot, debounce: false)
        XCTAssertEqual(session.results?.playlists.map(\.id), [p.id])
        try f.repository.updatePlaylist(id: p.id, name: "Renamed", description: "")
        await libraryEventually { library.snapshot.playlists.first?.name == "Renamed" }
        await session.update(query: "Reactive", snapshot: library.snapshot, debounce: false)
        XCTAssertTrue(session.results?.isEmpty == true)
    }
    @MainActor func testOutOfOrderResponsesCannotReplaceNewerQuery() async throws {
        let f = try populated(); let snapshot = try f.repository.snapshot(); let gate = SearchResponseGate()
        let session = LibrarySearchSession(operation: { query, snapshot in
            if query == "old" { await gate.wait() }
            return LibrarySearchEngine.search(query, in: snapshot)
        })
        let old = Task { await session.update(query: "old", snapshot: snapshot, debounce: false) }
        await gate.started()
        await session.update(query: "夜", snapshot: snapshot, debounce: false)
        await gate.release(); await old.value
        XCTAssertEqual(session.results?.query, "夜"); XCTAssertEqual(session.results?.playlists.count, 1)
    }
    @MainActor func testCancelledResponseCannotPublishResults() async throws {
        let f = try populated(); let snapshot = try f.repository.snapshot(); let gate = SearchResponseGate()
        let session = LibrarySearchSession(operation: { query, snapshot in await gate.wait(); return LibrarySearchEngine.search(query, in: snapshot) })
        let task = Task { await session.update(query: "夜", snapshot: snapshot, debounce: false) }
        await gate.started(); task.cancel(); await gate.release(); await task.value
        XCTAssertNil(session.results)
    }
}

private actor SearchResponseGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var entered = false
    func wait() async { entered = true; await withCheckedContinuation { continuation = $0 } }
    func started() async { while !entered { await Task.yield() } }
    func release() { continuation?.resume(); continuation = nil }
}
