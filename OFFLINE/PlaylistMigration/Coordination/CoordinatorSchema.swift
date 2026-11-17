import GRDB

/// Phase 10.6. Additive only: earlier migrations are never edited.
///
/// Reused, not duplicated:
/// * `migration_matching_jobs.intent` remains the durable user/system execution intent
///   (running, systemPaused, userPaused, userCancelled, completed, fatal).
/// * `migration_entries`, `migration_candidates`, `migration_matching_checkpoints`,
///   `migration_acquisitions`, `migration_acquisition_controls` and `download_jobs`
///   remain authoritative for stages, decisions, links, transfers and verified audio.
///
/// New:
/// * `migration_coordinator_state` — one row per migration: lifecycle state, execution
///   generation (lease token), pass cursor, fairness timestamp, wake-up deadline and
///   recovery metadata. Progress counters are never stored; they are derived.
/// * `migration_entry_retries` — bounded automatic retry bookkeeping per occurrence.
/// * `migration_provider_cooldowns` — provider-wide restriction deadlines shared by every
///   migration and preserved across launches.
enum CoordinatorSchema {
    static let version = "v018_persistent_migration_coordinator"
    /// Frozen literal list: a historical migration must never change with later code.
    static let states = "'pending','matching','awaitingReview','acquiring','waitingForNetwork','coolingDown','systemSuspended',"
        + "'resourceDeferred','userPaused','cancelling','cancelled','completed','completedWithIssues','failed'"

    static func register(in migrator: inout DatabaseMigrator) {
        migrator.registerMigration(version) { db in
            try db.execute(sql: """
                CREATE TABLE migration_coordinator_state (
                    migrationID TEXT PRIMARY KEY NOT NULL REFERENCES playlist_migrations(id) ON DELETE CASCADE,
                    state TEXT NOT NULL CHECK(state IN (\(states))),
                    generation TEXT,
                    cursorPosition INTEGER NOT NULL DEFAULT -1 CHECK(cursorPosition >= -1),
                    lastScheduledAt DATETIME,
                    heartbeatAt DATETIME,
                    lastCheckpointAt DATETIME,
                    lastRecoveryAt DATETIME,
                    waitUntil DATETIME,
                    interruptedBySystem BOOLEAN NOT NULL DEFAULT 0,
                    reason TEXT CHECK(reason IS NULL OR length(reason) <= 200),
                    errorCategory TEXT CHECK(errorCategory IS NULL OR length(errorCategory) <= 60),
                    createdAt DATETIME NOT NULL,
                    updatedAt DATETIME NOT NULL
                );
                CREATE INDEX migration_coordinator_state_schedule ON migration_coordinator_state(state, lastScheduledAt);
                CREATE TABLE migration_entry_retries (
                    entryID TEXT PRIMARY KEY NOT NULL REFERENCES migration_entries(id) ON DELETE CASCADE,
                    migrationID TEXT NOT NULL REFERENCES playlist_migrations(id) ON DELETE CASCADE,
                    failures INTEGER NOT NULL DEFAULT 0 CHECK(failures >= 0),
                    category TEXT NOT NULL CHECK(length(category) BETWEEN 1 AND 60),
                    eligible BOOLEAN NOT NULL,
                    lastAttemptAt DATETIME,
                    nextRetryAt DATETIME,
                    updatedAt DATETIME NOT NULL
                );
                CREATE INDEX migration_entry_retries_due ON migration_entry_retries(migrationID, eligible, nextRetryAt);
                CREATE TABLE migration_provider_cooldowns (
                    provider TEXT PRIMARY KEY NOT NULL CHECK(length(provider) BETWEEN 1 AND 60),
                    expiresAt DATETIME NOT NULL,
                    probes INTEGER NOT NULL DEFAULT 0 CHECK(probes >= 0),
                    reason TEXT CHECK(reason IS NULL OR length(reason) <= 300),
                    updatedAt DATETIME NOT NULL
                );
                CREATE INDEX migration_matching_checkpoints_outcome ON migration_matching_checkpoints(outcome, retryable);
                """)
        }
    }
}
