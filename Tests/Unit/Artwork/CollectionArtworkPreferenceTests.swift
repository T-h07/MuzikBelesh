import Foundation
import GRDB
import XCTest
@testable import OFFLINE

/// Phase 11.5 preferences: the global `UserDefaults` switch, per-collection GRDB modes and
/// the additive `v027_dynamic_collection_artwork` migration.
final class CollectionArtworkPreferenceTests: XCTestCase {
    // MARK: Global switch

    func testGlobalSwitchDefaultsToEnabledAndPersistsUnderAVersionedKey() throws {
        let suite = "CollectionArtworkPreferenceTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertEqual(UserDefaultsCollectionArtworkDefaults.key, "artwork.automaticCollections.v1")
        let store = UserDefaultsCollectionArtworkDefaults(defaults: defaults)
        XCTAssertNil(store.load())
        try store.save(false)
        XCTAssertEqual(UserDefaultsCollectionArtworkDefaults(defaults: defaults).load(), false, "Survives a new process reading the same suite")
        try store.save(true)
        XCTAssertEqual(store.load(), true)
    }

    @MainActor func testServiceUsesTheSavedGlobalSwitchAndKeepsItOnWriteFailure() throws {
        let enabled = CollectionArtworkService(library: nil, database: nil, paths: nil, store: MemoryArtworkDefaults(), foreground: false)
        XCTAssertTrue(enabled.automaticByDefault, "Existing users default to automatic mosaics")
        let store = MemoryArtworkDefaults(false)
        let service = CollectionArtworkService(library: nil, database: nil, paths: nil, store: store, foreground: false)
        XCTAssertFalse(service.automaticByDefault)
        store.failing = true
        service.setAutomaticByDefault(true)
        XCTAssertFalse(service.automaticByDefault, "A failed write keeps the previous choice")
        XCTAssertNotNil(service.lastError)
        store.failing = false
        service.setAutomaticByDefault(true)
        XCTAssertTrue(service.automaticByDefault); XCTAssertNil(service.lastError); XCTAssertEqual(store.value, true)
    }

    // MARK: Per-collection modes

    func testModesPersistAndAppDefaultRemovesTheRow() throws {
        let fixture = try LibraryFixture(count: 1); retainUntilTeardown(fixture)
        let playlist = try fixture.repository.createPlaylist(name: "Modes")
        let repository = CollectionArtworkRepository(db: fixture.storage.database.dbQueue)
        let identity = CollectionArtworkIdentity.playlist(playlist.id)
        XCTAssertEqual(try repository.preferences(), [:], "A new collection starts on the app default without any row")
        try repository.setMode(.staticArtwork, for: identity)
        XCTAssertEqual(try repository.preferences()[identity], .staticArtwork)
        try repository.setMode(.automatic, for: identity)
        XCTAssertEqual(try repository.preferences()[identity], .automatic)
        XCTAssertEqual(try fixture.preferenceRows(), 1, "Upserted, never duplicated")
        let reopened = CollectionArtworkRepository(db: try StorageCoordinator(paths: fixture.paths).database.dbQueue)
        XCTAssertEqual(try reopened.preferences()[identity], .automatic, "Survives relaunch")
        try repository.setMode(.appDefault, for: identity)
        XCTAssertEqual(try fixture.preferenceRows(), 0)
    }

    func testModesAreRefusedForMissingOrVirtualCollections() throws {
        let fixture = try LibraryFixture(count: 1); retainUntilTeardown(fixture)
        let repository = CollectionArtworkRepository(db: fixture.storage.database.dbQueue)
        XCTAssertThrowsError(try repository.setMode(.automatic, for: .playlist("missing"))) { XCTAssertEqual($0 as? LibraryError, .notFound) }
        XCTAssertThrowsError(try repository.setMode(.automatic, for: .album(LibrarySnapshot.unassignedAlbumID))) {
            XCTAssertEqual($0 as? CollectionArtworkPreferenceError, .unsupportedCollection)
        }
        XCTAssertEqual(try fixture.preferenceRows(), 0)
    }

