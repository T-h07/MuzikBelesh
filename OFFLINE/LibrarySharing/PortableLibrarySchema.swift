import Foundation
import GRDB

/// Phase 11.4 (`v026_portable_library_sharing`). Additive, after `v025_listening_analytics`.
///
/// 1. `playlist_migrations` is rebuilt so its `source` CHECK also admits `muzikBelesh`. A
///    native Muzik Belesh import is a new source and is never labelled as Spotify. Every
///    column, row (including its rowid), primary key, UNIQUE constraint and the
///    `playlist_migrations_status` index are preserved; child tables keep their textual
///    `REFERENCES playlist_migrations(id)` clauses, which resolve to the rebuilt table.
///    GRDB runs migrations with foreign keys disabled and checks them before commit, so the
///    DROP never cascades; the migration refuses to run if enforcement is somehow active.
/// 2. `portable_library_imports` — one durable row per confirmed import (operation identity,
///    request fingerprint, the user's acquisition choice and the post-commit phase).
/// 3. `portable_library_import_items` — which migration sessions an import created, their
///    document playlist identity and canonical content fingerprint (duplicate detection).
/// 4. `portable_library_entries` — per occurrence: document song reference, the validated
///    recording references from the document, and the local-reuse/reference resolution.
///
/// Historical migrations are never edited and no legacy row changes meaning.
enum PortableLibrarySchema {
    static let version = "v026_portable_library_sharing"

    enum Failure: Error { case foreignKeysEnforcedDuringRebuild }

    static func register(in migrator: inout DatabaseMigrator) {
        migrator.registerMigration(version) { db in
            guard try Bool.fetchOne(db, sql: "PRAGMA foreign_keys") != true else { throw Failure.foreignKeysEnforcedDuringRebuild }
            try db.execute(sql: """
                CREATE TABLE playlist_migrations_v026 (
                    id TEXT PRIMARY KEY NOT NULL,
                    destinationPlaylistID TEXT NOT NULL UNIQUE REFERENCES playlists(id) ON DELETE CASCADE,
                    operationID TEXT NOT NULL UNIQUE CHECK(length(operationID) BETWEEN 1 AND 200),
                    source TEXT NOT NULL CHECK(source IN ('spotifyAccountExport','exportify','spotifyAPI','muzikBelesh')),
                    sourcePlaylistID TEXT, sourceReference TEXT, sourcePlaylistName TEXT NOT NULL,
                    importFingerprint TEXT NOT NULL, expectedEntryCount INTEGER NOT NULL CHECK(expectedEntryCount BETWEEN 0 AND 10000),
                    status TEXT NOT NULL CHECK(status IN ('preparing','importingMetadata','metadataReady','matching','awaitingReview','downloading','verifying','completed','partiallyCompleted','paused','cancelled','failed')),
                    createdAt DATETIME NOT NULL, updatedAt DATETIME NOT NULL, failureInformation TEXT
                );
                INSERT INTO playlist_migrations_v026 (rowid, id, destinationPlaylistID, operationID, source, sourcePlaylistID, sourceReference,
                    sourcePlaylistName, importFingerprint, expectedEntryCount, status, createdAt, updatedAt, failureInformation)
                SELECT rowid, id, destinationPlaylistID, operationID, source, sourcePlaylistID, sourceReference,
                    sourcePlaylistName, importFingerprint, expectedEntryCount, status, createdAt, updatedAt, failureInformation
                FROM playlist_migrations;
                DROP TABLE playlist_migrations;
                ALTER TABLE playlist_migrations_v026 RENAME TO playlist_migrations;
                CREATE INDEX playlist_migrations_status ON playlist_migrations(status, createdAt);

                CREATE TABLE portable_library_imports (
                    id TEXT PRIMARY KEY NOT NULL,
                    operationID TEXT NOT NULL UNIQUE CHECK(length(operationID) BETWEEN 1 AND 200),
                    requestFingerprint TEXT NOT NULL CHECK(length(requestFingerprint) BETWEEN 1 AND 200),
                    exportID TEXT NOT NULL CHECK(length(exportID) BETWEEN 1 AND 64),
                    documentName TEXT NOT NULL CHECK(length(documentName) BETWEEN 1 AND 255),
                    schemaVersion INTEGER NOT NULL CHECK(schemaVersion >= 1),
                    automaticAcquisition BOOLEAN NOT NULL,
                    phase TEXT NOT NULL CHECK(phase IN ('committed','reconciling','handedOff','cancelled')),
                    createdAt DATETIME NOT NULL,
                    updatedAt DATETIME NOT NULL
                );
                CREATE TABLE portable_library_import_items (
                    migrationID TEXT PRIMARY KEY NOT NULL REFERENCES playlist_migrations(id) ON DELETE CASCADE,
                    importID TEXT NOT NULL REFERENCES portable_library_imports(id) ON DELETE CASCADE,
                    kind TEXT NOT NULL CHECK(kind IN ('playlist','standaloneSongs')),
                    documentPlaylistID TEXT CHECK(documentPlaylistID IS NULL OR length(documentPlaylistID) BETWEEN 1 AND 64),
                    contentFingerprint TEXT NOT NULL CHECK(length(contentFingerprint) BETWEEN 1 AND 200),
                    ordinal INTEGER NOT NULL CHECK(ordinal >= 0),
                    UNIQUE(importID, ordinal)
                );
                CREATE INDEX portable_library_import_items_import ON portable_library_import_items(importID);
                CREATE INDEX portable_library_import_items_fingerprint ON portable_library_import_items(contentFingerprint);
                CREATE TABLE portable_library_entries (
                    entryID TEXT PRIMARY KEY NOT NULL REFERENCES migration_entries(id) ON DELETE CASCADE,
                    migrationID TEXT NOT NULL REFERENCES playlist_migrations(id) ON DELETE CASCADE,
                    importID TEXT NOT NULL REFERENCES portable_library_imports(id) ON DELETE CASCADE,
                    songRef TEXT NOT NULL CHECK(length(songRef) BETWEEN 1 AND 64),
                    recordings TEXT NOT NULL CHECK(length(recordings) <= 200),
                    resolution TEXT NOT NULL CHECK(resolution IN ('pending','provenance','localMatch','reference','proposed','deferred')),
                    updatedAt DATETIME NOT NULL
                );
                CREATE INDEX portable_library_entries_import ON portable_library_entries(importID, resolution);
                CREATE INDEX portable_library_entries_migration ON portable_library_entries(migrationID);
                """)
        }
    }
}

