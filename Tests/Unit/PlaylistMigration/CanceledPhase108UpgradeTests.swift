import Foundation
import GRDB
import XCTest
@testable import OFFLINE

/// Phase 10.9 (G07/G08): a phone that ran the canceled Phase 10.8 test IPA has a database
/// with the `v023_spotify_pending_imports` migration recorded and its table present. The
/// release candidate does not know that migration. These tests reproduce that exact state
/// (schema copied verbatim from the retired commit a6cbf36) and prove the candidate opens
/// it, leaves the leftover table and its rows untouched, and changes no user data.
final class CanceledPhase108UpgradeTests: XCTestCase {
    static let canceledMigration = "v023_spotify_pending_imports"
    /// Verbatim `SpotifyPendingImportSchema` from a6cbf36 (never merged).
    static let canceledSchema = """
        CREATE TABLE spotify_pending_imports (
            id TEXT PRIMARY KEY NOT NULL,
            playlistID TEXT NOT NULL CHECK(length(playlistID) = 22),
            sharedAt DATETIME NOT NULL,
            receivedAt DATETIME NOT NULL,
            presentedAt DATETIME,
            state TEXT NOT NULL CHECK(state IN ('pending','imported')),
            migrationID TEXT REFERENCES playlist_migrations(id) ON DELETE SET NULL,
            updatedAt DATETIME NOT NULL
        );
        CREATE UNIQUE INDEX spotify_pending_imports_open ON spotify_pending_imports(playlistID) WHERE state = 'pending';
        CREATE INDEX spotify_pending_imports_order ON spotify_pending_imports(state, sharedAt, receivedAt);
        """

    private struct Installed {
        let fixture: LibraryFixture
        let ordinary: StoredPlaylist
        let imported: PlaylistMigrationSession
    }

    /// A realistic library (audio files, a liked song, an ordinary playlist, an imported
    /// playlist with a removed occurrence), then exactly what the 10.8 IPA added on launch
    /// plus one pending and one imported Spotify share row.
    private func phase108Installation() async throws -> Installed {
        let fixture = try LibraryFixture(count: 3)
        retainUntilTeardown(fixture)
        let ordinary = try fixture.repository.createPlaylist(name: "Ordinary")
        try fixture.repository.addTracks(fixture.ids, playlistID: ordinary.id)
        let candidate = try XCTUnwrap(PlaylistImportFixtures.parse(ReleaseImportFixtures.csv(50, repeats: [30: 5]), filename: "Imported.csv").candidates.first)
        let imported = try await PlaylistImportCoordinator(persistence: fixture.storage.playlistMigrations).commit(candidate, destinationName: "Imported").session
        let entries = try await fixture.storage.playlistMigrations.entries(migrationID: imported.id)
        try await fixture.storage.playlistMigrations.removeOccurrence(entryID: entries[7].id, playlistID: try XCTUnwrap(imported.destinationPlaylistID))
        let now = Date(), liked = fixture.ids[0]
        try await fixture.storage.database.dbQueue.write { db in
            try StoredLikedTrack(trackID: liked, dateLiked: now).insert(db)
            try db.execute(sql: Self.canceledSchema)
            try db.execute(sql: "INSERT INTO grdb_migrations (identifier) VALUES (?)", arguments: [Self.canceledMigration])
            try db.execute(sql: """
                INSERT INTO spotify_pending_imports (id, playlistID, sharedAt, receivedAt, presentedAt, state, migrationID, updatedAt)
                VALUES (?, '37i9dQZF1DXcBWIGoYBM5M', ?, ?, NULL, 'pending', NULL, ?),
                       (?, '37i9dQZF1DX0XUsuxWHRQd', ?, ?, ?, 'imported', ?, ?)
                """, arguments: [UUID().uuidString, now, now, now, UUID().uuidString, now, now, now, imported.id.uuidString, now])
        }
        return Installed(fixture: fixture, ordinary: ordinary, imported: imported)
    }

