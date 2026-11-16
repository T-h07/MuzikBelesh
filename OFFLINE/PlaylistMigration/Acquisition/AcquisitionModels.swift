import Foundation
import GRDB

/// Durable acquisition-link state. Transfer sub-states (queued, waiting for Wi-Fi,
/// downloading, verifying…) are never duplicated here: they are read from the shared
/// `download_jobs` row the link points to.
enum AcquisitionLinkState: String, Codable, DatabaseValueConvertible, Sendable {
    /// Linked (or waiting to be linked) to a shared download job that has not finished.
    case waiting
    /// The shared job produced a verified track; the occurrence association is pending.
    case associating
    /// The occurrence is associated with verified local audio.
    case ready
    /// Acquisition failed. Retryable failures keep retry state; the decision is preserved.
    case failed
    /// The confirmed source cannot be acquired automatically. Local-file import remains.
    case unsupported
}

struct AcquisitionLinkRecord: Codable, FetchableRecord, PersistableRecord, Equatable, Sendable {
    static let databaseTableName = "migration_acquisitions"
    var entryID: String
    var migrationID: String
    var candidateID: String
    var provider: String
    var providerIdentity: String
    var downloadJobID: String?
    var createdJob: Bool
    var state: AcquisitionLinkState
    var trackID: String?
    var failure: String?
    var retries: Int
    var nextRetryAt: Date?
    var createdAt: Date
    var updatedAt: Date
    var completedAt: Date?
    /// Confirmed-download batch this occurrence belongs to (v017).
    var batch: Int = 0

    /// Equality ignoring the modification stamp, so unchanged links are not rewritten.
    func sameContent(as other: AcquisitionLinkRecord) -> Bool {
        var copy = self; copy.updatedAt = other.updatedAt
        return copy == other
    }
}

struct AcquisitionControlRecord: Codable, FetchableRecord, PersistableRecord, Equatable, Sendable {
    static let databaseTableName = "migration_acquisition_controls"
    var migrationID: String
    var userPaused: Bool
    /// Set only after a "Playlist Ready Offline" notification was actually scheduled.
    var readyNotifiedAt: Date?
    /// Superseded by confirmed-download batches; retained for schema compatibility.
    var partialNotifiedSummary: String?
    var updatedAt: Date
    var currentBatch: Int = 0
    /// Last time a link joined `currentBatch`; completion waits for a quiet period after it.
    var batchUpdatedAt: Date? = nil
    var resolvedBatch: Int? = nil
    var batchOutcome: AcquisitionNotificationDelivery? = nil
    var readyOutcome: AcquisitionNotificationDelivery? = nil
}

/// What happened to one notification. `.failed` is transient (scheduling error or
/// permission not yet decided) and is never persisted as handled.
enum AcquisitionNotificationDelivery: String, Codable, DatabaseValueConvertible, Sendable {
    case delivered, notPermitted, failed
}

/// An occurrence whose user-confirmed YouTube recording should be acquired.
/// Only explicit `accepted` decisions on `matched` occurrences qualify; pending
/// recommendations are never acquired automatically.
struct AcquisitionDemand: Equatable, Sendable {
    let entryID: String
    let migrationID: String
    let candidateID: String
    let videoID: String
    let title: String
    let channel: String?
    let durationMs: Int64?
    let thumbnail: URL?
    let position: Int
}

struct AcquisitionPlan: Equatable, Sendable {
    var demands: [AcquisitionDemand] = []
    var links: [AcquisitionLinkRecord] = []
    var controls: [String: AcquisitionControlRecord] = [:]
    /// migrationID → destination playlist identity and source name.
    var playlists: [String: AcquisitionPlaylist] = [:]
    /// entryID → current entry status/local track, for stale-link detection.
    var entries: [String: AcquisitionEntrySnapshot] = [:]
    /// Staged replacements of already verified recordings ("Change Video").
    var replacements: [RecordingReplacementRecord] = []
}

struct AcquisitionPlaylist: Equatable, Sendable {
    let migrationID: String
    let playlistID: String
    let name: String
    let cancelled: Bool
}

struct AcquisitionEntrySnapshot: Equatable, Sendable {
    let status: PlaylistMigrationEntryStatus
    let localTrackID: String?
    let acceptedCandidateID: String?
}

/// Result of a stale-guarded association attempt.
enum AcquisitionAssociation: Equatable, Sendable {
    case associated
    /// The occurrence's decision changed while downloading; the old result must not attach.
    case stale
    /// The referenced local audio is missing or failed verification.
    case invalidAudio
}

/// Failure categories surfaced to the user. Classification uses the shared job's
/// persisted error text, which DownloadManager writes from `DownloadFailure` raw values
/// or `YouTubeError` descriptions.
enum AcquisitionFailureCategory: String, Sendable, CaseIterable {
    case network, waitingForWiFi, remoteRejected, streamExpired, unsupportedFormat, verificationFailed
    case insufficientStorage, sourceUnavailable, accessRestricted, userCancelled, importFailed, tooLarge, unknown