enum PortableImportPhase: String, Codable, DatabaseValueConvertible, Sendable {
    /// Metadata committed; local reuse and reference resolution not started.
    case committed
    /// Local reuse / document reference resolution in progress (resumed after relaunch).
    case reconciling
    /// Remaining work belongs to the migration coordinator (matching, acquisition, review).
    case handedOff
    /// The user cancelled remaining work. Playlists and verified audio are kept.
    case cancelled
}

enum PortableImportItemKind: String, Codable, DatabaseValueConvertible, Sendable {
    case playlist
    /// Full-library songs that were in no playlist, gathered in a clearly labelled collection.
    case standaloneSongs
}

enum PortableEntryResolution: String, Codable, DatabaseValueConvertible, Sendable {
    case pending
    /// Reused a local track that already holds the referenced YouTube recording.
    case provenance
    /// Reused a local track through the established local metadata matching policy.
    case localMatch
    /// The document's recording reference passed the strict automatic policy and was accepted.
    case reference
    /// The document's recording reference was saved as a candidate for review.
    case proposed
    /// Left to ordinary matching (local, discovery, review).
    case deferred
}

struct PortableLibraryImportRecord: Codable, FetchableRecord, PersistableRecord, Identifiable, Equatable, Sendable {
    static let databaseTableName = "portable_library_imports"
    var id: String
    var operationID: String
    var requestFingerprint: String
    var exportID: String
    var documentName: String
    var schemaVersion: Int
    var automaticAcquisition: Bool
    var phase: PortableImportPhase
    var createdAt: Date
    var updatedAt: Date
}

struct PortableLibraryImportItemRecord: Codable, FetchableRecord, PersistableRecord, Equatable, Sendable {
    static let databaseTableName = "portable_library_import_items"
    var migrationID: String
    var importID: String
    var kind: PortableImportItemKind
    var documentPlaylistID: String?
    var contentFingerprint: String
    var ordinal: Int
}

struct PortableLibraryEntryRecord: Codable, FetchableRecord, PersistableRecord, Equatable, Sendable {
    static let databaseTableName = "portable_library_entries"
    var entryID: String
    var migrationID: String
    var importID: String
    var songRef: String
    /// JSON array of validated YouTube video IDs, preferred first.
    var recordings: String
    var resolution: PortableEntryResolution
    var updatedAt: Date

    var videoIDs: [String] {
        ((try? JSONDecoder().decode([String].self, from: Data(recordings.utf8))) ?? []).filter(YouTubeURLValidator.isValidID)
    }
    static func encode(_ ids: [String]) -> String {
        let valid = Array(ids.filter(YouTubeURLValidator.isValidID).prefix(PortableLibraryLimits.recordingsPerSong))
        return (try? String(decoding: JSONEncoder().encode(valid), as: UTF8.self)) ?? "[]"
    }
}
