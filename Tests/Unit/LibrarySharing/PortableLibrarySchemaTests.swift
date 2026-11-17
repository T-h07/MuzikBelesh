import Foundation
import GRDB
import XCTest
@testable import OFFLINE

/// Phase 11.4 `v026_portable_library_sharing`: additive, preserves every existing
/// migration row and relationship, and admits the new native source.
final class PortableLibrarySchemaTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("PortableSchema-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: directory) }

    func testIdentifierIsAppendOnly() {
        XCTAssertEqual(PortableLibrarySchema.version, "v026_portable_library_sharing")
        XCTAssertNotEqual(PortableLibrarySchema.version, CanceledPhase108UpgradeTests.canceledMigration)
        XCTAssertGreaterThan(PortableLibrarySchema.version, ListeningAnalyticsSchema.version)
    }

    func testUpgradeFromV025PreservesMigrationRowsAndRelationships() throws {
        let url = directory.appendingPathComponent("library.sqlite")
        let old = try DatabaseManager(url: url, migrationTarget: ListeningAnalyticsSchema.version)
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let rowid: Int64 = try old.dbQueue.write { db in
            try StoredPlaylist(id: "pl-1", name: "Old Import", description: nil, artworkRelativePath: nil, dateAdded: now, dateModified: now).insert(db)
            try db.execute(sql: """
                INSERT INTO playlist_migrations (id, destinationPlaylistID, operationID, source, sourcePlaylistID, sourceReference, sourcePlaylistName,
                    importFingerprint, expectedEntryCount, status, createdAt, updatedAt, failureInformation)
                VALUES ('mig-1', 'pl-1', 'op-1', 'spotifyAccountExport', 'src', NULL, 'Old Import', 'fp', 1, 'awaitingReview', ?, ?, 'note')
                """, arguments: [now, now])
            try db.execute(sql: """
                INSERT INTO migration_entries (id, migrationID, sourcePosition, title, primaryArtist, additionalArtists, album, durationMs,
                    sourceTrackID, sourceURI, artworkURL, localTrackID, status, createdAt, updatedAt)
                VALUES ('entry-1', 'mig-1', 0, 'Old Song', 'Old Artist', '[]', NULL, 1000, NULL, NULL, NULL, NULL, 'needsReview', ?, ?)
                """, arguments: [now, now])
            return try Int64.fetchOne(db, sql: "SELECT rowid FROM playlist_migrations WHERE id = 'mig-1'") ?? -1
        }
        let before = try old.dbQueue.read { try Row.fetchOne($0, sql: "SELECT * FROM playlist_migrations WHERE id = 'mig-1'") }
        let upgraded = try DatabaseManager(url: url)
        try upgraded.dbQueue.read { db in
            XCTAssertEqual(try String.fetchAll(db, sql: "SELECT identifier FROM grdb_migrations ORDER BY identifier").last, PortableLibrarySchema.version)
            XCTAssertEqual(try Row.fetchOne(db, sql: "SELECT * FROM playlist_migrations WHERE id = 'mig-1'"), before)
            XCTAssertEqual(try Int64.fetchOne(db, sql: "SELECT rowid FROM playlist_migrations WHERE id = 'mig-1'"), rowid)
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM migration_entries WHERE migrationID = 'mig-1'"), 1)
            XCTAssertEqual(try Row.fetchAll(db, sql: "PRAGMA foreign_key_check").count, 0)
            XCTAssertEqual(try String.fetchOne(db, sql: "PRAGMA integrity_check"), "ok")
            let indexes = try String.fetchAll(db, sql: "SELECT name FROM sqlite_master WHERE type = 'index' AND tbl_name = 'playlist_migrations'")
            XCTAssertTrue(indexes.contains("playlist_migrations_status"))
            for table in ["portable_library_imports", "portable_library_import_items", "portable_library_entries"] {
                XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM \(table)"), 0)
            }
        }
        try upgraded.dbQueue.write { db in
            try StoredPlaylist(id: "pl-2", name: "Native", description: nil, artworkRelativePath: nil, dateAdded: now, dateModified: now).insert(db)
            try db.execute(sql: """
                INSERT INTO playlist_migrations (id, destinationPlaylistID, operationID, source, sourcePlaylistName, importFingerprint,
                    expectedEntryCount, status, createdAt, updatedAt) VALUES ('mig-2', 'pl-2', 'op-2', 'muzikBelesh', 'Native', 'fp2', 0, 'metadataReady', ?, ?)
                """, arguments: [now, now])
            XCTAssertThrowsError(try db.execute(sql: """
                INSERT INTO playlist_migrations (id, destinationPlaylistID, operationID, source, sourcePlaylistName, importFingerprint,
                    expectedEntryCount, status, createdAt, updatedAt) VALUES ('mig-3', 'pl-2', 'op-3', 'somethingElse', 'X', 'fp3', 0, 'metadataReady', ?, ?)
                """, arguments: [now, now]))
            // Cascades still resolve to the rebuilt table.
            try db.execute(sql: "DELETE FROM playlists WHERE id = 'pl-1'")
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM playlist_migrations WHERE id = 'mig-1'"), 0)
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM migration_entries WHERE id = 'entry-1'"), 0)
        }
        let session = try upgraded.dbQueue.read { try MigrationSessionRecord.fetchOne($0, key: "mig-2")?.model() }
        XCTAssertEqual(session?.source, .muzikBelesh)
        XCTAssertEqual(PlaylistMigrationSource.muzikBelesh.displayName, "Muzik Belesh library")
    }
}