    func testUnknownStoredValuesFallBackToTheAppDefault() throws {
        let fixture = try LibraryFixture(count: 1); retainUntilTeardown(fixture)
        let playlist = try fixture.repository.createPlaylist(name: "Future")
        try fixture.storage.database.dbQueue.writeWithoutTransaction { db in
            try db.execute(sql: "PRAGMA ignore_check_constraints = ON")
            try db.execute(sql: "INSERT INTO collection_artwork_preferences VALUES ('playlist', ?, 'sideways', ?)", arguments: [playlist.id, Date()])
            try db.execute(sql: "INSERT INTO collection_artwork_preferences VALUES ('genre', 'rock', 'automatic', ?)", arguments: [Date()])
            try db.execute(sql: "PRAGMA ignore_check_constraints = OFF")
        }
        XCTAssertEqual(try CollectionArtworkRepository(db: fixture.storage.database.dbQueue).preferences(), [:])
    }

    func testDeletingACollectionRemovesItsPreference() throws {
        let fixture = try LibraryFixture(count: 2); retainUntilTeardown(fixture)
        let playlist = try fixture.repository.createPlaylist(name: "Doomed")
        let album = try fixture.repository.saveAlbum(draft: AlbumDraft(title: "Doomed Album", artist: "Doomed Artist"), trackIDs: [fixture.ids[0]])
        let artistID = try XCTUnwrap(album.artistID)
        let repository = CollectionArtworkRepository(db: fixture.storage.database.dbQueue)
        try repository.setMode(.staticArtwork, for: .playlist(playlist.id))
        try repository.setMode(.automatic, for: .album(album.id))
        try repository.setMode(.staticArtwork, for: .artist(artistID))
        XCTAssertEqual(try fixture.preferenceRows(), 3)
        _ = try fixture.repository.deletePlaylist(id: playlist.id, confirmed: true)
        _ = try fixture.repository.deleteAlbum(id: album.id, confirmed: true)
        try deleteArtist(artistID, fixture)
        XCTAssertEqual(try fixture.preferenceRows(), 0)
    }

    private func deleteArtist(_ id: String, _ fixture: LibraryFixture) throws {
        try fixture.storage.database.dbQueue.write { db in try db.execute(sql: "DELETE FROM artists WHERE id = ?", arguments: [id]) }
    }

    @MainActor func testPerCollectionModesOverrideTheGlobalDefaultInBothDirections() throws {
        let fixture = try LibraryFixture(count: 1); retainUntilTeardown(fixture)
        let (_, _, library) = fixture.services()
        let on = try fixture.repository.createPlaylist(name: "Forced on")
        let off = try fixture.repository.createPlaylist(name: "Forced off")
        let inherits = try fixture.repository.createPlaylist(name: "Inherits")
        let store = MemoryArtworkDefaults(false)
        let service = fixture.artworkService(library: library, store: store)
        service.setMode(.automatic, for: .playlist(on.id))
        service.setMode(.staticArtwork, for: .playlist(off.id))
        XCTAssertTrue(service.mosaicEnabled(for: .playlist(on.id)), "An explicit choice overrides a disabled global setting")
        XCTAssertFalse(service.mosaicEnabled(for: .playlist(off.id)))
        XCTAssertFalse(service.mosaicEnabled(for: .playlist(inherits.id)))
        service.setAutomaticByDefault(true)
        XCTAssertTrue(service.mosaicEnabled(for: .playlist(inherits.id)), "New and untouched collections inherit the global default")
        XCTAssertFalse(service.mosaicEnabled(for: .playlist(off.id)), "Static stays static")
        XCTAssertTrue(service.mosaicEnabled(for: .album(LibrarySnapshot.unassignedAlbumID)))
        XCTAssertEqual(service.mode(for: .playlist(inherits.id)), .appDefault)

        // A relaunch restores both levels from storage.
        let relaunched = fixture.artworkService(library: library, store: MemoryArtworkDefaults(store.value))
        XCTAssertEqual(relaunched.mode(for: .playlist(on.id)), .automatic)
        XCTAssertEqual(relaunched.mode(for: .playlist(off.id)), .staticArtwork)
        XCTAssertTrue(relaunched.automaticByDefault)
    }

