import Foundation
import GRDB
import OSLog

/// Migration-level lifecycle owned by `PlaylistMigrationCoordinator`. Separate from
/// `PlaylistMigrationStatus` (the Phase 10.1 session lifecycle) so no existing enum,
/// transition table or CHECK constraint changes meaning.
enum MigrationLifecycleState: String, Codable, CaseIterable, Sendable {
    /// Imported, never scheduled.
    case pending
    /// Matching work is executing, or is queued for the single matching worker.
    case matching
    case awaitingReview
    /// Confirmed recordings are downloading, verifying or being associated.
    case acquiring
    case waitingForNetwork
    case coolingDown
    /// The app has no iOS execution opportunity right now.
    case systemSuspended
    case resourceDeferred
    case userPaused
    case cancelling
    case cancelled
    case completed
    case completedWithIssues
    case failed

    /// Restored without user action once the blocking condition clears.
    var recoversAutomatically: Bool {
        [.matching, .acquiring, .waitingForNetwork, .coolingDown, .systemSuspended, .resourceDeferred].contains(self)
    }
    var isTerminal: Bool { [.cancelled, .completed].contains(self) }

    /// Plain, specific status text (no internals).
    var message: String {
        switch self {
        case .pending: "Not started"
        case .matching: "Finding recordings"
        case .awaitingReview: "Waiting for your review"
        case .acquiring: "Downloading confirmed songs"
        case .waitingForNetwork: "Waiting for connection"
        case .coolingDown: "Search temporarily limited"
        case .systemSuspended: "Waiting for iOS execution opportunity"
        case .resourceDeferred: "Paused to protect the device"
        case .userPaused: "Paused by you"
        case .cancelling: "Cancelling"
        case .cancelled: "Migration cancelled"
        case .completed: "Ready offline"
        case .completedWithIssues: "Needs attention"
        case .failed: "Stopped. Your progress is saved."
        }
    }
}

/// Unified failure classification (diagnostics, retry policy, presentation). It maps
/// onto, and never overrides, the matching and acquisition engines' own categories.
enum MigrationFailureCategory: String, Codable, CaseIterable, Sendable {
    case networkUnavailable, timeout, rateLimited, providerTemporary, providerRestricted
    case unsupportedRecording, invalidMetadata, missingRecording, verificationFailed
    case storage, userCancelled, backgroundExpired, resourceDeferred, explicitRetry

    /// Eligible for bounded automatic retry.
    var retryable: Bool {
        [.networkUnavailable, .timeout, .rateLimited, .providerTemporary, .storage, .backgroundExpired, .resourceDeferred, .explicitRetry].contains(self)
    }

    /// Checkpoint outcomes written by the matching engine (`commitMatching`,
    /// `recordMatchingFailure`). Unknown or successful outcomes return nil.
    static func matching(outcome: String) -> Self? {
        switch outcome {
        case "discoveryFailed": return .providerTemporary
        case "provider": return .providerTemporary
        case "storageBusy", "changedRecords": return .storage
        case "interrupted": return .backgroundExpired
        case "offline": return .networkUnavailable
        case "metadata": return .invalidMetadata
        case "noMatch": return .missingRecording
        default: return nil
        }
    }

    static func youtube(_ error: YouTubeError?) -> Self? {
        guard let error else { return nil }
        switch error {
        case .networkUnavailable: return .networkUnavailable
        case .requestTimeout: return .timeout
        case .rateLimited: return .rateLimited
        case .providerRestricted, .accessRestricted, .redirectUnavailable: return .providerRestricted
        case .searchUnavailable, .sourceUnavailable, .metadataUnavailable, .streamNotReady, .streamExpired, .extractionFailed: return .providerTemporary
        case .noAudioStreams, .noCompatibleAudio, .videoUnavailable, .regionRestricted: return .unsupportedRecording
        case .invalidURL, .invalidVideoID: return .invalidMetadata
        case .cancelled: return .userCancelled
        }
    }
}

