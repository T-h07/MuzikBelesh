import Foundation

// Phase 10.7 — Migration issue reporting.
//
// An issue is a persistent, classified state of one exact source occurrence. Everything
// here is derived from authoritative rows (occurrences, candidates, checkpoints, retry
// bookkeeping, acquisition links and shared download jobs); presentation never invents
// or clears an issue on its own.

/// What went wrong, as precisely as the persisted evidence allows. A category is chosen
/// only from structured state (typed error raw values, checkpoint outcomes, link and job
/// states); when the cause is not known, `unknown` is used instead of a guess.
enum MigrationIssueCategory: String, Codable, CaseIterable, Sendable {
    // Matching
    case noReliableMatch
    case ambiguousMatches
    /// One plausible recording exists but needs confirmation (never "incorrect").
    case needsConfirmation
    case allSuggestionsRejected
    case notSearched
    case temporaryProviderFailure
    case networkUnavailable
    case rateLimited
    case interruptedMatching
    case storageBusy
    case unsupportedMetadata
    // Acquisition
    case sourceUnavailable
    case regionRestricted
    case providerAccessRestricted
    case networkTimeout
    case expiredStream
    case interruptedDownload
    case insufficientStorage
    case storageWriteFailed
    case audioValidationFailed
    case unsupportedFormat
    case downloadTooLarge
    case downloadCancelled
    case importFailure
    // Association / lifecycle
    case missingLocalAudio
    case migrationCancelled
    case unknown

    /// Short, plain title for filters, badges and VoiceOver.
    var title: String {
        switch self {
        case .noReliableMatch: "No reliable match"
        case .ambiguousMatches: "Several possible recordings"
        case .needsConfirmation: "Needs your confirmation"
        case .allSuggestionsRejected: "All suggestions rejected"
        case .notSearched: "Not searched yet"
        case .temporaryProviderFailure: "Search temporarily unavailable"
        case .networkUnavailable: "No connection"
        case .rateLimited: "Search temporarily limited"
        case .interruptedMatching: "Matching interrupted"
        case .storageBusy: "Storage busy"
        case .unsupportedMetadata: "Song information not supported"
        case .sourceUnavailable: "Recording unavailable"
        case .regionRestricted: "Unavailable in your region"
        case .providerAccessRestricted: "Access restricted"
        case .networkTimeout: "Connection timed out"
        case .expiredStream: "Download link expired"
        case .interruptedDownload: "Download interrupted"
        case .insufficientStorage: "Not enough storage"
        case .storageWriteFailed: "Couldn't save the audio"
        case .audioValidationFailed: "Audio couldn't be verified"
        case .unsupportedFormat: "Unsupported audio format"
        case .downloadTooLarge: "Audio too large"
        case .downloadCancelled: "Download cancelled"
        case .importFailure: "Couldn't add to library"
        case .missingLocalAudio: "Audio file missing"
        case .migrationCancelled: "Migration cancelled"
        case .unknown: "Something went wrong"
        }
    }

