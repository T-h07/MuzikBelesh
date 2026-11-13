import XCTest
import GRDB
@testable import OFFLINE

final class Phase4LibraryMigrationTests: XCTestCase {
    func testLatestPhase4DatabaseUpgradesWithoutLosingRelationshipsOrPlayback() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Phase4-Upgrade-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = try AppStoragePaths(root: root)
        let old = try DatabaseManager(url: paths.database, migrationTarget: "v008_navigation_history")
        let bytes = LibraryFixture.wav(seed: 1); try bytes.write(to: paths.musicURL(relativePath: "legacy.wav"))
        let hash = try AudioFileService().sha256(url: paths.musicURL(relativePath: "legacy.wav"))
        try old.dbQueue.write { db in
            let date = Date(timeIntervalSince1970: 1_600_000_000)
            try StoredArtist(id: "legacy-artist", name: "Artíste", normalizedName: "artiste", artworkRelativePath: nil, dateAdded: date, dateModified: date).insert(db)
            try db.execute(sql: "INSERT INTO albums (id,title,normalizedTitle,artistID,dateAdded,dateModified) VALUES (?,?,?,?,?,?)", arguments: ["legacy-album", "Record", "record", "legacy-artist", date, date])
            try db.execute(sql: "INSERT INTO tracks (id,title,artistID,albumID,durationMs,fileRelativePath,fileExtension,fileSizeBytes,contentSHA256,availability,dateAdded,dateModified,metadataSource) VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?)", arguments: ["legacy", "Legacy", "legacy-artist", "legacy-album", 2050, "legacy.wav", "wav", bytes.count, hash, "available", date, date, "test"])
            try StoredPlaylist(id: "p", name: "Keep", description: "Keep", artworkRelativePath: nil, dateAdded: date, dateModified: date).insert(db)
            try db.execute(sql: "INSERT INTO playlist_tracks (playlistID,trackID,position,dateAdded) VALUES ('p','legacy',0,?)", arguments: [date])
            try StoredLikedTrack(trackID: "legacy", dateLiked: date).insert(db)
            try db.execute(sql: "INSERT INTO playback_state (scope,currentTrackID,positionMs,shuffleEnabled,repeatMode,contextTrackIDsJSON,shuffleOrderJSON,shufflePosition,navigationHistoryJSON,navigationHistoryPosition,sleepTimerDeadlineMs,sleepTimerDurationMs,dateModified) VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?)", arguments: ["default", "legacy", 500, true, "all", "[\"legacy\"]", "[\"legacy\"]", 1, "[\"legacy\"]", 0, Int64(Date().addingTimeInterval(300).timeIntervalSince1970 * 1000), 300000, date])
            try StoredQueueEntry(id: "q", trackID: "legacy", position: 0, dateAdded: date).insert(db)
            try StoredHistoryEntry(id: "h", trackID: "legacy", startedAt: date, completedAt: nil, durationListenedMs: nil, source: "legacy").insert(db)
            try StoredTrackSource(id: "s", trackID: "legacy", sourceType: "test", sourceIdentifier: "source", canonicalURL: nil, dateRecorded: date).insert(db)
        }
        let reopened = try StorageCoordinator(paths: paths); let repository = LibraryRepository(db: reopened.database.dbQueue)
        XCTAssertEqual(try reopened.tracks.all().map(\.id), ["legacy"])
        XCTAssertEqual(try reopened.tracks.find(id: "legacy")?.artistID, "legacy-artist")
        XCTAssertEqual(try reopened.playlists.tracks(playlistID: "p").map(\.id), ["legacy"])
        XCTAssertTrue(try repository.snapshot().likedIDs.contains("legacy")); XCTAssertEqual(try repository.search("ARTISTE", sort: .newest).map(\.id), ["legacy"])
        XCTAssertEqual(try reopened.playback.queue().map(\.trackID), ["legacy"]); XCTAssertEqual(try reopened.playback.history(limit: 10).first?.trackID, "legacy")
        let state = try XCTUnwrap(reopened.playback.state()); XCTAssertEqual(state.positionMs, 500); XCTAssertEqual(state.shufflePosition, 1); XCTAssertEqual(state.navigationHistoryPosition, 0)
        XCTAssertNotNil(state.sleepTimerDeadlineMs); XCTAssertEqual(state.sleepTimerDurationMs, 300000)
        XCTAssertEqual(try Data(contentsOf: paths.musicURL(relativePath: "legacy.wav")), bytes)
        XCTAssertEqual(try reopened.database.dbQueue.read { try Row.fetchAll($0, sql: "PRAGMA foreign_key_check").count }, 0)
        XCTAssertEqual(try reopened.database.dbQueue.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM grdb_migrations") }, 14)
        _ = try StorageCoordinator(paths: paths)
    }
}
