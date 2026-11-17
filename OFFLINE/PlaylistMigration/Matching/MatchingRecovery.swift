import Foundation
import GRDB
import OSLog

enum MatchingFailureCategory: String, Codable, Sendable {
    case metadata, changedRecords, provider, storageBusy, storageFatal, interrupted, cancelled, userPaused, offline
    var message: String {
        switch self {
        case .metadata: return "One source entry could not be processed. Other entries will continue."
        case .changedRecords: return "Stored records changed during matching. The affected entry is available for retry."
        case .provider: return "Search temporarily unavailable. You can retry later."
        case .storageBusy: return "Local storage is busy. The affected entry is available for retry."
        case .storageFatal: return "Matching stopped because local storage could not safely commit results. Existing results are preserved."
        case .interrupted: return "Matching was interrupted. It continues from where it stopped when you return."
        case .cancelled: return "Matching stopped. Your progress is saved."
        case .userPaused: return "Progress saved. Continue whenever you're ready."
        case .offline: return "Waiting for an internet connection. Progress is saved."
        }
    }
    static func classify(_ error: Error) -> Self {
        if error is CancellationError { return .interrupted }
        if let error = error as? DatabaseError {
            return [5, 6].contains(error.resultCode.rawValue) ? .storageBusy : .storageFatal
        }
        if let error = error as? PlaylistMigrationStorageError {
            switch error {
            case .unsafeDiagnostics, .invalidCandidate, .invalidLocalTrack: return .metadata
            case .notFound: return .changedRecords
            default: return .storageFatal
            }
        }
        if error is SongMatchingError { return .changedRecords }
        if error is YouTubeError { return .provider }
        return .storageFatal
    }
}

/// Preserve ordinary song words such as "Secret"; strip credential *syntax* and
/// URLs instead. The legacy diagnostics validator remains unchanged.
enum MatchingSafeText {
    static func metadata(_ value: String) -> String {
        var text = String(value.prefix(1000))
        for pattern in ["(?i)https?://\\S+", "(?i)bearer\\s+\\S+", "(?i)(access[_-]?token|refresh[_-]?token|password|secret|api[_-]?key|oauth)\\s*[:=]\\s*\\S+", "[\\p{Cc}&&[^\\n\\t]]"] {
            text = text.replacingOccurrences(of: pattern, with: "[redacted]", options: .regularExpression)
        }
        return text
    }
}

enum MatchingDiagnostics {
    private static let log = Logger(subsystem: "com.th07.muzikbelesh", category: "PlaylistMatching")
    /// Run-level trace: how many occurrences were claimed vs skipped as already complete.
    static func run(session: UUID, claimed: Int, skippedCompleted: Int, retryFailed: Bool, offline: Bool) {
        log.info("run session=\(session.uuidString, privacy: .public) claimed=\(claimed, privacy: .public) skippedCompleted=\(skippedCompleted, privacy: .public) retryFailed=\(retryFailed, privacy: .public) offline=\(offline, privacy: .public)")
    }
    static func record(_ error: Error, session: UUID, entry: UUID?, stage: String, provider: String = "none") {
        let category = MatchingFailureCategory.classify(error).rawValue
        // Never use DatabaseError.description: it can include SQL arguments.
        let detail: String
        if let db = error as? DatabaseError { detail = "SQLite result=\(db.resultCode.rawValue) extended=\(db.extendedResultCode.rawValue)" }
        else if let typed = error as? PlaylistMigrationStorageError { detail = typed.localizedDescription }
        else if let typed = error as? YouTubeError { detail = typed.rawValue }
        else if let typed = error as? SongMatchingError { detail = String(describing: typed) }
        else { detail = String(reflecting: type(of: error)) }
        log.error("category=\(category, privacy: .public) session=\(session.uuidString, privacy: .public) occurrence=\(entry?.uuidString ?? "none", privacy: .public) stage=\(stage, privacy: .public) provider=\(provider, privacy: .public) underlying=\(detail, privacy: .public)")
    }
}

struct MatchingJobRecord: Codable, FetchableRecord, PersistableRecord, Sendable {
    static let databaseTableName = "migration_matching_jobs"
    var migrationID: String
    /// running/systemPaused resume automatically; userPaused/userCancelled/completed/fatal never do.
    var intent: String
    var updatedAt: Date
}
struct MatchingCheckpoint: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "migration_matching_checkpoints"
    var entryID: String
    var algorithm: String
    var retryable: Bool
    var outcome: String
    var updatedAt: Date
}

extension GRDBPlaylistMigrationRepository {
    func setMatchingIntent(_ id: UUID, intent: String) async throws {
        try await db.write { db in
            guard try MigrationSessionRecord.fetchOne(db, key: id.uuidString) != nil else { throw PlaylistMigrationStorageError.notFound }
            try MatchingJobRecord(migrationID: id.uuidString, intent: intent, updatedAt: Date()).save(db)
        }
    }
    func matchingIntent(_ id: UUID) async throws -> String? {
        try await db.read { db in try MatchingJobRecord.fetchOne(db, key: id.uuidString)?.intent }
    }
    func resumableMatchingJobs() async throws -> [UUID] {
        try await db.read { db in
            try MatchingJobRecord.filter(["running", "systemPaused"].contains(Column("intent"))).order(Column("updatedAt"))
                .fetchAll(db).compactMap { UUID(uuidString: $0.migrationID) }
        }
    }
}
