import GRDB
import XCTest
@testable import OFFLINE

/// Phase 12 release gate (G06/G15): a database left by every shipped or distributed build
/// upgrades in place to v1.2.0 without losing or rewriting a single pre-existing row, with
/// SQLite integrity and foreign keys intact.
///
/// Each case builds a populated installation, rewinds it to the schema of one historical
/// build by removing only the tables and migration records that build did not have (the
/// same technique as `LocalProfileUpgradeTests`), then reopens it with the current
/// `StorageCoordinator`, exactly as the next launch of the upgraded app does.
final class Phase12UpgradeMatrixTests: XCTestCase {
    /// Historical cut points, oldest first. Phase 11.3 (themes) changed no schema: its
    /// preferences live in UserDefaults, so it shares the 11.2 cut.
    private enum Cut: String, CaseIterable {
        case v110 = "v1.1.0 (v022)"
        case phase111 = "Phase 11.1 (v024)"
        case phase112and113 = "Phase 11.2/11.3 (v025)"
        case phase114 = "Phase 11.4 (v026)"
        case phase115 = "Phase 11.5 (v027)"
    }

    private func installation(at cut: Cut) throws -> LibraryFixture {
        let fixture = try LibraryFixture(count: 4)
        retainUntilTeardown(fixture)
        let repository = fixture.repository
        let mix = try repository.createPlaylist(name: "Upgrade Mix", description: "Order matters")
        try repository.addTracks([fixture.ids[2], fixture.ids[0], fixture.ids[3]], playlistID: mix.id)
        try repository.setLiked(true, trackID: fixture.ids[1])
        // A migrated playlist with a repeated source recording, two ready occurrences and
        // unresolved placeholders: order and occurrence identity must survive.
        let source = PlaylistMigrationSourcePlaylist(source: .exportify, name: "Migrated Upgrade", entries: (0..<5).map {
            PlaylistMigrationSourceTrack(position: $0, title: "Source song \($0 % 3)", primaryArtist: "Artist", album: "Album",
                                         durationMs: 180_000, sourceTrackID: "source-\($0 % 3)")
        })
        let session = try fixture.storage.playlistMigrations.createCommittedPlaylist(from: source, operationID: "phase12-upgrade")
        try fixture.storage.database.dbQueue.write { db in
            try db.execute(sql: "UPDATE migration_entries SET localTrackID = ?, status = 'ready' WHERE migrationID = ? AND sourcePosition IN (0, 3)",
                           arguments: [fixture.ids[0], session.id.uuidString])
        }
        if cut != .v110 {
            _ = try LocalProfileRepository(db: fixture.storage.database.dbQueue, paths: fixture.paths).create(username: "Upgrader", avatar: nil)
        }
        if [.phase112and113, .phase114, .phase115].contains(cut) {
            let analytics = ListeningAnalyticsRepository(db: fixture.storage.database.dbQueue)
            let started = Date(timeIntervalSince1970: 1_700_000_000)
            try analytics.begin(ListeningSessionStart(id: "session-1", trackID: fixture.ids[0], startedAt: started, startDay: "2023-11-14",
                                                      durationMs: 2_000, context: ListeningContext(kind: "playlist", sourceID: mix.id)))
            try analytics.write(ListeningSessionUpdate(id: "session-1", listenedMs: 1_900, durationMs: 2_000, qualified: true, completed: true,
                                                       dayDeltas: ["2023-11-14": 1_900], at: started.addingTimeInterval(2), endReason: "ended"))
        }
        try rewind(fixture, to: cut)
        return fixture
    }

    /// Removes exactly what later builds added. Later tables are empty in these fixtures
    /// except where the cut includes them.
    private func rewind(_ fixture: LibraryFixture, to cut: Cut) throws {
        try fixture.storage.database.dbQueue.write { db in
            var removed: [String] = []
            if cut != .phase115 {
                try db.execute(sql: "DROP TRIGGER collection_artwork_preferences_playlist_deleted; DROP TRIGGER collection_artwork_preferences_album_deleted; DROP TRIGGER collection_artwork_preferences_artist_deleted; DROP TABLE collection_artwork_preferences")
                removed.append(CollectionArtworkSchema.version)
            }
            if [.v110, .phase111, .phase112and113].contains(cut) {
                try db.execute(sql: "DROP TABLE portable_library_entries; DROP TABLE portable_library_import_items; DROP TABLE portable_library_imports")
                removed.append(PortableLibrarySchema.version)
            }
            if [.v110, .phase111].contains(cut) {
                try db.execute(sql: "DROP TABLE listening_session_days; DROP TABLE listening_sessions; DROP TABLE listening_analytics_state")
                removed.append(ListeningAnalyticsSchema.version)
            }
            if cut == .v110 {
                try db.execute(sql: "DROP TABLE local_user_profile")
                removed.append(LocalProfileSchema.version)
            }
            for identifier in removed {
                try db.execute(sql: "DELETE FROM grdb_migrations WHERE identifier = ?", arguments: [identifier])
            }
        }
    }