    /// Human-readable, technically accurate explanation (no error codes or internals).
    var explanation: String {
        switch self {
        case .noReliableMatch: "We couldn't find a reliable recording for this song."
        case .ambiguousMatches: "Several recordings look similar. Choose the correct version."
        case .needsConfirmation: "A possible recording was found. Confirm it's the right version before it downloads."
        case .allSuggestionsRejected: "You rejected every suggested recording. Search again, choose a video yourself or use a local file."
        case .notSearched: "This song hasn't been searched yet."
        case .temporaryProviderFailure: "The search service was temporarily unavailable while looking for this song."
        case .networkUnavailable: "There was no internet connection while searching for this song."
        case .rateLimited: "The search service is temporarily limiting requests. Searching continues automatically."
        case .interruptedMatching: "Matching for this song was interrupted before its results were saved."
        case .storageBusy: "The device's storage was busy while saving this song's results."
        case .unsupportedMetadata: "This song's source information could not be processed."
        case .sourceUnavailable: "This recording is no longer available from the selected source."
        case .regionRestricted: "This recording is unavailable in your region."
        case .providerAccessRestricted: "This recording requires access or verification the app can't provide."
        case .networkTimeout: "The connection timed out while downloading."
        case .expiredStream: "The temporary audio link expired or was rejected. Retry the download to request a new link."
        case .interruptedDownload: "The download was interrupted before it finished."
        case .insufficientStorage: "There isn't enough available storage to save this recording."
        case .storageWriteFailed: "The audio file couldn't be saved on this device. Check available storage, then retry."
        case .audioValidationFailed: "This recording could not be verified. Try downloading it again or use a local audio file."
        case .unsupportedFormat: "This recording does not have a supported audio format."
        case .downloadTooLarge: "This recording exceeds the download size limit."
        case .downloadCancelled: "The download was cancelled before it finished."
        case .importFailure: "The downloaded audio couldn't be added to your library."
        case .missingLocalAudio: "The audio file previously linked to this song is missing."
        case .migrationCancelled: "This song wasn't processed because the migration was cancelled."
        case .unknown: "This song couldn't be processed. The exact cause wasn't recorded."
        }
    }
}

/// Identity of an issue record per occurrence: a matching issue and an acquisition
/// issue are separate, so confirming a recording resolves the first without hiding a
/// later download failure.
enum MigrationIssueStage: String, Codable, CaseIterable, Sendable {
    case matching, acquisition, association

    /// Stable `migration_issues.code` for Phase 10.7 records. Legacy codes (for example
    /// the matching engine's `matching-attempt`) are left to their owners.
    var code: String { "report." + rawValue }
    init?(code: String) {
        guard code.hasPrefix("report.") else { return nil }
        self.init(rawValue: String(code.dropFirst("report.".count)))
    }
}

/// Where the error originated. Drives wording and which subsystem owns recovery.
enum MigrationIssueProvenance: String, Codable, CaseIterable, Sendable {
    case metadataImport, localMatching, externalDiscovery, userCandidateSelection
    case downloadResolution, networkTransfer, audioValidation, storageImport, playlistAssociation, migrationLifecycle
}

enum MigrationIssueSeverityLevel: Sendable {
    case blocking, waiting
}

/// Recovery actions. Only actions valid for the occurrence's actual state are offered.
enum MigrationIssueAction: String, Codable, CaseIterable, Sendable, Identifiable {
    case reviewCandidates
    case retrySong
    case retryDownload
    case chooseOtherRecording
    case attachLocalRecording
    case importLocalFile
    case skip
    case restore
    /// Re-download the confirmed recording after its local audio was deleted.
    case downloadAgain
    var id: String { rawValue }

    var title: String {
        switch self {
        case .reviewCandidates: "Review Candidates"
        case .retrySong: "Search Again"
        case .retryDownload: "Retry Download"
        case .chooseOtherRecording: "Choose Other Recording"
        case .attachLocalRecording: "Use Song From Library"
        case .importLocalFile: "Import Local Audio"
        case .skip: "Skip Song"
        case .restore: "Restore Song"
        case .downloadAgain: "Download Again"
        }
    }
}

/// Where one source occurrence stands. `playable + unresolved + skipped == total`.
enum MigrationOccurrenceDisposition: String, Codable, Sendable {
    /// Present, verified local audio is associated.
    case playable
    /// The user explicitly skipped this occurrence.
    case skipped
    /// Work remains and will continue automatically (queued, downloading, retry scheduled,
    /// cooling down, waiting for network) or is paused by the user. Not a failure.
    case waiting
    /// Candidates exist and the user's decision is required.
    case needsReview
    /// Processing for this occurrence settled without usable audio; user action required.
    case failed

