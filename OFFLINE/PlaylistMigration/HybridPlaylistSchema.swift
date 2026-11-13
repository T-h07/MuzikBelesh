import GRDB

enum HybridPlaylistSchema {
    static func register(in migrator: inout DatabaseMigrator) {
        migrator.registerMigration("v014_matching_recovery_hybrid_playlists") { db in
            try db.execute(sql: """
                CREATE TABLE migration_matching_jobs (
                    migrationID TEXT PRIMARY KEY NOT NULL REFERENCES playlist_migrations(id) ON DELETE CASCADE,
                    intent TEXT NOT NULL CHECK(intent IN ('running','systemPaused','userCancelled','completed','fatal')),
                    updatedAt DATETIME NOT NULL
                );
                CREATE TABLE migration_matching_checkpoints (
                    entryID TEXT PRIMARY KEY NOT NULL REFERENCES migration_entries(id) ON DELETE CASCADE,
                    algorithm TEXT NOT NULL, retryable BOOLEAN NOT NULL,
                    outcome TEXT NOT NULL, updatedAt DATETIME NOT NULL
                );
                CREATE TABLE playlist_local_occurrences (
                    id TEXT PRIMARY KEY NOT NULL,
                    playlistID TEXT NOT NULL REFERENCES playlists(id) ON DELETE CASCADE,
                    trackID TEXT NOT NULL REFERENCES tracks(id) ON DELETE CASCADE,
                    position INTEGER NOT NULL CHECK(position >= 0),
                    createdAt DATETIME NOT NULL,
                    UNIQUE(playlistID, position)
                );
                CREATE INDEX playlist_local_occurrences_track ON playlist_local_occurrences(trackID);
                """)
        }
    }
}
