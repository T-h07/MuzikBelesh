import Foundation

/// Everything persisted about one occurrence that classification needs. Built from one
/// indexed read per migration (`MigrationIssueRepository.facts`).
struct MigrationOccurrenceFacts: Equatable, Sendable {
    var status: PlaylistMigrationEntryStatus
    var localTrackID: String?
    /// The associated track exists, is managed, readable and has its recorded size.
    var trackAvailable = false
    /// Provider of the accepted decision ("local", "youtube"), if any.
    var acceptedProvider: String?
    var pendingCandidates = 0
    var rejectedCandidates = 0
    /// Matching checkpoint written by the matching engine.
    var checkpointOutcome: String?
    var checkpointRetryable = false
    /// Phase 10.6 bounded retry bookkeeping.
    var retryFailures: Int?
    var retryCategory: String?
    var retryEligible = false
    var retryLastAttemptAt: Date?
    var retryNextAt: Date?
    /// Phase 10.5 acquisition link and its shared download job.
    var linkState: AcquisitionLinkState?
    var linkFailure: String?
    var linkRetries = 0
    var linkNextRetryAt: Date?
    var linkUpdatedAt: Date?
    var jobState: StoredDownloadState?
    var jobError: String?
    var jobExpectedBytes: Int64?
}

/// Migration-wide conditions that change how an occurrence is described.
struct MigrationIssueContext: Equatable, Sendable {
    /// `migration_matching_jobs.intent` (nil: matching was never started).
    var matchingIntent: String?
    var cancelled = false
    var downloadsPaused = false
    /// Provider cooldown or connectivity wait recorded by the coordinator.
    var waitUntil: Date?
    var lifecycle: MigrationLifecycleState?
    /// Measured free capacity of the app's storage volume. Only a measured shortfall
    /// against the job's known size is reported as insufficient storage.
    var availableCapacity: Int64?
    var now = Date()

    var matchingPaused: Bool { matchingIntent == "userPaused" }
    var matchingRunning: Bool { ["running", "systemPaused"].contains(matchingIntent ?? "") }

    /// Observation time and the fluctuating free-space measurement are inputs, not state:
    /// two reports over the same rows compare equal, so SwiftUI is not refreshed needlessly.
    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.matchingIntent == rhs.matchingIntent && lhs.cancelled == rhs.cancelled && lhs.downloadsPaused == rhs.downloadsPaused
            && lhs.waitUntil == rhs.waitUntil && lhs.lifecycle == rhs.lifecycle
    }
}

/// Pure, deterministic classification. Never inspects free-form text except to compare
/// it for exact equality with the raw values/descriptions the owning subsystem writes
/// (`DownloadFailure`, `YouTubeError`, `AcquisitionFailureCategory.message`).
enum MigrationIssueClassifier {
    static let matchingActionsForUnmatched: [MigrationIssueAction] = [.retrySong, .attachLocalRecording, .importLocalFile, .skip]

    static func assess(_ facts: MigrationOccurrenceFacts, context: MigrationIssueContext) -> MigrationOccurrenceAssessment {
        switch facts.status {
        case .ready:
            if facts.localTrackID != nil && facts.trackAvailable { return .playable }
            // Marked ready, but the verified file is gone: never counted as playable.
            return failure(.missingLocalAudio, stage: .association, provenance: .playlistAssociation,
                           actions: [.attachLocalRecording, .importLocalFile])
        case .skipped:
            return .skipped
        case .unavailable:
            if facts.acceptedProvider == "local" || facts.checkpointOutcome == nil || facts.checkpointOutcome == "local" {
                return failure(.missingLocalAudio, stage: .association, provenance: .playlistAssociation,
                               actions: [.attachLocalRecording, .importLocalFile, .skip])
            }
            if let waiting = matchingWait(facts, context: context) { return waiting }
            if facts.pendingCandidates > 0 { return review(facts) }
            if context.cancelled { return cancelled(facts) }
            return failure(.noReliableMatch, stage: .matching, provenance: .externalDiscovery, retryable: true,
                           actions: matchingActionsForUnmatched, facts: facts)
        case .needsReview:
            if let waiting = matchingWait(facts, context: context, reviewable: facts.pendingCandidates > 0) { return waiting }
            if facts.pendingCandidates > 0 { return review(facts) }
            if context.cancelled { return cancelled(facts) }
            return failure(facts.rejectedCandidates > 0 ? .allSuggestionsRejected : .noReliableMatch, stage: .matching,
                           provenance: facts.rejectedCandidates > 0 ? .userCandidateSelection : .externalDiscovery, retryable: true,
                           actions: matchingActionsForUnmatched, facts: facts)
        case .failed:
            if let waiting = matchingWait(facts, context: context) { return waiting }
            if context.cancelled { return cancelled(facts) }
            return matchingFailure(facts)
        case .pending, .matching:
            if context.cancelled { return cancelled(facts) }
            if context.matchingPaused { return wait("Paused by you", .matching, facts: facts, automatic: false) }
            if let waiting = matchingWait(facts, context: context) { return waiting }
            if context.matchingIntent == nil { return wait("Matching hasn't started", .matching, facts: facts, automatic: false) }
            if context.matchingRunning {
                return wait(facts.status == .matching ? "Finding a recording" : "Waiting to be matched", .matching, facts: facts)
            }
            // Matching settled (completed/fatal) without reaching this occurrence.
            return failure(.notSearched, stage: .matching, provenance: .externalDiscovery, retryable: true,
                           actions: matchingActionsForUnmatched, facts: facts)
        case .matched, .queued, .downloading, .verifying:
            return acquisition(facts, context: context)
        }
    }

