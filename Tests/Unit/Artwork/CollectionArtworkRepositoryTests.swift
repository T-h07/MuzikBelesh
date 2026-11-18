import Foundation
import GRDB
import XCTest
@testable import OFFLINE

/// Phase 11.5 candidate index: each collection's covers come only from its own songs.
final class CollectionArtworkRepositoryTests: XCTestCase {
    private func fixture(_ count: Int = 6) throws -> LibraryFixture {
        let fixture = try LibraryFixture(count: count)
        retainUntilTeardown(fixture)
        for index in 0..<count { try fixture.setTrackArtwork("cover-\(index).jpg", index) }
        return fixture
    }

    func testOrdinaryPlaylistsUseOnlyTheirOwnSongs() throws {
        let f = try fixture()
        let first = try f.repository.createPlaylist(name: "First")
        let second = try f.repository.createPlaylist(name: "Second")
        try f.repository.addTracks([f.ids[0], f.ids[1]], playlistID: first.id)
        try f.repository.addTracks([f.ids[4], f.ids[5]], playlistID: second.id)
        let index = try f.artworkIndex()
        XCTAssertEqual(index[.playlist(first.id)]?.candidates, ["cover-0.jpg", "cover-1.jpg"])
        XCTAssertEqual(index[.playlist(second.id)]?.candidates, ["cover-4.jpg", "cover-5.jpg"])
        XCTAssertEqual(index[.playlist(first.id)]?.firstPath, "cover-0.jpg")
        XCTAssertNil(index[.playlist(first.id)]?.customPath)
    }

    func testSharedArtworkPathsCountOnceAndSongsWithoutArtworkAreSkipped() throws {
        let f = try fixture()
        try f.setTrackArtwork("cover-0.jpg", 1)
        try f.setTrackArtwork(nil, 2)
        try f.setTrackArtwork("../outside.jpg", 3)
        let playlist = try f.repository.createPlaylist(name: "Shared")
        try f.repository.addTracks(Array(f.ids.prefix(5)), playlistID: playlist.id)
        XCTAssertEqual(try f.artworkIndex()[.playlist(playlist.id)]?.candidates, ["cover-0.jpg", "cover-4.jpg"])
    }

    func testEmptyPlaylistHasNoCandidatesButKeepsItsCustomCover() throws {
        let f = try fixture(1)
        let playlist = try f.repository.createPlaylist(name: "Empty")
        try f.storage.database.dbQueue.write { db in
            try db.execute(sql: "UPDATE playlists SET artworkRelativePath = 'custom.jpg' WHERE id = ?", arguments: [playlist.id])
        }
        let entry = try XCTUnwrap(try f.artworkIndex()[.playlist(playlist.id)])
        XCTAssertEqual(entry.candidates, [])
        XCTAssertEqual(entry.customPath, "custom.jpg")
    }

    func testAlbumsFollowPersistentIdentityNotSimilarNames() throws {
        let f = try fixture()
        let first = try f.repository.saveAlbum(draft: AlbumDraft(title: "Same Name", artist: "Same Artist"), trackIDs: [f.ids[0], f.ids[1]])
        let second = try f.repository.saveAlbum(draft: AlbumDraft(title: "Same Name", artist: "Same Artist"), trackIDs: [f.ids[2]])
        XCTAssertNotEqual(first.id, second.id)
        let index = try f.artworkIndex()
        XCTAssertEqual(index[.album(first.id)]?.candidates, ["cover-0.jpg", "cover-1.jpg"])
        XCTAssertEqual(index[.album(second.id)]?.candidates, ["cover-2.jpg"])
        let unassigned = try XCTUnwrap(index[.album(LibrarySnapshot.unassignedAlbumID)])
        XCTAssertEqual(unassigned.candidates, ["cover-3.jpg", "cover-4.jpg", "cover-5.jpg"])
        XCTAssertNil(unassigned.customPath)
    }

    func testAlbumTracksSharingOneEmbeddedCoverAreDeduplicated() throws {
        let f = try fixture(4)
        for index in 0..<4 { try f.setTrackArtwork("embedded.jpg", index) }
        let album = try f.repository.saveAlbum(draft: AlbumDraft(title: "One Cover"), trackIDs: f.ids)
        let entry = try XCTUnwrap(try f.artworkIndex()[.album(album.id)])
        XCTAssertEqual(entry.candidates, ["embedded.jpg"])
        XCTAssertEqual(CollectionArtworkSelector.select(entry.candidates, identity: .album(album.id), epoch: 3)?.tiles, ["embedded.jpg", nil, nil, nil],
                       "One cover never fills all four quadrants")
    }

    func testAlbumCustomCoverIsTheRecordCoverNotTheFirstSongCover() throws {
        let f = try fixture()
        let album = try f.repository.saveAlbum(draft: AlbumDraft(title: "Covered"), trackIDs: [f.ids[0]])
        XCTAssertNil(try f.artworkIndex()[.album(album.id)]?.customPath, "A derived group cover is not a custom cover")
        try f.storage.database.dbQueue.write { db in
            try db.execute(sql: "UPDATE albums SET artworkRelativePath = 'album-cover.jpg' WHERE id = ?", arguments: [album.id])
        }
        XCTAssertEqual(try f.artworkIndex()[.album(album.id)]?.customPath, "album-cover.jpg")
    }

