import XCTest
@testable import OFFLINE

/// Phase 10.7 classification (T01–T09 and the precision rules). Pure and deterministic:
/// every input is the exact persisted value the owning subsystem writes.
final class MigrationIssueClassifierTests: XCTestCase {
    private let running = MigrationIssueContext(matchingIntent: "completed")

    private func facts(_ status: PlaylistMigrationEntryStatus, _ change: (inout MigrationOccurrenceFacts) -> Void = { _ in }) -> MigrationOccurrenceFacts {
        var value = MigrationOccurrenceFacts(status: status); change(&value); return value
    }
    private func download(_ link: AcquisitionLinkState, error: String?, failure: String? = nil) -> MigrationOccurrenceFacts {
        facts(.matched) { $0.acceptedProvider = "youtube"; $0.linkState = link; $0.jobState = .failed; $0.jobError = error; $0.linkFailure = failure }
    }

    // T01
    func testCompletedMatchingWithoutReliableRecordingIsNoReliableMatch() {
        let value = MigrationIssueClassifier.assess(facts(.unavailable) { $0.checkpointOutcome = "noMatch" }, context: running)
        XCTAssertEqual(value.disposition, .failed)
        XCTAssertEqual(value.category, .noReliableMatch)
        XCTAssertEqual(value.stage, .matching)
        XCTAssertEqual(value.explanation, "We couldn't find a reliable recording for this song.")
        XCTAssertEqual(value.actions, [.retrySong, .attachLocalRecording, .importLocalFile, .skip])
        XCTAssertFalse(value.automaticRecovery)
    }

    // T02
    func testSeveralPlausibleCandidatesNeedReviewAndOneCandidateIsNotCalledIncorrect() {
        let several = MigrationIssueClassifier.assess(facts(.needsReview) { $0.pendingCandidates = 3; $0.checkpointOutcome = "review" }, context: running)
        XCTAssertEqual(several.disposition, .needsReview)
        XCTAssertEqual(several.category, .ambiguousMatches)
        XCTAssertTrue(several.requiresReview)
        XCTAssertEqual(several.actions.first, .reviewCandidates)
        XCTAssertEqual(several.explanation, "Several recordings look similar. Choose the correct version.")
        // A single below-threshold candidate is only "needs confirmation", never "wrong".
        let one = MigrationIssueClassifier.assess(facts(.needsReview) { $0.pendingCandidates = 1; $0.checkpointOutcome = "review" }, context: running)
        XCTAssertEqual(one.category, .needsConfirmation)
        let text = (one.explanation ?? "").lowercased()
        XCTAssertFalse(text.contains("incorrect") || text.contains("wrong"))
        // The engine's recommendation is also a confirmation, not an ambiguity.
        let recommended = MigrationIssueClassifier.assess(facts(.needsReview) { $0.pendingCandidates = 4; $0.checkpointOutcome = "recommended" }, context: running)
        XCTAssertEqual(recommended.category, .needsConfirmation)
    }

    // T03
    func testOnlyAnExplicitRegionRestrictionIsReportedAsRegional() {
        let region = MigrationIssueClassifier.assess(download(.unsupported, error: YouTubeError.regionRestricted.errorDescription), context: running)
        XCTAssertEqual(region.category, .regionRestricted)
        XCTAssertEqual(region.explanation, "This recording is unavailable in your region.")
        XCTAssertFalse(region.actions.contains(.retryDownload))
        XCTAssertEqual(region.actions, [.chooseOtherRecording, .importLocalFile, .skip])
        // A generic access restriction (for example an HTTP 403 from the provider) is not regional.
        let access = MigrationIssueClassifier.assess(download(.unsupported, error: YouTubeError.accessRestricted.errorDescription), context: running)
        XCTAssertEqual(access.category, .providerAccessRestricted)
        // A rejected media request during transfer is an expired/rejected link, not a region block.
        let rejected = MigrationIssueClassifier.assess(download(.failed, error: DownloadFailure.rejected.rawValue), context: running)
        XCTAssertEqual(rejected.category, .expiredStream)
        XCTAssertTrue(rejected.actions.contains(.retryDownload))
    }