    var retryable: Bool {
        switch self {
        case .network, .waitingForWiFi, .remoteRejected, .streamExpired, .insufficientStorage, .importFailed, .unknown, .userCancelled: true
        case .verificationFailed: true // One retry: a truncated transfer can fail verification.
        case .unsupportedFormat, .sourceUnavailable, .accessRestricted, .tooLarge: false
        }
    }
    /// Automatic retries before the user must act. Permanent categories never retry.
    var automaticRetries: Int {
        switch self {
        case .verificationFailed: 1
        case .userCancelled: 0
        default: retryable ? 3 : 0
        }
    }
    var message: String {
        switch self {
        case .network: "The connection was interrupted. It will retry when the network returns."
        case .waitingForWiFi: "Waiting for Wi-Fi."
        case .remoteRejected: "The source rejected the request."
        case .streamExpired: "The temporary audio link expired."
        case .unsupportedFormat: "No supported audio-only stream is available for this recording."
        case .verificationFailed: "The downloaded audio failed verification."
        case .insufficientStorage: "The audio file could not be stored. Check available storage."
        case .sourceUnavailable: "This recording is unavailable, private or removed."
        case .accessRestricted: "This recording requires access or verification the app cannot provide."
        case .userCancelled: "The download was cancelled."
        case .importFailed: "The audio could not be added to the library."
        case .tooLarge: "The audio exceeds the download size limit."
        case .unknown: "The download failed."
        }
    }

    static func classify(_ text: String?) -> AcquisitionFailureCategory {
        guard let text, !text.isEmpty else { return .unknown }
        switch text {
        case DownloadFailure.connection.rawValue: return .network
        case DownloadFailure.rejected.rawValue: return .remoteRejected
        case DownloadFailure.invalid.rawValue: return .verificationFailed
        case DownloadFailure.disk.rawValue: return .insufficientStorage
        case DownloadFailure.size.rawValue: return .tooLarge
        case DownloadFailure.terminated.rawValue: return .network
        case "Audio could not be imported.": return .importFailed
        default: break
        }
        let youtube: [(YouTubeError, AcquisitionFailureCategory)] = [
            (.networkUnavailable, .network), (.requestTimeout, .network), (.rateLimited, .remoteRejected),
            (.metadataUnavailable, .network), (.streamNotReady, .network), (.streamExpired, .streamExpired),
            (.extractionFailed, .remoteRejected), (.videoUnavailable, .sourceUnavailable),
            (.regionRestricted, .accessRestricted), (.accessRestricted, .accessRestricted), (.providerRestricted, .accessRestricted),
            (.noAudioStreams, .unsupportedFormat), (.noCompatibleAudio, .unsupportedFormat), (.invalidVideoID, .unsupportedFormat),
        ]
        return youtube.first { $0.0.errorDescription == text }?.1 ?? .unknown
    }
}

/// What a single occurrence shows. Derived from persisted link + shared job state.
enum AcquisitionDisplayState: Equatable, Sendable {
    case availableOffline
    case queued
    case preparing
    case waitingForWiFi
    case waitingForConnection
    case waitingForDevice
    /// Every download slot is in use; `limited` when Low Power Mode or temperature lowered the limit.
    case waitingForSlot(limited: Bool)
    /// iOS is not currently giving the app execution time (app in the background).
    case waitingForExecution
    case downloading(progress: Double?)
    /// A background transfer exists but iOS has not delivered any bytes yet.
    case waitingForSystem
    case verifying
    case playlistPaused
    case paused
    case failed(String, retryable: Bool)
    case unsupported(String)

    var label: String {
        switch self {
        case .availableOffline: return "Available offline"
        case .queued: return "Queued"
        case .preparing: return "Preparing download"
        case .waitingForWiFi: return "Waiting for Wi-Fi"
        case .waitingForConnection: return "Waiting for connection"
        case .waitingForDevice: return "Waiting for device to cool"
        case .waitingForSlot(let limited): return limited ? "Waiting for a download slot (Low Power Mode or temperature limit)" : "Waiting for a download slot"
        case .waitingForExecution: return "Waiting for iOS to resume the app"
        case .downloading(let progress):
            // A percentage only when the transfer reported a real byte total.
            guard let progress else { return "Downloading" }
            return "Downloading — \(Int((min(1, max(0, progress)) * 100).rounded(.down)))%"
        case .waitingForSystem: return "Waiting for iOS to start the transfer"
        case .verifying: return "Verifying audio"
        case .playlistPaused: return "Downloads paused"
        case .paused: return "Paused"
        case .failed: return "Download failed"
        case .unsupported: return "Unsupported source"
        }
    }
    var isActive: Bool {
        switch self { case .preparing, .downloading, .verifying: true; default: false }
    }
    var isPending: Bool {
        switch self { case .queued, .preparing, .waitingForWiFi, .waitingForConnection, .waitingForDevice, .waitingForSlot, .waitingForExecution, .downloading, .waitingForSystem, .verifying: true; default: false }
    }
    var needsAttention: Bool {
        switch self { case .failed, .unsupported: true; default: false }
    }
    var detail: String? {
        switch self {
        case .failed(let message, _), .unsupported(let message): message
        default: nil
        }
    }
}

/// Per-playlist counters. Every value is derived from persisted rows and jobs.
struct PlaylistAcquisitionSummary: Equatable, Sendable {
    var total = 0
    var availableOffline = 0
    var queued = 0
    var downloading = 0
    var waitingForWiFi = 0
    var verifying = 0
    var paused = 0
    var failed = 0
    var unsupported = 0
    var awaitingReview = 0
    var userPaused = false
    /// Low Power Mode or elevated device temperature limits transfers to one at a time.
    var resourceLimited = false

    var attention: Int { failed + unsupported }
    var acquiring: Int { queued + downloading + waitingForWiFi + verifying }
    var complete: Bool { total > 0 && availableOffline == total }
    var hasAcquisitionWork: Bool { acquiring + paused + attention > 0 }
}