    // MARK: Matching

    /// A temporary condition (scheduled retry, provider deferral/cooldown) is status, not
    /// a failure: it never inflates the unresolved-failure count.
    private static func matchingWait(_ facts: MigrationOccurrenceFacts, context: MigrationIssueContext,
                                     reviewable: Bool = false) -> MigrationOccurrenceAssessment? {
        guard !context.cancelled else { return nil }
        if facts.checkpointOutcome == "discoveryDeferred" {
            if context.matchingPaused { return wait("Paused by you", .matching, facts: facts, automatic: false, reviewable: reviewable) }
            var value = wait("Search temporarily limited — continues automatically", .matching, facts: facts, reviewable: reviewable)
            value.category = .rateLimited; value.provenance = .externalDiscovery
            value.explanation = MigrationIssueCategory.rateLimited.explanation
            value.nextRetryAt = context.waitUntil.flatMap { $0 > context.now ? $0 : nil }
            return value
        }
        if facts.retryEligible, let next = facts.retryNextAt, facts.localTrackID == nil {
            if context.matchingPaused { return wait("Paused by you", .matching, facts: facts, automatic: false, reviewable: reviewable) }
            var value = wait(facts.retryCategory == MigrationFailureCategory.explicitRetry.rawValue ? "Retry scheduled" : "Retrying automatically",
                             .matching, facts: facts, reviewable: reviewable)
            if facts.retryCategory != MigrationFailureCategory.explicitRetry.rawValue, let category = matchingCategory(facts.checkpointOutcome) {
                value.category = category; value.explanation = category.explanation; value.provenance = .externalDiscovery
            }
            value.nextRetryAt = next
            value.retryable = true
            return value
        }
        return nil
    }

    private static func review(_ facts: MigrationOccurrenceFacts) -> MigrationOccurrenceAssessment {
        let category: MigrationIssueCategory = facts.pendingCandidates > 1 && facts.checkpointOutcome != "recommended" ? .ambiguousMatches : .needsConfirmation
        var value = MigrationOccurrenceAssessment(disposition: .needsReview, category: category, stage: .matching,
                                                  provenance: .externalDiscovery, status: "Needs your review", explanation: category.explanation)
        value.requiresReview = true
        value.actions = [.reviewCandidates, .attachLocalRecording, .importLocalFile, .skip]
        value.retryCount = facts.retryFailures ?? 0
        value.lastAttemptAt = facts.retryLastAttemptAt
        return value
    }

    static func matchingCategory(_ value: String?) -> MigrationIssueCategory? {
        guard let outcome = value else { return nil }
        return switch outcome {
        case MatchingFailureCategory.provider.rawValue, "discoveryFailed": .temporaryProviderFailure
        case MatchingFailureCategory.offline.rawValue: .networkUnavailable
        case MatchingFailureCategory.storageBusy.rawValue: .storageBusy
        case MatchingFailureCategory.changedRecords.rawValue, MatchingFailureCategory.interrupted.rawValue,
             MatchingFailureCategory.cancelled.rawValue, MatchingFailureCategory.userPaused.rawValue: .interruptedMatching
        case MatchingFailureCategory.metadata.rawValue: .unsupportedMetadata
        case "noMatch": .noReliableMatch
        default: nil
        }
    }