    // T04
    func testTimeoutAndRateLimitingAreDistinctAndRateLimitingIsNotAMissingSong() {
        let timeout = MigrationIssueClassifier.assess(download(.failed, error: YouTubeError.requestTimeout.errorDescription), context: running)
        let limited = MigrationIssueClassifier.assess(download(.failed, error: YouTubeError.rateLimited.errorDescription), context: running)
        XCTAssertEqual(timeout.category, .networkTimeout)
        XCTAssertEqual(limited.category, .rateLimited)
        XCTAssertNotEqual(timeout.category, limited.category)
        // A provider-wide deferral during matching is a waiting condition, not a failure.
        var context = MigrationIssueContext(matchingIntent: "running")
        context.waitUntil = context.now.addingTimeInterval(120)
        let deferred = MigrationIssueClassifier.assess(facts(.needsReview) { $0.checkpointOutcome = "discoveryDeferred" }, context: context)
        XCTAssertEqual(deferred.disposition, .waiting)
        XCTAssertEqual(deferred.category, .rateLimited)
        XCTAssertTrue(deferred.automaticRecovery)
        XCTAssertFalse(deferred.disposition.needsAttention)
        XCTAssertNotEqual(deferred.category, .noReliableMatch)
    }

    // T05
    func testExpiredStreamIsRecoverableThroughAcquisition() {
        let next = Date().addingTimeInterval(60)
        let retrying = MigrationIssueClassifier.assess(facts(.matched) {
            $0.acceptedProvider = "youtube"; $0.linkState = .waiting; $0.linkRetries = 1; $0.linkNextRetryAt = next
            $0.linkFailure = AcquisitionFailureCategory.streamExpired.message; $0.jobState = .failed
            $0.jobError = YouTubeError.streamExpired.errorDescription
        }, context: running)
        XCTAssertEqual(retrying.disposition, .waiting, "A scheduled automatic retry is not a failure")
        XCTAssertEqual(retrying.category, .expiredStream)
        XCTAssertTrue(retrying.automaticRecovery)
        XCTAssertTrue(retrying.retryable)
        XCTAssertEqual(retrying.nextRetryAt, next)
        XCTAssertEqual(retrying.status, "Retrying automatically")
        let exhausted = MigrationIssueClassifier.assess(download(.failed, error: YouTubeError.streamExpired.errorDescription), context: running)
        XCTAssertEqual(exhausted.disposition, .failed)
        XCTAssertEqual(exhausted.actions.first, .retryDownload)
        XCTAssertEqual(exhausted.stage, .acquisition)
        XCTAssertEqual(exhausted.provenance, .downloadResolution)
    }

    // T06
    func testInsufficientStorageOnlyWhenTheShortfallIsMeasured() {
        var failing = download(.failed, error: DownloadFailure.disk.rawValue)
        failing.jobExpectedBytes = 5_000_000
        XCTAssertEqual(MigrationIssueClassifier.acquisitionCategory(failing, capacity: 1_000_000), .insufficientStorage)
        let proven = MigrationIssueClassifier.assess(failing, context: MigrationIssueContext(matchingIntent: "completed", availableCapacity: 1_000_000))
        XCTAssertEqual(proven.explanation, "There isn't enough available storage to save this recording.")
        XCTAssertEqual(proven.provenance, .storageImport)
        XCTAssertTrue(proven.actions.contains(.retryDownload))
        // Unknown capacity or enough space: a write failure, never claimed as a full device.
        XCTAssertEqual(MigrationIssueClassifier.acquisitionCategory(failing, capacity: nil), .storageWriteFailed)
        XCTAssertEqual(MigrationIssueClassifier.acquisitionCategory(failing, capacity: 50_000_000), .storageWriteFailed)
        // An import failure is not a storage-capacity failure.
        XCTAssertEqual(MigrationIssueClassifier.acquisitionCategory(download(.failed, error: "Audio could not be imported.")), .importFailure)
    }

    // T07
    func testValidationFailureAndMissingAudioAreNeverPlayable() {
        let invalid = MigrationIssueClassifier.assess(download(.failed, error: DownloadFailure.invalid.rawValue), context: running)
        XCTAssertEqual(invalid.category, .audioValidationFailed)
        XCTAssertEqual(invalid.provenance, .audioValidation)
        XCTAssertNotEqual(invalid.disposition, .playable)
        let ready = MigrationIssueClassifier.assess(facts(.ready) { $0.localTrackID = "track"; $0.trackAvailable = false }, context: running)
        XCTAssertEqual(ready.disposition, .failed)
        XCTAssertEqual(ready.category, .missingLocalAudio)
        XCTAssertFalse(ready.actions.contains(.skip), "A ready occurrence cannot be skipped by the state machine")
        XCTAssertEqual(MigrationIssueClassifier.assess(facts(.ready) { $0.localTrackID = "track"; $0.trackAvailable = true }, context: running), .playable)
    }