    /// Every row of every table that exists before the upgrade, keyed by table.
    private func everyRow(_ queue: DatabaseQueue) throws -> [String: [String]] {
        try queue.read { db in
            let tables = try String.fetchAll(db, sql: "SELECT name FROM sqlite_master WHERE type = 'table' AND name NOT LIKE 'sqlite_%' AND name != 'grdb_migrations' ORDER BY name")
            var result: [String: [String]] = [:]
            for table in tables { result[table] = try Row.fetchAll(db, sql: "SELECT * FROM \"\(table)\"").map(\.description).sorted() }
            return result
        }
    }

    private func integrity(_ queue: DatabaseQueue) throws -> (integrity: [String], foreignKeys: Int) {
        try queue.read { db in
            (try String.fetchAll(db, sql: "PRAGMA integrity_check"), try Row.fetchAll(db, sql: "PRAGMA foreign_key_check").count)
        }
    }

    func testEveryHistoricalDatabaseUpgradesInPlaceWithoutDataLoss() throws {
        for cut in Cut.allCases {
            let fixture = try installation(at: cut)
            let before = try everyRow(fixture.storage.database.dbQueue)
            let beforeOrder = try fixture.storage.database.dbQueue.read { db in
                try String.fetchAll(db, sql: "SELECT trackID FROM playlist_tracks WHERE playlistID = (SELECT id FROM playlists WHERE name = 'Upgrade Mix') ORDER BY position")
            }

            let upgraded = try StorageCoordinator(paths: fixture.paths) // Next launch of v1.2.0.
            let queue = upgraded.database.dbQueue
            let applied = try appliedMigrations(queue)
            for required in [PlaylistLinkDownloadSchema.version, LocalProfileSchema.version, ListeningAnalyticsSchema.version,
                             PortableLibrarySchema.version, CollectionArtworkSchema.version] {
                XCTAssertTrue(applied.contains(required), "\(cut.rawValue): \(required) not applied")
            }
            XCTAssertFalse(applied.contains(CanceledPhase108UpgradeTests.canceledMigration), cut.rawValue)

            let after = try everyRow(queue)
            for (table, rows) in before {
                XCTAssertEqual(after[table], rows, "\(cut.rawValue): rows of \(table) changed during upgrade")
            }
            let check = try integrity(queue)
            XCTAssertEqual(check.integrity, ["ok"], cut.rawValue)
            XCTAssertEqual(check.foreignKeys, 0, "\(cut.rawValue): foreign key violations")

            let afterOrder = try queue.read { db in
                try String.fetchAll(db, sql: "SELECT trackID FROM playlist_tracks WHERE playlistID = (SELECT id FROM playlists WHERE name = 'Upgrade Mix') ORDER BY position")
            }
            XCTAssertEqual(afterOrder, beforeOrder, cut.rawValue)
            XCTAssertEqual(afterOrder, [fixture.ids[2], fixture.ids[0], fixture.ids[3]], cut.rawValue)
            let profile = try LocalProfileRepository(db: queue, paths: fixture.paths).load()
            XCTAssertEqual(profile?.username, cut == .v110 ? nil : "Upgrader", cut.rawValue)
            for index in fixture.ids.indices {
                XCTAssertTrue(FileManager.default.fileExists(atPath: try fixture.file(index).path), "\(cut.rawValue): audio file \(index) missing")
            }

            // Reopening the upgraded database is a no-op.
            let reopened = try StorageCoordinator(paths: fixture.paths)
            XCTAssertEqual(try everyRow(reopened.database.dbQueue), after, "\(cut.rawValue): second launch changed data")
        }
    }
}