/// Bounded exponential backoff. The initial attempt does NOT count: after failure N
/// (1-based) the N-th automatic retry is scheduled, up to `maximumAutomaticRetries`.
/// After that the occurrence needs an explicit Retry (or review).
struct MigrationRetryPolicy: Sendable {
    var delays: [TimeInterval] = [15, 60, 180]
    var maximumDelay: TimeInterval = 600
    var maximumAutomaticRetries = 3
    /// ± fraction of the delay, bounded, to avoid synchronized retry storms.
    var jitter: Double = 0.1
    var random: @Sendable () -> Double = { Double.random(in: 0...1) }

    static let standard = MigrationRetryPolicy()
    static let deterministic = MigrationRetryPolicy(jitter: 0)

    /// Delay before the retry that follows failure number `failures`; nil when exhausted.
    func delay(afterFailure failures: Int) -> TimeInterval? {
        guard failures >= 1, failures <= maximumAutomaticRetries else { return nil }
        let base = min(maximumDelay, delays.isEmpty ? maximumDelay : delays[min(failures, delays.count) - 1])
        guard jitter > 0 else { return base }
        let factor = 1 + (min(1, max(0, random())) * 2 - 1) * min(0.5, jitter)
        return min(maximumDelay, max(1, base * factor))
    }
}

/// Provider-wide restriction deadline, shared across migrations and launches.
struct PersistedProviderCooldown: Codable, FetchableRecord, PersistableRecord, Equatable, Sendable {
    static let databaseTableName = "migration_provider_cooldowns"
    var provider: String
    var expiresAt: Date
    var probes: Int
    var reason: String?
    var updatedAt: Date
}

protocol ProviderCooldownPersisting: Sendable {
    func providerCooldowns() async throws -> [String: PersistedProviderCooldown]
    func saveProviderCooldown(_ value: PersistedProviderCooldown) async throws
    func clearProviderCooldown(_ provider: String) async throws
}

struct CoordinatorStateRecord: Codable, FetchableRecord, PersistableRecord, Equatable, Sendable {
    static let databaseTableName = "migration_coordinator_state"
    var migrationID: String
    var state: MigrationLifecycleState
    /// Lease token of the current execution. A callback carrying another value is stale.
    var generation: String?
    /// Last source position covered by the current matching pass (-1: pass not started).
    var cursorPosition: Int
    var lastScheduledAt: Date?
    var heartbeatAt: Date?
    var lastCheckpointAt: Date?
    var lastRecoveryAt: Date?
    var waitUntil: Date?
    var interruptedBySystem: Bool
    var reason: String?
    var errorCategory: String?
    var createdAt: Date
    var updatedAt: Date

    static func initial(_ migrationID: String, now: Date) -> Self {
        .init(migrationID: migrationID, state: .pending, generation: nil, cursorPosition: -1, lastScheduledAt: nil, heartbeatAt: nil,
              lastCheckpointAt: nil, lastRecoveryAt: nil, waitUntil: nil, interruptedBySystem: false, reason: nil, errorCategory: nil,
              createdAt: now, updatedAt: now)
    }
}

struct EntryRetryRecord: Codable, FetchableRecord, PersistableRecord, Equatable, Sendable {
    static let databaseTableName = "migration_entry_retries"
    var entryID: String
    var migrationID: String
    /// Failed attempts since the last success or explicit retry.
    var failures: Int
    var category: String
    var eligible: Bool
    var lastAttemptAt: Date?
    var nextRetryAt: Date?
    var updatedAt: Date
}

/// One unit of matching work handed to the single matching worker.
struct MatchingWorkItem: Equatable, Sendable {
    enum Kind: String, Sendable { case ordinary, retry }
    let migrationID: UUID
    let only: Set<UUID>?
    let retryFailed: Bool
    let generation: UUID
    let kind: Kind
    /// Highest source position in an ordinary slice (the pass cursor after it commits).
    let sliceEnd: Int?
    /// Durable matching intent before this unit started (retries never promote it).
    let previousIntent: String?
}

