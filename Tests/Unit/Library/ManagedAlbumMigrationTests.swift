import XCTest
import GRDB
@testable import OFFLINE

final class ManagedAlbumMigrationTests: XCTestCase {
    func testBuild66DatabaseUpgradesAdditivelyPreservingAllIdentitiesFilesAndOrder() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Build66-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = try AppStoragePaths(root: root)
        let old = try DatabaseManager(url: paths.database, migrationTarget: "v009_library_management")
        let date = Date(timeIntervalSince1970: 1_600_000_000)
        let audio = LibraryFixture.wav(seed: 0); try audio.write(to: paths.musicURL(relativePath: "legacy.wav"))
        let art = "artwork-\(UUID().uuidString).jpg"; let cover = try LibraryFixture.image(); try cover.write(to: paths.artworkURL(relativePath: art))
        try old.dbQueue.write { db in
            try StoredArtist(id: "artist", name: "Artist", normalizedName: "artist", artworkRelativePath: nil, dateAdded: date, dateModified: date).insert(db)
            // Raw old-schema inserts are deliberate: current model fields must not
            // leak into the previous physical build's schema fixture.
            try db.execute(sql: "INSERT INTO albums (id,title,normalizedTitle,artistID,artworkRelativePath,dateAdded,dateModified) VALUES (?,?,?,?,?,?,?)", arguments: ["stable-album", "Record", "record", "artist", art, date, date])
            for (id, album, offset) in [("z", "stable-album", 0), ("a", "stable-album", 0), ("unassigned", "", 1)] {
                try db.execute(sql: "INSERT INTO tracks (id,title,artistID,albumID,fileRelativePath,fileExtension,fileSizeBytes,contentSHA256,availability,dateAdded,dateModified,metadataSource) VALUES (?,?,?,?,?,?,?,?,?,?,?,?)", arguments: [id, id, "artist", album.isEmpty ? nil : album, "legacy.wav", "wav", audio.count, id, "available", date.addingTimeInterval(Double(offset)), date, "test"])
            }
            try StoredPlaylist(id: "playlist", name: "Keep", description: "Saved", artworkRelativePath: art, dateAdded: date, dateModified: date).insert(db)
            try db.execute(sql: "INSERT INTO playlist_tracks (playlistID,trackID,position,dateAdded) VALUES ('playlist','z',0,?),('playlist','a',1,?)", arguments: [date, date])
            try StoredLikedTrack(trackID: "z", dateLiked: date).insert(db)
            try StoredQueueEntry(id: "queue", trackID: "z", position: 0, dateAdded: date).insert(db)
            try StoredHistoryEntry(id: "history", trackID: "z", startedAt: date, completedAt: nil, durationListenedMs: nil, source: "album").insert(db)
            try db.execute(sql: "INSERT INTO playback_state (scope,currentTrackID,positionMs,shuffleEnabled,repeatMode,dateModified) VALUES ('default','z',500,0,'off',?)", arguments: [date])
        }
        let upgraded = try StorageCoordinator(paths: paths); let repo = LibraryRepository(db: upgraded.database.dbQueue)
        let value = try repo.snapshot()
        XCTAssertEqual(Set(value.tracks.map(\.id)), Set(["a", "z", "unassigned"]))
        XCTAssertEqual(value.albumGroups.first { $0.id == "stable-album" }?.trackIDs, ["a", "z"])
        XCTAssertEqual(value.albumGroups.first { $0.id == LibrarySnapshot.unassignedAlbumID }?.trackIDs, ["unassigned"])
        XCTAssertEqual(value.albums.map(\.id), ["stable-album"]); XCTAssertEqual(value.albums.first?.artworkRelativePath, art)
        XCTAssertEqual(value.playlistTracks("playlist").map(\.id), ["z", "a"]); XCTAssertEqual(value.likedIDs, ["z"])
        XCTAssertEqual(try upgraded.playback.queue().map(\.id), ["queue"]); XCTAssertEqual(try upgraded.playback.history(limit: 5).map(\.id), ["history"])
        XCTAssertEqual(try upgraded.playback.state()?.positionMs, 500)
        XCTAssertEqual(try Data(contentsOf: paths.musicURL(relativePath: "legacy.wav")), audio)
        XCTAssertEqual(try Data(contentsOf: paths.artworkURL(relativePath: art)), cover)
        let reopened = try StorageCoordinator(paths: paths)
        XCTAssertEqual(try LibraryRepository(db: reopened.database.dbQueue).snapshot(), value)
        XCTAssertEqual(try upgraded.database.dbQueue.read { try Row.fetchAll($0, sql: "PRAGMA foreign_key_check").count }, 0)
    }
}
