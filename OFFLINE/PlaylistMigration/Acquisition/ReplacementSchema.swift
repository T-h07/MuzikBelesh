import Foundation
import GRDB

/// Staged recording replacement ("Change Video" for an occurrence that is already ready
/// with verified offline audio). Additive only: earlier migrations are never edited.
///
/// One row per occurrence with a pending replacement. It records exactly what is being
/// replaced (the accepted decision and the verified track in use when the user asked)
/// and what replaces it (a *pending* candidate, never accepted until verified). The
/// occurrence keeps its current audio — and stays playable — until the replacement's
/// audio is downloaded through `DownloadManager`, verified and switched atomically.
/// Transfer state lives in the shared `download_jobs` row, never here.
enum ReplacementSchema {
    static let version = "v020_recording_replacements"

    static func register(in migrator: inout DatabaseMigrator) {
        migrator.registerMigration(version) { db in
            try db.execute(sql: """
                CREATE TABLE migration_replacements (
                    entryID TEXT PRIMARY KEY NOT NULL REFERENCES migration_entries(id) ON DELETE CASCADE,
                    migrationID TEXT NOT NULL REFERENCES playlist_migrations(id) ON DELETE CASCADE,
                    originalCandidateID TEXT,
                    originalTrackID TEXT NOT NULL CHECK(length(originalTrackID) BETWEEN 1 AND 200),
                    candidateID TEXT NOT NULL,
                    videoID TEXT NOT NULL CHECK(length(videoID) BETWEEN 1 AND 64),
                    title TEXT NOT NULL,
                    channel TEXT,
                    durationMs INTEGER CHECK(durationMs IS NULL OR durationMs >= 0),
                    downloadJobID TEXT REFERENCES download_jobs(id) ON DELETE SET NULL,
                    createdJob BOOLEAN NOT NULL DEFAULT 0,
                    state TEXT NOT NULL CHECK(state IN ('waiting','failed')),
                    failure TEXT,
                    retries INTEGER NOT NULL DEFAULT 0 CHECK(retries >= 0),
                    createdAt DATETIME NOT NULL,
                    updatedAt DATETIME NOT NULL
                );
                CREATE INDEX migration_replacements_job ON migration_replacements(downloadJobID);
                CREATE INDEX migration_replacements_migration ON migration_replacements(migrationID);
                """)
        }
    }
}

enum RecordingReplacementState: String, Codable, DatabaseValueConvertible, Sendable {
    /// Linked (or waiting to be linked) to a shared download job that has not finished.
    case waiting
    /// The replacement could not be acquired; the original recording stays in use.
    case failed
}

struct RecordingReplacementRecord: Codable, FetchableRecord, PersistableRecord, Equatable, Sendable {
    static let databaseTableName = "migration_replacements"
    var entryID: String
    var migrationID: String
    /// Accepted decision being replaced (nil for a legacy association without one).
    var originalCandidateID: String?
    /// The verified track in use when the replacement was requested.
    var originalTrackID: String
    /// The staged replacement candidate (decision `pending` until the switch).
    var candidateID: String
    var videoID: String
    var title: String
    var channel: String?
    var durationMs: Int64?
    var downloadJobID: String?
    var createdJob: Bool
    var state: RecordingReplacementState
    var failure: String?
    var retries: Int
    var createdAt: Date
    var updatedAt: Date
}

/// Result of the guarded switch.
enum RecordingReplacementOutcome: Equatable, Sendable {
    /// The occurrence now uses the verified replacement.
    case replaced
    /// The request or the occurrence changed (cancelled, re-staged, original audio gone):
    /// nothing was switched.
    case stale
    /// The downloaded audio is missing or failed verification: nothing was switched.
    case invalidAudio
}