    // T08
    func testPermanentFailuresOfferOnlyManualActions() {
        let metadata = MigrationIssueClassifier.assess(facts(.failed) { $0.checkpointOutcome = "metadata" }, context: running)
        XCTAssertEqual(metadata.category, .unsupportedMetadata)
        XCTAssertFalse(metadata.retryable)
        XCTAssertFalse(metadata.actions.contains(.retrySong))
        XCTAssertEqual(metadata.actions, [.attachLocalRecording, .importLocalFile, .skip])
        let format = MigrationIssueClassifier.assess(download(.unsupported, error: YouTubeError.noCompatibleAudio.errorDescription), context: running)
        XCTAssertEqual(format.category, .unsupportedFormat)
        XCTAssertFalse(format.retryable)
        XCTAssertFalse(format.automaticRecovery)
        XCTAssertEqual(format.actions, [.chooseOtherRecording, .importLocalFile, .skip])
        // Classification also works from the link's persisted category message alone.
        let unavailable = MigrationIssueClassifier.assess(download(.unsupported, error: nil, failure: AcquisitionFailureCategory.sourceUnavailable.message), context: running)
        XCTAssertEqual(unavailable.category, .sourceUnavailable)
    }

    // T09
    func testUnknownCausesUseATruthfulGenericExplanation() {
        let transfer = MigrationIssueClassifier.assess(download(.failed, error: "Something new the app never wrote before"), context: running)
        XCTAssertEqual(transfer.category, .unknown)
        XCTAssertEqual(transfer.explanation, "This song couldn't be processed. The exact cause wasn't recorded.")
        let matching = MigrationIssueClassifier.assess(facts(.failed) { $0.checkpointOutcome = "someFutureOutcome" }, context: running)
        XCTAssertEqual(matching.category, .unknown)
        XCTAssertEqual(matching.disposition, .failed)
    }

    func testInterruptedTransfersAreTemporaryAndWaitingConditionsAreNotFailures() {
        let interrupted = MigrationIssueClassifier.assess(download(.failed, error: DownloadFailure.connection.rawValue), context: running)
        XCTAssertEqual(interrupted.category, .interruptedDownload)
        XCTAssertTrue(interrupted.retryable, "An interrupted transfer is never permanent")
        XCTAssertTrue(interrupted.actions.contains(.retryDownload))
        // Queued, downloading, paused and never-started work is waiting, not failed.
        let queued = MigrationIssueClassifier.assess(facts(.matched) { $0.acceptedProvider = "youtube"; $0.linkState = .waiting; $0.jobState = .downloading }, context: running)
        XCTAssertEqual(queued.disposition, .waiting); XCTAssertEqual(queued.status, "Downloading")
        var paused = running; paused.downloadsPaused = true
        XCTAssertEqual(MigrationIssueClassifier.assess(facts(.matched) { $0.acceptedProvider = "youtube"; $0.linkState = .waiting }, context: paused).status, "Downloads paused by you")
        let pending = MigrationIssueClassifier.assess(facts(.pending), context: MigrationIssueContext(matchingIntent: "running"))
        XCTAssertEqual(pending.disposition, .waiting)
        XCTAssertEqual(MigrationIssueClassifier.assess(facts(.pending), context: MigrationIssueContext(matchingIntent: "userPaused")).status, "Paused by you")
        // A scheduled matching retry is waiting; an exhausted one needs the user.
        let scheduled = MigrationIssueClassifier.assess(facts(.failed) {
            $0.checkpointOutcome = "provider"; $0.retryFailures = 1; $0.retryEligible = true; $0.retryNextAt = Date().addingTimeInterval(30)
        }, context: MigrationIssueContext(matchingIntent: "running"))
        XCTAssertEqual(scheduled.disposition, .waiting); XCTAssertEqual(scheduled.category, .temporaryProviderFailure)
        let exhausted = MigrationIssueClassifier.assess(facts(.failed) {
            $0.checkpointOutcome = "provider"; $0.retryFailures = 4; $0.retryEligible = false
        }, context: MigrationIssueContext(matchingIntent: "completed"))
        XCTAssertEqual(exhausted.disposition, .failed); XCTAssertEqual(exhausted.status, "Automatic retries exhausted")
        XCTAssertTrue(exhausted.actions.contains(.retrySong))
    }

    func testCancelledMigrationStopsWorkTruthfully() {
        var context = running; context.cancelled = true
        let value = MigrationIssueClassifier.assess(facts(.pending), context: context)
        XCTAssertEqual(value.category, .migrationCancelled)
        XCTAssertEqual(value.disposition, .failed)
        XCTAssertFalse(value.actions.contains(.retrySong))
    }

    func testUserFacingTextNeverExposesInternals() {
        for category in MigrationIssueCategory.allCases {
            let text = category.explanation + " " + category.title
            XCTAssertNil(text.range(of: "(?i)(error\\s*-?\\d+|youtubeerror|downloadfailure|avfoundation|http|sqlite|\\.swift)", options: .regularExpression), category.rawValue)
            XCTAssertNoThrow(try MigrationPersistentText.validate([category.explanation]))
        }
    }
}