    private static func matchingFailure(_ facts: MigrationOccurrenceFacts) -> MigrationOccurrenceAssessment {
        let category = matchingCategory(facts.checkpointOutcome) ?? .unknown
        if category == .unsupportedMetadata {
            // Permanent: the same metadata fails again, so no retry is offered.
            return failure(.unsupportedMetadata, stage: .matching, provenance: .metadataImport,
                           actions: [.attachLocalRecording, .importLocalFile, .skip], facts: facts)
        }
        var value = failure(category, stage: .matching, provenance: category == .storageBusy ? .localMatching : .externalDiscovery,
                            retryable: true, actions: matchingActionsForUnmatched, facts: facts)
        if facts.retryFailures != nil && !facts.retryEligible { value.status = "Automatic retries exhausted" }
        return value
    }

    // MARK: Acquisition

    private static func acquisition(_ facts: MigrationOccurrenceFacts, context: MigrationIssueContext) -> MigrationOccurrenceAssessment {
        let category = acquisitionCategory(facts, capacity: context.availableCapacity)
        switch facts.linkState {
        case .unsupported:
            return failure(category, stage: .acquisition, provenance: provenance(category),
                           actions: [.chooseOtherRecording, .importLocalFile, .skip], facts: facts)
        case .failed:
            let permanentCategories: [MigrationIssueCategory] = [.sourceUnavailable, .regionRestricted, .providerAccessRestricted, .unsupportedFormat, .downloadTooLarge]
            let permanent = permanentCategories.contains(category)
            var actions: [MigrationIssueAction] = permanent ? [] : [.retryDownload]
            actions += [.chooseOtherRecording, .importLocalFile, .skip]
            return failure(category, stage: .acquisition, provenance: provenance(category), retryable: !permanent,
                           actions: actions, facts: facts)
        case .waiting, .associating, .ready:
            if context.cancelled { return cancelled(facts) }
            if context.downloadsPaused { return wait("Downloads paused by you", .acquisition, facts: facts, automatic: false) }
            var value = wait(downloadStatus(facts), .acquisition, facts: facts)
            if facts.linkRetries > 0, facts.linkFailure != nil {
                // A transient download failure with an automatic retry still pending.
                value.status = "Retrying automatically"
                value.category = category; value.explanation = category.explanation; value.provenance = provenance(category)
                value.retryCount = facts.linkRetries; value.nextRetryAt = facts.linkNextRetryAt; value.retryable = true
            }
            return value
        case nil:
            if context.cancelled { return cancelled(facts) }
            if context.downloadsPaused { return wait("Downloads paused by you", .acquisition, facts: facts, automatic: false) }
            return wait("Waiting to download", .acquisition, facts: facts)
        }
    }

    private static func downloadStatus(_ facts: MigrationOccurrenceFacts) -> String {
        if facts.linkState == .associating { return "Verifying audio" }
        switch facts.jobState {
        case .resolving: return "Preparing download"
        case .downloading: return "Downloading"
        case .verifying, .importing, .completed: return "Verifying audio"
        case .waitingForWiFi: return "Waiting for Wi-Fi"
        case .paused: return "Download paused"
        case .interrupted: return "Waiting for connection"
        default: return "Waiting to download"
        }
    }