    var isUnresolved: Bool { self == .waiting || self == .needsReview || self == .failed }
    /// Counted as an issue that needs the user (not a temporary waiting condition).
    var needsAttention: Bool { self == .needsReview || self == .failed }
}

/// Filters on the Migration Issues screen.
enum MigrationIssueFilter: String, CaseIterable, Identifiable, Sendable {
    case all, needsReview, failed, waiting, skipped, resolved
    var id: String { rawValue }
    var title: String {
        switch self {
        case .all: "All Issues"
        case .needsReview: "Needs Review"
        case .failed: "Failed"
        case .waiting: "Waiting"
        case .skipped: "Skipped"
        case .resolved: "Resolved"
        }
    }
}

/// Classification of one occurrence (pure output of `MigrationIssueClassifier`).
struct MigrationOccurrenceAssessment: Equatable, Sendable {
    var disposition: MigrationOccurrenceDisposition
    /// Nil for playable and skipped occurrences.
    var category: MigrationIssueCategory?
    var stage: MigrationIssueStage?
    var provenance: MigrationIssueProvenance?
    /// One-line current status ("Retrying automatically", "Downloading", …).
    var status: String
    var explanation: String?
    /// The underlying operation may be retried (automatically or by the user).
    var retryable: Bool = false
    /// Recovery happens without user action (scheduled retry, queued work, cooldown).
    var automaticRecovery: Bool = false
    var requiresReview: Bool = false
    var actions: [MigrationIssueAction] = []
    var retryCount: Int = 0
    var nextRetryAt: Date? = nil
    var lastAttemptAt: Date? = nil

    static let playable = MigrationOccurrenceAssessment(disposition: .playable, status: "Available offline")
    static let skipped = MigrationOccurrenceAssessment(disposition: .skipped, status: "Skipped", actions: [.restore])
}

/// One row of the Migration Issues report (immutable source metadata is read from the
/// occurrence, never duplicated in issue persistence).
struct MigrationOccurrenceReport: Identifiable, Equatable, Sendable {
    let entry: PlaylistMigrationEntry
    let assessment: MigrationOccurrenceAssessment
    let pendingCandidates: Int
    /// Open persisted issue for the current stage, when one exists.
    let issueID: UUID?
    let issueCreatedAt: Date?
    /// Closed issue records kept as history for this occurrence.
    let resolvedIssues: Int
    var id: UUID { entry.id }
    var position: Int { entry.position }

    func matches(_ filter: MigrationIssueFilter) -> Bool {
        switch filter {
        case .all: assessment.disposition.isUnresolved || assessment.disposition == .skipped
        case .needsReview: assessment.disposition == .needsReview
        case .failed: assessment.disposition == .failed
        case .waiting: assessment.disposition == .waiting
        case .skipped: assessment.disposition == .skipped
        case .resolved: assessment.disposition == .playable && resolvedIssues > 0
        }
    }
}

/// Persisted Phase 10.7 issue row (subset of `migration_issues` plus v019 columns).
struct MigrationIssueRow: Equatable, Sendable {
    let id: UUID
    let migrationID: UUID
    let entryID: UUID
    let stage: MigrationIssueStage
    let category: String?
    let provenance: String?
    let message: String
    let resolution: PlaylistMigrationIssueResolution
    let closeReason: String?
    let recoverable: Bool?
    let createdAt: Date
    let updatedAt: Date
    let resolvedAt: Date?
    let lastObservedAt: Date?
}

/// Why a Phase 10.7 issue record was closed. History is never deleted.
enum MigrationIssueCloseReason: String, Codable, Sendable {
    /// The underlying condition was corrected (audio verified, recording confirmed…).
    case conditionCleared
    /// A different category replaced it for the same occurrence and stage.
    case superseded
    /// The user skipped the occurrence.
    case skipped
    /// The occurrence is back in automatic processing (for example after a retry).
    case recovering
    /// An explicit user action ended it (for example removing the song from its playlist).
    case userAction
}