    func testArtistsUsePerformerAndAlbumArtistSongsWithoutDerivedOverride() throws {
        let f = try fixture()
        try f.repository.editMetadata(trackID: f.ids[0], draft: TrackMetadataDraft(title: "A", artist: "Performer", album: ""))
        try f.repository.editMetadata(trackID: f.ids[1], draft: TrackMetadataDraft(title: "B", artist: "Guest", album: "Compilation", albumArtist: "Performer"))
        try f.repository.editMetadata(trackID: f.ids[2], draft: TrackMetadataDraft(title: "C", artist: "Somebody Else", album: ""))
        let snapshot = try f.repository.snapshot()
        let performer = try XCTUnwrap(snapshot.artists.first { $0.name == "Performer" })
        let group = try XCTUnwrap(snapshot.artistGroups.first { $0.id == performer.id })
        XCTAssertNotNil(group.artworkRelativePath, "The group shows a song cover as its legacy fallback")
        let entry = try XCTUnwrap(try f.artworkIndex()[.artist(performer.id)])
        XCTAssertEqual(entry.candidates, ["cover-0.jpg", "cover-1.jpg"])
        XCTAssertNil(entry.customPath, "Only a stored artist cover is an explicit choice")
    }

    func testMigratedAndImportedPlaylistsUseVerifiedLocalRecordingsAndManualOccurrences() throws {
        let f = try fixture()
        for source in [PlaylistMigrationSource.exportify, .muzikBelesh] {
            let playlist = PlaylistMigrationSourcePlaylist(source: source, name: "Imported \(source.rawValue)", entries: (0..<5).map {
                PlaylistMigrationSourceTrack(position: $0, title: "Original \($0)", primaryArtist: "Artist", durationMs: 1000,
                                             artworkURL: URL(string: "https://i.scdn.co/image/remote-\($0)"))
            })
            let session = try f.storage.playlistMigrations.createCommittedPlaylist(from: playlist, operationID: "artwork-\(source.rawValue)")
            let playlistID = try XCTUnwrap(session.destinationPlaylistID)
            try f.storage.database.dbQueue.write { db in
                // Two verified recordings (one repeated); the others stay unresolved placeholders.
                try db.execute(sql: "UPDATE migration_entries SET localTrackID = ?, status = 'ready' WHERE migrationID = ? AND sourcePosition IN (0, 3)", arguments: [f.ids[0], session.id.uuidString])
                try db.execute(sql: "UPDATE migration_entries SET localTrackID = ?, status = 'ready' WHERE migrationID = ? AND sourcePosition = 1", arguments: [f.ids[1], session.id.uuidString])
                // A candidate that is not verified yet contributes nothing.
                try db.execute(sql: "UPDATE migration_entries SET localTrackID = ? WHERE migrationID = ? AND sourcePosition = 2", arguments: [f.ids[5], session.id.uuidString])
            }
            try f.repository.addTracks([f.ids[2]], playlistID: playlistID) // A manual occurrence.
            let entry = try XCTUnwrap(try f.artworkIndex()[.playlist(playlistID)])
            XCTAssertEqual(entry.candidates, ["cover-0.jpg", "cover-1.jpg", "cover-2.jpg"], "\(source): remote artwork URLs are never used")
            XCTAssertEqual(entry.firstPath, "cover-0.jpg")
        }
    }

    func testIndexIsPureAndDoesNotChangeTheLibrary() throws {
        let f = try fixture()
        let playlist = try f.repository.createPlaylist(name: "Pure")
        try f.repository.addTracks(f.ids, playlistID: playlist.id)
        let before = try ReleaseIntegritySnapshot.capture(f.storage.database.dbQueue, paths: f.paths)
        for _ in 0..<3 { _ = try f.artworkIndex() }
        XCTAssertEqual(try ReleaseIntegritySnapshot.capture(f.storage.database.dbQueue, paths: f.paths), before)
    }

    func testIndexOfALargeLibraryIsBuiltOnce() throws {
        // 10,000 songs in 1,000 playlists: one O(n) pass, then O(1) lookups per row.
        var snapshot = LibrarySnapshot()
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        snapshot.tracks = (0..<10_000).map {
            StoredTrack(id: "t\($0)", title: "T", artistID: nil, albumID: nil, durationMs: 1, fileRelativePath: "t\($0).wav", fileExtension: "wav", fileSizeBytes: 1,
                        contentSHA256: "h\($0)", artworkRelativePath: "art-\($0).jpg", availability: .available, dateAdded: now, dateModified: now,
                        originalFilename: nil, metadataSource: "test")
        }
        snapshot.playlists = (0..<1_000).map { StoredPlaylist(id: "p\($0)", name: "P", description: nil, artworkRelativePath: nil, dateAdded: now, dateModified: now) }
        snapshot.memberships = (0..<10_000).map { PlaylistMembership(playlistID: "p\($0 % 1_000)", trackID: "t\($0)", position: $0 / 1_000, dateAdded: now) }
        let start = Date()
        let index = CollectionArtworkIndexBuilder.build(snapshot: snapshot, artistGroups: [], albumGroups: [])
        XCTAssertLessThan(Date().timeIntervalSince(start), 10)
        XCTAssertEqual(index.count, 1_000)
        XCTAssertEqual(index[.playlist("p7")]?.candidates.count, 10)
    }
}