    @MainActor func testRapidModeSwitchingEndsOnTheLastChoice() throws {
        let fixture = try LibraryFixture(count: 1); retainUntilTeardown(fixture)
        let (_, _, library) = fixture.services()
        let playlist = try fixture.repository.createPlaylist(name: "Flip")
        let service = fixture.artworkService(library: library)
        let identity = CollectionArtworkIdentity.playlist(playlist.id)
        for index in 0..<50 { service.setMode(index.isMultiple(of: 2) ? .staticArtwork : .automatic, for: identity) }
        service.setMode(.staticArtwork, for: identity)
        XCTAssertEqual(service.mode(for: identity), .staticArtwork)
        XCTAssertEqual(try CollectionArtworkRepository(db: fixture.storage.database.dbQueue).preferences()[identity], .staticArtwork)
        XCTAssertEqual(try fixture.preferenceRows(), 1)
        service.setMode(.automatic, for: .playlist("deleted-meanwhile"))
        XCTAssertNotNil(service.lastError, "A failed write is reported and changes nothing")
        XCTAssertEqual(service.mode(for: .playlist("deleted-meanwhile")), .appDefault)
    }

    // MARK: Migration

    func testMigrationIdentifierIsAppendOnly() {
        XCTAssertEqual(CollectionArtworkSchema.version, "v027_dynamic_collection_artwork")
        XCTAssertGreaterThan(CollectionArtworkSchema.version, PortableLibrarySchema.version)
        XCTAssertNotEqual(CollectionArtworkSchema.version, CanceledPhase108UpgradeTests.canceledMigration)
    }

    func testUpgradeFromPhase114PreservesCollectionsAndCustomCovers() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ArtworkSchema-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("library.sqlite")
        let old = try DatabaseManager(url: url, migrationTarget: PortableLibrarySchema.version)
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        try old.dbQueue.write { db in
            try StoredPlaylist(id: "custom", name: "Custom", description: "kept", artworkRelativePath: "artwork-custom.jpg", dateAdded: now, dateModified: now).insert(db)
            try StoredPlaylist(id: "empty", name: "Empty", description: nil, artworkRelativePath: nil, dateAdded: now, dateModified: now).insert(db)
            try StoredAlbum(id: "album", title: "Album", normalizedTitle: "album", artistID: nil, artworkRelativePath: "artwork-album.jpg", dateAdded: now, dateModified: now).insert(db)
            try StoredTrack(id: "song", title: "Song", artistID: nil, albumID: "album", durationMs: 1000, fileRelativePath: "song.wav", fileExtension: "wav", fileSizeBytes: 1,
                            contentSHA256: "hash", artworkRelativePath: "artwork-custom.jpg", availability: .available, dateAdded: now, dateModified: now,
                            originalFilename: nil, metadataSource: "test").insert(db)
            try db.execute(sql: "INSERT INTO playlist_tracks (playlistID, trackID, position, dateAdded) VALUES ('custom', 'song', 0, ?)", arguments: [now])
        }
        func rows(_ queue: DatabaseQueue) throws -> [String: [Row]] {
            try queue.read { db in
                var result: [String: [Row]] = [:]
                for table in ["playlists", "albums", "tracks", "playlist_tracks"] { result[table] = try Row.fetchAll(db, sql: "SELECT * FROM \(table) ORDER BY rowid") }
                return result
            }
        }
        let before = try rows(old.dbQueue)
        XCTAssertFalse(try old.dbQueue.read { try $0.tableExists(CollectionArtworkSchema.table) })
        let upgraded = try DatabaseManager(url: url)
        XCTAssertEqual(try rows(upgraded.dbQueue), before, "Existing records, including custom cover paths, are unchanged")
        try upgraded.dbQueue.read { db in
            XCTAssertTrue(try db.tableExists(CollectionArtworkSchema.table))
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM collection_artwork_preferences"), 0, "Everyone starts on the app default")
            XCTAssertEqual(try String.fetchAll(db, sql: "SELECT identifier FROM grdb_migrations ORDER BY identifier").last, CollectionArtworkSchema.version)
            XCTAssertEqual(try Row.fetchAll(db, sql: "PRAGMA foreign_key_check").count, 0)
            XCTAssertEqual(try String.fetchOne(db, sql: "PRAGMA integrity_check"), "ok")
            let triggers = try String.fetchAll(db, sql: "SELECT name FROM sqlite_master WHERE type = 'trigger' AND tbl_name IN ('playlists', 'albums', 'artists') ORDER BY name")
            XCTAssertEqual(triggers, ["collection_artwork_preferences_album_deleted", "collection_artwork_preferences_artist_deleted", "collection_artwork_preferences_playlist_deleted"])
        }
        _ = try DatabaseManager(url: url) // Reopening is idempotent.
    }
}
