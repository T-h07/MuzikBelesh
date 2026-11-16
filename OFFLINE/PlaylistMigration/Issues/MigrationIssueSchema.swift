import GRDB

/// Phase 10.7. Additive only: earlier migrations are never edited and `migration_issues`
/// is not rebuilt. Existing issue rows (including resolved and dismissed history) keep
/// their values; the new columns are NULL for them.
///
/// * `migration_issues` gains structured classification (category, stage, provenance,
///   recoverable), `lastObservedAt` and `closeReason`. Phase 10.7 records use the codes
///   `report.matching`, `report.acquisition` and `report.association`; a partial unique
///   index guarantees at most one *open* record per occurrence and stage, so repeated
///   reconciliation can never accumulate duplicates. Legacy codes are unaffected.
/// * `migration_report_state` — one row per migration: the processing-cycle counter,
///   whether the last observation was settled, and which cycle's completion summary
///   the user already dismissed in the app.
/// * `migration_report_events` — the durable notification ledger: one aggregate event
///   per migration and processing cycle, with its delivery outcome and bounded attempts.
///
/// Attempt counts and retry deadlines are not duplicated: they stay in
/// `migration_entry_retries`, `migration_acquisitions` and `download_jobs`.
enum MigrationIssueSchema {
    static let version = "v019_migration_issue_reporting"
    static let reportCodes = "'report.matching','report.acquisition','report.association'"

    static func register(in migrator: inout DatabaseMigrator) {
        migrator.registerMigration(version) { db in
            try db.execute(sql: """
                ALTER TABLE migration_issues ADD COLUMN category TEXT CHECK(category IS NULL OR length(category) BETWEEN 1 AND 60);
                ALTER TABLE migration_issues ADD COLUMN stage TEXT CHECK(stage IS NULL OR stage IN ('matching','acquisition','association'));
                ALTER TABLE migration_issues ADD COLUMN provenance TEXT CHECK(provenance IS NULL OR length(provenance) BETWEEN 1 AND 60);
                ALTER TABLE migration_issues ADD COLUMN recoverable BOOLEAN;
                ALTER TABLE migration_issues ADD COLUMN lastObservedAt DATETIME;
                ALTER TABLE migration_issues ADD COLUMN closeReason TEXT CHECK(closeReason IS NULL OR closeReason IN ('conditionCleared','superseded','skipped','recovering','userAction'));
                CREATE UNIQUE INDEX migration_issues_open_report ON migration_issues(entryID, code)
                    WHERE resolution = 'open' AND code IN (\(reportCodes));
                CREATE INDEX migration_issues_code ON migration_issues(migrationID, code, resolution);
                CREATE TABLE migration_report_state (
                    migrationID TEXT PRIMARY KEY NOT NULL REFERENCES playlist_migrations(id) ON DELETE CASCADE,
                    cycle INTEGER NOT NULL DEFAULT 0 CHECK(cycle >= 0),
                    settled BOOLEAN NOT NULL DEFAULT 0,
                    outcome TEXT CHECK(outcome IS NULL OR length(outcome) BETWEEN 1 AND 40),
                    revision TEXT CHECK(revision IS NULL OR length(revision) <= 200),
                    observedBatch INTEGER,
                    settledAt DATETIME,
                    presentedCycle INTEGER NOT NULL DEFAULT 0 CHECK(presentedCycle >= 0),
                    createdAt DATETIME NOT NULL,
                    updatedAt DATETIME NOT NULL
                );
                CREATE TABLE migration_report_events (
                    migrationID TEXT NOT NULL REFERENCES playlist_migrations(id) ON DELETE CASCADE,
                    cycle INTEGER NOT NULL CHECK(cycle >= 1),
                    kind TEXT NOT NULL CHECK(kind IN ('fullyReady','needsAttention')),
                    revision TEXT NOT NULL CHECK(length(revision) <= 200),
                    batchAtSettle INTEGER,
                    delivery TEXT CHECK(delivery IS NULL OR delivery IN ('delivered','notPermitted','coalesced','superseded','abandoned')),
                    attempts INTEGER NOT NULL DEFAULT 0 CHECK(attempts >= 0),
                    lastAttemptAt DATETIME,
                    deliveredAt DATETIME,
                    createdAt DATETIME NOT NULL,
                    updatedAt DATETIME NOT NULL,
                    PRIMARY KEY(migrationID, cycle)
                );
                CREATE INDEX migration_report_events_pending ON migration_report_events(delivery, migrationID);
                """)
        }
    }
}
