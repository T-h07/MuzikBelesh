import GRDB

enum MigrationStorageSchema {
    static func register(in migrator: inout DatabaseMigrator) {
        migrator.registerMigration("v013_playlist_migration_storage") { db in
            try db.execute(sql: """
                CREATE TABLE playlist_migrations (
                    id TEXT PRIMARY KEY NOT NULL,
                    destinationPlaylistID TEXT NOT NULL UNIQUE REFERENCES playlists(id) ON DELETE CASCADE,
                    operationID TEXT NOT NULL UNIQUE CHECK(length(operationID) BETWEEN 1 AND 200),
                    source TEXT NOT NULL CHECK(source IN ('spotifyAccountExport','exportify','spotifyAPI')),
                    sourcePlaylistID TEXT, sourcePlaylistName TEXT NOT NULL,
                    importFingerprint TEXT NOT NULL, expectedEntryCount INTEGER NOT NULL CHECK(expectedEntryCount BETWEEN 0 AND 10000),
                    status TEXT NOT NULL CHECK(status IN ('preparing','importingMetadata','metadataReady','matching','awaitingReview','downloading','verifying','completed','partiallyCompleted','paused','cancelled','failed')),
                    createdAt DATETIME NOT NULL, updatedAt DATETIME NOT NULL, failureInformation TEXT
                );
                CREATE INDEX playlist_migrations_status ON playlist_migrations(status, createdAt);
                CREATE TABLE migration_entries (
                    id TEXT PRIMARY KEY NOT NULL,
                    migrationID TEXT NOT NULL REFERENCES playlist_migrations(id) ON DELETE CASCADE,
                    sourcePosition INTEGER NOT NULL CHECK(sourcePosition >= 0),
                    title TEXT NOT NULL, primaryArtist TEXT, additionalArtists TEXT NOT NULL,
                    album TEXT, durationMs INTEGER CHECK(durationMs >= 0), sourceTrackID TEXT, sourceURI TEXT, artworkURL TEXT,
                    localTrackID TEXT REFERENCES tracks(id) ON DELETE SET NULL,
                    status TEXT NOT NULL CHECK(status IN ('pending','matching','needsReview','matched','queued','downloading','verifying','ready','unavailable','failed','skipped')),
                    createdAt DATETIME NOT NULL, updatedAt DATETIME NOT NULL,
                    UNIQUE(migrationID, sourcePosition), UNIQUE(migrationID, id)
                );
                CREATE INDEX migration_entries_localTrack ON migration_entries(localTrackID);
                CREATE INDEX migration_entries_status ON migration_entries(migrationID, status);
                CREATE TABLE migration_candidates (
                    id TEXT PRIMARY KEY NOT NULL,
                    entryID TEXT NOT NULL REFERENCES migration_entries(id) ON DELETE CASCADE,
                    provider TEXT NOT NULL, providerTrackID TEXT, title TEXT NOT NULL, artist TEXT,
                    durationMs INTEGER CHECK(durationMs >= 0), confidence REAL CHECK(confidence BETWEEN 0 AND 1),
                    evidence TEXT NOT NULL, decision TEXT NOT NULL CHECK(decision IN ('pending','accepted','rejected')),
                    createdAt DATETIME NOT NULL, updatedAt DATETIME NOT NULL
                );
                CREATE INDEX migration_candidates_entry ON migration_candidates(entryID, createdAt, id);
                CREATE TABLE migration_issues (
                    id TEXT PRIMARY KEY NOT NULL,
                    migrationID TEXT NOT NULL REFERENCES playlist_migrations(id) ON DELETE CASCADE,
                    entryID TEXT,
                    code TEXT NOT NULL, message TEXT NOT NULL, technicalDetails TEXT,
                    severity TEXT NOT NULL CHECK(severity IN ('information','warning','blocking')),
                    resolution TEXT NOT NULL CHECK(resolution IN ('open','resolved','dismissed')),
                    createdAt DATETIME NOT NULL, updatedAt DATETIME NOT NULL, resolvedAt DATETIME,
                    FOREIGN KEY(migrationID, entryID) REFERENCES migration_entries(migrationID, id) ON DELETE CASCADE
                );
                CREATE INDEX migration_issues_resolution ON migration_issues(migrationID, resolution);
                CREATE INDEX migration_issues_entry ON migration_issues(entryID);
                CREATE TRIGGER migration_track_deleted BEFORE DELETE ON tracks BEGIN
                    UPDATE migration_entries SET status = 'unavailable', updatedAt = CURRENT_TIMESTAMP
                    WHERE localTrackID = OLD.id AND status = 'ready';
                END;
                CREATE TRIGGER migration_track_unavailable AFTER UPDATE OF availability ON tracks
                WHEN NEW.availability != 'available' BEGIN
                    UPDATE migration_entries SET localTrackID = NULL, status = 'unavailable', updatedAt = CURRENT_TIMESTAMP
                    WHERE localTrackID = NEW.id AND status = 'ready';
                END;
                """)
            // Navigation uses occurrence IDs only for migration-managed contexts.
            try db.alter(table: "playback_state") { t in
                t.add(column: "migrationContextJSON", .text)
            }
        }
    }
}
