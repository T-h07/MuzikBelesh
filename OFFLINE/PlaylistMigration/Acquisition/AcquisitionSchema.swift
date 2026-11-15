import GRDB

/// Phase 10.5. Additive only: earlier migrations are never edited.
///
/// `migration_acquisitions` links one source occurrence (and the exact accepted
/// candidate it was linked for) to the single shared `download_jobs` row for that
/// recording. Transfer state, generation, session, bytes, quality, retries and errors
/// remain owned by `download_jobs`; this table only records the association, the
/// verified result and acquisition-level failure classification.
///
/// `migration_acquisition_controls` stores durable per-playlist user intent (Pause)
/// and notification delivery state, so neither is lost or repeated across launches.
enum AcquisitionSchema {
    static func register(in migrator: inout DatabaseMigrator) {
        migrator.registerMigration("v016_playlist_audio_acquisition") { db in
            try db.execute(sql: """
                CREATE TABLE migration_acquisitions (
                    entryID TEXT PRIMARY KEY NOT NULL REFERENCES migration_entries(id) ON DELETE CASCADE,
                    migrationID TEXT NOT NULL REFERENCES playlist_migrations(id) ON DELETE CASCADE,
                    candidateID TEXT NOT NULL,
                    provider TEXT NOT NULL CHECK(provider IN ('youtube')),
                    providerIdentity TEXT NOT NULL CHECK(length(providerIdentity) BETWEEN 1 AND 64),
                    downloadJobID TEXT REFERENCES download_jobs(id) ON DELETE SET NULL,
                    createdJob BOOLEAN NOT NULL DEFAULT 0,
                    state TEXT NOT NULL CHECK(state IN ('waiting','associating','ready','failed','unsupported')),
                    trackID TEXT REFERENCES tracks(id) ON DELETE SET NULL,
                    failure TEXT,
                    retries INTEGER NOT NULL DEFAULT 0 CHECK(retries >= 0),
                    nextRetryAt DATETIME,
                    createdAt DATETIME NOT NULL, updatedAt DATETIME NOT NULL, completedAt DATETIME
                );
                CREATE INDEX migration_acquisitions_job ON migration_acquisitions(downloadJobID);
                CREATE INDEX migration_acquisitions_identity ON migration_acquisitions(provider, providerIdentity);
                CREATE INDEX migration_acquisitions_migration ON migration_acquisitions(migrationID, state);
                CREATE TABLE migration_acquisition_controls (
                    migrationID TEXT PRIMARY KEY NOT NULL REFERENCES playlist_migrations(id) ON DELETE CASCADE,
                    userPaused BOOLEAN NOT NULL DEFAULT 0,
                    readyNotifiedAt DATETIME,
                    partialNotifiedSummary TEXT,
                    updatedAt DATETIME NOT NULL
                );
                """)
        }
        // Durable confirmed-download batches and real delivery outcomes (device hotfix).
        // A batch is the set of links confirmed while the previous batch was unresolved;
        // `resolvedBatch` records which batch's completion was handled and how.
        migrator.registerMigration("v017_acquisition_notification_batches") { db in
            try db.execute(sql: """
                ALTER TABLE migration_acquisitions ADD COLUMN batch INTEGER NOT NULL DEFAULT 0 CHECK(batch >= 0);
                ALTER TABLE migration_acquisition_controls ADD COLUMN currentBatch INTEGER NOT NULL DEFAULT 0 CHECK(currentBatch >= 0);
                ALTER TABLE migration_acquisition_controls ADD COLUMN batchUpdatedAt DATETIME;
                ALTER TABLE migration_acquisition_controls ADD COLUMN resolvedBatch INTEGER;
                ALTER TABLE migration_acquisition_controls ADD COLUMN batchOutcome TEXT CHECK(batchOutcome IN ('delivered','notPermitted'));
                ALTER TABLE migration_acquisition_controls ADD COLUMN readyOutcome TEXT CHECK(readyOutcome IN ('delivered','notPermitted'));
                UPDATE migration_acquisition_controls SET readyOutcome = 'delivered' WHERE readyNotifiedAt IS NOT NULL;
                """)
        }
    }
}
