import Foundation
import GRDB

/// Phase 11.5 (`v027_dynamic_collection_artwork`). Additive, after `v026_portable_library_sharing`.
///
/// One row per collection whose artwork mode differs from the app default. "Use App Default"
/// is the absence of a row, so every existing and newly created collection starts on the
/// default without any write. Triggers remove a row when its playlist, album or artist is
/// deleted. Mosaics themselves are derived presentation state and are never stored.
enum CollectionArtworkSchema {
    static let version = "v027_dynamic_collection_artwork"
    static let table = "collection_artwork_preferences"

    static func register(in migrator: inout DatabaseMigrator) {
        migrator.registerMigration(version) { db in
            try db.execute(sql: """
                CREATE TABLE collection_artwork_preferences (
                    collectionKind TEXT NOT NULL CHECK(collectionKind IN ('playlist', 'album', 'artist')),
                    collectionID TEXT NOT NULL CHECK(length(collectionID) BETWEEN 1 AND 512),
                    artworkMode TEXT NOT NULL CHECK(artworkMode IN ('automatic', 'static')),
                    updatedAt DATETIME NOT NULL,
                    PRIMARY KEY (collectionKind, collectionID)
                );
                CREATE TRIGGER collection_artwork_preferences_playlist_deleted AFTER DELETE ON playlists BEGIN
                    DELETE FROM collection_artwork_preferences WHERE collectionKind = 'playlist' AND collectionID = OLD.id;
                END;
                CREATE TRIGGER collection_artwork_preferences_album_deleted AFTER DELETE ON albums BEGIN
                    DELETE FROM collection_artwork_preferences WHERE collectionKind = 'album' AND collectionID = OLD.id;
                END;
                CREATE TRIGGER collection_artwork_preferences_artist_deleted AFTER DELETE ON artists BEGIN
                    DELETE FROM collection_artwork_preferences WHERE collectionKind = 'artist' AND collectionID = OLD.id;
                END;
                """)
        }
    }
}

enum CollectionArtworkPreferenceError: LocalizedError, Equatable {
    case unsupportedCollection
    var errorDescription: String? { "This collection always follows the app's artwork setting." }
}

/// Per-collection artwork modes in GRDB.
final class CollectionArtworkRepository: @unchecked Sendable {
    let db: DatabaseQueue
    init(db: DatabaseQueue) { self.db = db }

    /// Unknown kinds or modes (a future version's rows) are ignored: they mean "app default".
    static func preferences(_ db: Database) throws -> [CollectionArtworkIdentity: CollectionArtworkMode] {
        var result: [CollectionArtworkIdentity: CollectionArtworkMode] = [:]
        for row in try Row.fetchAll(db, sql: "SELECT collectionKind, collectionID, artworkMode FROM collection_artwork_preferences") {
            guard let kindName = row["collectionKind"] as String?, let kind = CollectionArtworkKind(rawValue: kindName), kind.hasPersistentPreference,
                  let id = row["collectionID"] as String?, !id.isEmpty,
                  let modeName = row["artworkMode"] as String?, let mode = CollectionArtworkMode(rawValue: modeName), mode != .appDefault
            else { continue }
            result[CollectionArtworkIdentity(kind: kind, id: id)] = mode
        }
        return result
    }

    func preferences() throws -> [CollectionArtworkIdentity: CollectionArtworkMode] { try db.read(Self.preferences) }

    /// `.appDefault` deletes the row. A mode for a collection that no longer exists is refused.
    func setMode(_ mode: CollectionArtworkMode, for identity: CollectionArtworkIdentity, now: Date = Date()) throws {
        guard identity.kind.hasPersistentPreference, let owner = identity.kind.ownerTable else { throw CollectionArtworkPreferenceError.unsupportedCollection }
        try db.write { db in
            if mode == .appDefault {
                try db.execute(sql: "DELETE FROM collection_artwork_preferences WHERE collectionKind = ? AND collectionID = ?",
                               arguments: [identity.kind.rawValue, identity.id])
                return
            }
            // `owner` is one of three fixed table names; the identifier is bound.
            guard try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM \(owner) WHERE id = ?", arguments: [identity.id]) == 1 else { throw LibraryError.notFound }
            try db.execute(sql: """
                INSERT INTO collection_artwork_preferences (collectionKind, collectionID, artworkMode, updatedAt) VALUES (?, ?, ?, ?)
                ON CONFLICT(collectionKind, collectionID) DO UPDATE SET artworkMode = excluded.artworkMode, updatedAt = excluded.updatedAt
                """, arguments: [identity.kind.rawValue, identity.id, mode.rawValue, now])
        }
    }
}

/// The global "Automatic Collection Artwork" switch. Injected so tests and UI tests never touch
/// the real preferences.
protocol CollectionArtworkDefaultStoring: AnyObject {
    /// `nil` when nothing was saved yet (the default, enabled, applies).
    func load() -> Bool?
    func save(_ enabled: Bool) throws
}

/// `UserDefaults` storage under one versioned key, consistent with the theme preference.
final class UserDefaultsCollectionArtworkDefaults: CollectionArtworkDefaultStoring {
    static let key = "artwork.automaticCollections.v1"
    private let defaults: UserDefaults
    init(defaults: UserDefaults = .standard) { self.defaults = defaults }
    func load() -> Bool? { defaults.object(forKey: Self.key) as? Bool }
    func save(_ enabled: Bool) throws { defaults.set(enabled, forKey: Self.key) }
}