/// The matching worker's link to the coordinator. Only the coordinator decides what
/// runs next; the view model executes it under one iOS execution grant.
@MainActor protocol MatchingScheduling: AnyObject {
    /// Next eligible unit of work, or nil when nothing may run now.
    func nextMatchingWork() async -> MatchingWorkItem?
    /// Durable intent for a migration whose run just returned normally.
    func intentAfterRun(_ migrationID: UUID, item: MatchingWorkItem?, report: SongMatchingProgress, startedAt: Date) async -> String
    /// The worker became idle (finished, paused, cancelled, interrupted or failed).
    func matchingWorkerDidStop(_ migrationID: UUID?, reason: MatchingFailureCategory?)
}

/// Derived from authoritative rows; never persisted as counters.
struct MigrationCoordinatorProgress: Equatable, Sendable {
    var total = 0
    /// Occurrences whose matching attempt finished (any outcome).
    var matchingCompleted = 0
    /// Occurrences the matching worker may still claim.
    var matchingRemaining = 0
    var awaitingReview = 0
    /// Explicitly confirmed YouTube selections that are not yet linked for download.
    var confirmed = 0
    var queuedDownloads = 0
    var downloading = 0
    var verifying = 0
    var availableOffline = 0
    var failedOrUnsupported = 0
    var dueRetries = 0
    var matchingFraction: Double { total == 0 ? 0 : Double(matchingCompleted) / Double(total) }
    var offlineFraction: Double { total == 0 ? 0 : Double(availableOffline) / Double(total) }
}

struct MigrationCoordinatorStatus: Equatable, Sendable {
    var state: MigrationLifecycleState
    var progress: MigrationCoordinatorProgress
    var waitUntil: Date?
    var isActive: Bool
    var message: String
}

/// One consistent aggregate read per migration for scheduling and presentation.
struct MigrationOverview: Equatable, Sendable {
    var migrationID: UUID
    var sessionStatus: PlaylistMigrationStatus
    var createdAt: Date
    var intent: String?
    var state: CoordinatorStateRecord?
    var total = 0
    var ready = 0
    var unmatched = 0
    var eligible = 0
    var review = 0
    var confirmed = 0
    var issues = 0
    var downloadsPaused = false
    var acquiringOpen = 0
    var acquisitionIssues = 0
    var linkWaitingQueued = 0
    var linkDownloading = 0
    var linkVerifying = 0
    var links = 0
    var dueRetries = 0
    /// Due retries the user requested explicitly (allowed even while matching is paused).
    var explicitDue = 0
    var nextRetryAt: Date?

    /// Sessions the matching engine accepts (`beginMatching`).
    var schedulable: Bool {
        [.metadataReady, .matching, .awaitingReview, .partiallyCompleted, .paused, .failed].contains(sessionStatus)
    }
    var cancelled: Bool { sessionStatus == .cancelled || intent == "userCancelled" }
}

/// Structured, privacy-safe diagnostics (identifiers, counts, states, categories only).
enum CoordinatorDiagnostics {
    static let log = Logger(subsystem: "com.th07.muzikbelesh", category: "PlaylistMigrationCoordinator")
    static func event(_ name: String, migration: UUID? = nil, _ details: [String: String] = [:]) {
        let fields = details.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: " ")
        log.info("event=\(name, privacy: .public) migration=\(migration?.uuidString ?? "none", privacy: .public) \(fields, privacy: .public)")
    }
    static func conflict(_ name: String, migration: UUID?, _ details: [String: String] = [:]) {
        let fields = details.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: " ")
        log.notice("recoveryConflict=\(name, privacy: .public) migration=\(migration?.uuidString ?? "none", privacy: .public) \(fields, privacy: .public)")
    }
    static func failure(_ error: Error, stage: String, migration: UUID?) {
        let detail: String
        if let db = error as? DatabaseError { detail = "SQLite result=\(db.resultCode.rawValue)" }
        else if let typed = error as? PlaylistMigrationStorageError { detail = String(describing: typed) }
        else if let typed = error as? PlaylistMigrationFoundationError { detail = String(describing: typed) }
        else { detail = String(reflecting: type(of: error)) }
        log.error("stage=\(stage, privacy: .public) migration=\(migration?.uuidString ?? "none", privacy: .public) underlying=\(detail, privacy: .public)")
    }
}
