import XCTest
@testable import OFFLINE

final class SearchSortingAndLikesTests: XCTestCase {
    private func searchable() throws -> LibraryFixture {
        let f = try LibraryFixture()
        try f.repository.editMetadata(trackID: f.ids[0], draft: TrackMetadataDraft(title: "Étoile Night", artist: "Beyoncé", album: "Lune"))
        try f.repository.editMetadata(trackID: f.ids[1], draft: TrackMetadataDraft(title: "100%_literal", artist: "日本語", album: "夜空"))
        return f
    }
    func testExactAndPartialTitleSearch() throws { let f = try searchable(); for term in ["Étoile Night", "Night", "etoile"] { XCTAssertEqual(try f.repository.search(term, sort: .newest).map(\.id), [f.ids[0]]) } }
    func testArtistAndAlbumSearch() throws { let f = try searchable(); for term in ["Beyoncé", "Lune"] { XCTAssertEqual(try f.repository.search(term, sort: .newest).map(\.id), [f.ids[0]]) } }
    func testMixedCaseAndUnicodeSearch() throws { let f = try searchable(); XCTAssertEqual(try f.repository.search("bEyOnCe", sort: .newest).map(\.id), [f.ids[0]]); for term in ["日本", "夜空"] { XCTAssertEqual(try f.repository.search(term, sort: .newest).map(\.id), [f.ids[1]]) } }
    func testEmptyWhitespaceAndNoResultQueries() throws { let f = try searchable(); for term in ["", " \n "] { XCTAssertEqual(try f.repository.search(term, sort: .newest).count, 4) }; XCTAssertTrue(try f.repository.search("unmatched", sort: .newest).isEmpty) }
    func testSQLWildcardAndInjectionCharactersAreLiteralBoundValues() throws { let f = try searchable(); for term in ["%", "_", "%_literal"] { XCTAssertEqual(try f.repository.search(term, sort: .newest).map(\.id), [f.ids[1]]) }; XCTAssertTrue(try f.repository.search("' OR 1=1; --", sort: .newest).isEmpty); XCTAssertEqual(try f.storage.tracks.all().count, 4) }
    func testLongQueryIsBoundedAndDeterministic() throws { let f = try searchable(); XCTAssertTrue(try f.repository.search(String(repeating: "x", count: 100_000), sort: .newest).isEmpty); XCTAssertEqual(try f.repository.search("Song", sort: .nameAscending).map(\.id), [f.ids[2], f.ids[3]]) }
    func testNameSortBothDirectionsAndStableIDTieBreak() throws {
        let f = try LibraryFixture()
        for id in f.ids.prefix(2) { try f.repository.editMetadata(trackID: id, draft: TrackMetadataDraft(title: "Same", artist: "", album: "")) }
        XCTAssertEqual(try f.repository.search("", sort: .nameAscending).map(\.id), f.ids)
        XCTAssertEqual(try f.repository.search("", sort: .nameDescending).map(\.id), [f.ids[3], f.ids[2], f.ids[0], f.ids[1]])
    }
    func testArtistSortUsesDisplayIdentityNotUUID() throws {
        let f = try LibraryFixture()
        try f.repository.editMetadata(trackID: f.ids[0], draft: TrackMetadataDraft(title: "Song 0", artist: "Zulu", album: ""))
        try f.repository.editMetadata(trackID: f.ids[1], draft: TrackMetadataDraft(title: "Song 1", artist: "Alpha", album: ""))
        XCTAssertEqual(Array(try f.repository.search("", sort: .artist).map(\.id).suffix(2)), [f.ids[1], f.ids[0]])
    }
    func testDateSortBothDirections() throws { let f = try LibraryFixture(); XCTAssertEqual(try f.repository.search("", sort: .oldest).map(\.id), f.ids); XCTAssertEqual(try f.repository.search("", sort: .newest).map(\.id), Array(f.ids.reversed())) }
    func testNumericDurationSortBothDirectionsWithUnknownLast() throws {
        let f = try LibraryFixture()
        for (index, duration) in [Int64?(570_000), 720_000, 10_000, nil].enumerated() { var t = try XCTUnwrap(f.storage.tracks.find(id: f.ids[index])); t.durationMs = duration; try f.storage.tracks.save(t) }
        XCTAssertEqual(try f.repository.search("", sort: .shortest).map(\.id), [f.ids[2], f.ids[0], f.ids[1], f.ids[3]])
        XCTAssertEqual(try f.repository.search("", sort: .longest).map(\.id), [f.ids[1], f.ids[0], f.ids[2], f.ids[3]])
    }
    func testSortPreferenceRestoresWithoutChangingPlaylistCustomOrder() throws {
        let f = try LibraryFixture(); let p = try f.repository.createPlaylist(name: "A"); let order = [f.ids[2], f.ids[0], f.ids[3], f.ids[1]]
        try f.repository.addTracks(order, playlistID: p.id); try f.repository.setSort(.nameDescending)
        let reopened = try StorageCoordinator(paths: f.paths)
        XCTAssertEqual(try LibraryRepository(db: reopened.database.dbQueue).snapshot().sort, .nameDescending)
        XCTAssertEqual(try reopened.playlists.tracks(playlistID: p.id).map(\.id), order)
    }
    func testLikeUnlikeAreIdempotentAndPersistAcrossRepositories() throws {
        let f = try LibraryFixture()
        try f.repository.setLiked(true, trackID: f.ids[0]); try f.repository.setLiked(true, trackID: f.ids[0])
        let reopened = try StorageCoordinator(paths: f.paths); let r = LibraryRepository(db: reopened.database.dbQueue)
        XCTAssertEqual(try r.snapshot().likedIDs, [f.ids[0]])
        try r.setLiked(false, trackID: f.ids[0]); try r.setLiked(false, trackID: f.ids[0]); try r.setLiked(false, trackID: "absent")
        XCTAssertTrue(try f.repository.snapshot().likedIDs.isEmpty)
    }
    func testLikingMissingRowFailsWithoutCreatingBrokenReference() throws { let f = try LibraryFixture(); XCTAssertThrowsError(try f.repository.setLiked(true, trackID: "absent")); XCTAssertEqual(try f.foreignKeys(), 0) }
}