    func testCandidateOpensA108DatabaseWithoutChangingAnyUserDataOrTheLeftoverTable() async throws {
        let installed = try await phase108Installation()
        let fixture = installed.fixture
        let before = try ReleaseIntegritySnapshot.capture(fixture.storage.database.dbQueue, paths: fixture.paths)
        XCTAssertEqual(before.rows("spotify_pending_imports"), 2)

        // The exact open the app performs first: every known migration is already applied and
        // the unknown v023 record is neither a failure nor a reason to erase anything.
        let reopened = try DatabaseManager(url: fixture.paths.database)
        let identifiers = try await reopened.dbQueue.read { try String.fetchAll($0, sql: "SELECT identifier FROM grdb_migrations ORDER BY identifier") }
        // v001–v022, the canceled v023 record, and Phase 11.1's v024.
        XCTAssertEqual(identifiers.count, 24)
        XCTAssertTrue(identifiers.contains(Self.canceledMigration), "The historical record is kept")
        XCTAssertEqual(identifiers.last, LocalProfileSchema.version)
        XCTAssertTrue(identifiers.contains(PlaylistLinkDownloadSchema.version))
        let after = try ReleaseIntegritySnapshot.capture(reopened.dbQueue, paths: fixture.paths)
        XCTAssertEqual(after, before, "Opening a 10.8 database changed data: \(before) → \(after)")
        let violations = try await reopened.dbQueue.read { try Row.fetchAll($0, sql: "PRAGMA foreign_key_check").count }
        let integrity = try await reopened.dbQueue.read { try String.fetchOne($0, sql: "PRAGMA integrity_check") }
        XCTAssertEqual(violations, 0); XCTAssertEqual(integrity, "ok")

        // The full app launch path (recovery, reconciliation, migration recovery) also works.
        let launched = try StorageCoordinator(paths: fixture.paths)
        let launchedSnapshot = try ReleaseIntegritySnapshot.capture(launched.database.dbQueue, paths: fixture.paths)
        for table in ["tracks", "playlists", "playlist_tracks", "liked_tracks", "migration_entries", "playlist_migrations", "spotify_pending_imports"] {
            XCTAssertEqual(launchedSnapshot.tables[table], before.tables[table], "Launch changed \(table)")
        }
        XCTAssertEqual(launchedSnapshot.files, before.files)
        let library = try LibraryRepository(db: launched.database.dbQueue).snapshot()
        XCTAssertEqual(library.playlistTracks(installed.ordinary.id).map(\.id), fixture.ids)
        XCTAssertEqual(library.likedIDs, [fixture.ids[0]])
        let entries = try await launched.playlistMigrations.entries(migrationID: installed.imported.id)
        XCTAssertEqual(entries.count, 49, "The removed occurrence stays removed")
        XCTAssertEqual(entries.map(\.position), Array(0..<50).filter { $0 != 7 })
    }

    /// The leftover table references `playlist_migrations` (ON DELETE SET NULL). Deleting an
    /// imported playlist must still work and keep the database consistent.
    func testDeletingAnImportedPlaylistReferencedByALeftoverRowSucceeds() async throws {
        let installed = try await phase108Installation()
        let fixture = installed.fixture
        let launched = try StorageCoordinator(paths: fixture.paths)
        let repository = LibraryRepository(db: launched.database.dbQueue)
        _ = try repository.deletePlaylist(id: try XCTUnwrap(installed.imported.destinationPlaylistID), confirmed: true)
        let references = try await launched.database.dbQueue.read { db in
            try Row.fetchAll(db, sql: "SELECT migrationID FROM spotify_pending_imports").map { $0["migrationID"] as String? }
        }
        XCTAssertEqual(references.count, 2, "Leftover rows are not deleted")
        XCTAssertTrue(references.allSatisfy { $0 == nil })
        let sessions = try await launched.database.dbQueue.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM playlist_migrations") }
        let violations = try await launched.database.dbQueue.read { try Row.fetchAll($0, sql: "PRAGMA foreign_key_check").count }
        XCTAssertEqual(sessions, 0); XCTAssertEqual(violations, 0)
        XCTAssertEqual(try repository.snapshot().playlistTracks(installed.ordinary.id).map(\.id), fixture.ids)
        for id in fixture.ids { XCTAssertTrue(FileManager.default.fileExists(atPath: try fixture.paths.musicURL(relativePath: "\(id).wav").path)) }
    }

    /// After the upgrade, normal work (a new import, a manual playlist) uses the supported
    /// pipeline and adds no schema migration.
    func testNormalImportAndPlaylistEditingContinueAfterTheUpgrade() async throws {
        let installed = try await phase108Installation()
        let launched = try StorageCoordinator(paths: installed.fixture.paths)
        let candidate = try XCTUnwrap(PlaylistImportFixtures.parse(ReleaseImportFixtures.csv(200), filename: "After upgrade.csv").candidates.first)
        let commit = try await PlaylistImportCoordinator(persistence: launched.playlistMigrations).commit(candidate, destinationName: "After upgrade")
        let entries = try await launched.playlistMigrations.entries(migrationID: commit.session.id)
        assertOccurrenceInvariant(entries, source: try XCTUnwrap(candidate.source))
        let manual = try LibraryRepository(db: launched.database.dbQueue).createPlaylist(name: "Manual after upgrade")
        try LibraryRepository(db: launched.database.dbQueue).addTracks([installed.fixture.ids[1]], playlistID: manual.id)
        let migrations = try await launched.database.dbQueue.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM grdb_migrations") }
        let leftovers = try await launched.database.dbQueue.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM spotify_pending_imports") }
        XCTAssertEqual(migrations, 24); XCTAssertEqual(leftovers, 2)
    }
}