    /// Exact mapping of the job's persisted error (written by `DownloadManager` from
    /// `DownloadFailure` raw values or `YouTubeError` descriptions), then of the link's
    /// persisted `AcquisitionFailureCategory` message. Unknown text stays `unknown`.
    static func acquisitionCategory(_ facts: MigrationOccurrenceFacts, capacity: Int64? = nil) -> MigrationIssueCategory {
        if facts.jobState == .cancelled { return .downloadCancelled }
        if let text = facts.jobError, !text.isEmpty {
            switch text {
            case DownloadFailure.connection.rawValue, DownloadFailure.terminated.rawValue: return .interruptedDownload
            case DownloadFailure.rejected.rawValue: return .expiredStream
            case DownloadFailure.invalid.rawValue: return .audioValidationFailed
            case DownloadFailure.size.rawValue: return .downloadTooLarge
            case DownloadFailure.disk.rawValue:
                // Proven only by a measured shortfall against the job's known size.
                if let capacity, let needed = facts.jobExpectedBytes, needed > 0, capacity < needed { return .insufficientStorage }
                return .storageWriteFailed
            case "Audio could not be imported.": return .importFailure
            default: break
            }
            let youtube: [(YouTubeError, MigrationIssueCategory)] = [
                (.networkUnavailable, .interruptedDownload), (.requestTimeout, .networkTimeout), (.rateLimited, .rateLimited),
                (.streamExpired, .expiredStream), (.streamNotReady, .temporaryProviderFailure), (.metadataUnavailable, .temporaryProviderFailure),
                (.extractionFailed, .temporaryProviderFailure), (.searchUnavailable, .temporaryProviderFailure),
                (.videoUnavailable, .sourceUnavailable), (.regionRestricted, .regionRestricted),
                (.accessRestricted, .providerAccessRestricted), (.providerRestricted, .providerAccessRestricted),
                (.redirectUnavailable, .providerAccessRestricted),
                (.noAudioStreams, .unsupportedFormat), (.noCompatibleAudio, .unsupportedFormat), (.invalidVideoID, .unsupportedFormat),
            ]
            if let match = youtube.first(where: { $0.0.errorDescription == text }) { return match.1 }
        }
        if let message = facts.linkFailure,
           let category = AcquisitionFailureCategory.allCases.first(where: { $0.message == message }) {
            switch category {
            case .network: return .interruptedDownload
            case .waitingForWiFi: return .interruptedDownload
            case .remoteRejected: return .expiredStream
            case .streamExpired: return .expiredStream
            case .unsupportedFormat: return .unsupportedFormat
            case .verificationFailed: return .audioValidationFailed
            case .insufficientStorage:
                if let capacity, let needed = facts.jobExpectedBytes, needed > 0, capacity < needed { return .insufficientStorage }
                return .storageWriteFailed
            case .sourceUnavailable: return .sourceUnavailable
            case .accessRestricted: return .providerAccessRestricted
            case .userCancelled: return .downloadCancelled
            case .importFailed: return .importFailure
            case .tooLarge: return .downloadTooLarge
            case .unknown: return .unknown
            }
        }
        return .unknown
    }

    static func provenance(_ category: MigrationIssueCategory) -> MigrationIssueProvenance {
        switch category {
        case .sourceUnavailable, .regionRestricted, .providerAccessRestricted, .unsupportedFormat, .expiredStream, .rateLimited,
             .temporaryProviderFailure: .downloadResolution
        case .interruptedDownload, .networkTimeout, .downloadCancelled, .downloadTooLarge: .networkTransfer
        case .audioValidationFailed: .audioValidation
        case .insufficientStorage, .storageWriteFailed, .importFailure: .storageImport
        case .missingLocalAudio: .playlistAssociation
        default: .downloadResolution
        }
    }

    // MARK: Builders

    private static func cancelled(_ facts: MigrationOccurrenceFacts) -> MigrationOccurrenceAssessment {
        failure(.migrationCancelled, stage: facts.status == .matched ? .acquisition : .matching, provenance: .migrationLifecycle,
                actions: [.attachLocalRecording, .importLocalFile, .skip], facts: facts)
    }

    private static func failure(_ category: MigrationIssueCategory, stage: MigrationIssueStage, provenance: MigrationIssueProvenance,
                                retryable: Bool = false, actions: [MigrationIssueAction], facts: MigrationOccurrenceFacts? = nil) -> MigrationOccurrenceAssessment {
        var value = MigrationOccurrenceAssessment(disposition: .failed, category: category, stage: stage, provenance: provenance,
                                                  status: "Needs attention", explanation: category.explanation)
        value.retryable = retryable
        value.actions = actions
        if let facts {
            value.retryCount = stage == .acquisition ? facts.linkRetries : (facts.retryFailures ?? 0)
            value.lastAttemptAt = stage == .acquisition ? facts.linkUpdatedAt : facts.retryLastAttemptAt
            // Pending suggestions remain reviewable even when the last attempt failed.
            if stage == .matching, facts.pendingCandidates > 0, !value.actions.contains(.reviewCandidates) {
                value.actions.insert(.reviewCandidates, at: 0)
            }
        }
        return value
    }

    private static func wait(_ status: String, _ stage: MigrationIssueStage, facts: MigrationOccurrenceFacts,
                             automatic: Bool = true, reviewable: Bool = false) -> MigrationOccurrenceAssessment {
        var value = MigrationOccurrenceAssessment(disposition: .waiting, stage: stage, status: status)
        value.automaticRecovery = automatic
        value.retryCount = stage == .acquisition ? facts.linkRetries : (facts.retryFailures ?? 0)
        value.lastAttemptAt = stage == .acquisition ? nil : facts.retryLastAttemptAt
        if reviewable { value.actions = [.reviewCandidates] }
        if stage == .matching { value.actions += [.skip] } else if facts.status == .matched { value.actions += [.skip] }
        return value
    }
}
