import Foundation

struct SongMatchingProgress: Sendable {
    var total = 0
    var processed = 0
    var alreadyLocal = 0
    var localMatches = 0
    var recommended = 0
    var review = 0
    var noMatch = 0
    var failed = 0
    var candidates = 0
    var discoveryFailed = 0
    var deferred = 0
    var discoveryPaused = false
    var message: String? = nil
}

/// One app-owned worker, one in-flight provider call, incremental atomic commits.
/// This service has no playback, download, stream resolver or track-creation dependency.
actor PlaylistMigrationMatchingService: PlaylistMigrationMatching {
    let repository: GRDBPlaylistMigrationRepository
    let providers: [any ExternalCandidateDiscovery]
    let scoring: CandidateScoringEngine
    let policy: MatchDecisionPolicy
    private var running = false
    init(repository: GRDBPlaylistMigrationRepository, providers: [any ExternalCandidateDiscovery],
         configuration: SongMatchingConfiguration = .standard) {
        self.repository = repository; self.providers = Array(providers.prefix(3))
        scoring = CandidateScoringEngine(configuration: configuration)
        policy = MatchDecisionPolicy(configuration: configuration)
    }

    /// Read-only protocol adapter. Lifecycle callers use run() so decisions are
    /// checked and persisted at the transaction boundary.
    func candidates(for entry: PlaylistMigrationEntry) async throws -> [PlaylistMigrationCandidate] {
        let index = try await repository.matchingLibrary()
        let local = index.candidates(for: entry.source)
        var scores = local.values.map { scoring.score(source: entry.source, candidate: $0) }
        if policy.decide(scores, truncated: local.truncated).outcome != .local {
            for provider in providers {
                let result = try await provider.discover(entry.source)
                scores += result.recordings.prefix(20).map { scoring.score(source: entry.source, candidate: $0) }
            }
        }
        let previous = try await repository.candidates(entryID: entry.id)
        return policy.decide(scores).ranked.prefix(40).map { score in
            let old = previous.first { $0.provider == score.recording.provider && $0.providerTrackID == score.recording.identity }
            return PlaylistMigrationCandidate(id: old?.id ?? UUID(), entryID: entry.id, provider: score.recording.provider,
                providerTrackID: score.recording.identity, title: score.recording.title, artist: score.recording.artist,
                durationMs: score.recording.durationMs, confidence: score.score / 100, evidence: score.evidence, decision: old?.decision ?? .pending)
        }
    }

    func run(migrationID: UUID, progress: @escaping @Sendable (SongMatchingProgress) async -> Void) async throws {
        guard !running else { throw SongMatchingError.busy }
        running = true
        defer { running = false }
        let session = try await repository.beginMatching(migrationID: migrationID)
        do {
            let entries = try await repository.entries(migrationID: migrationID)
            var index = try await repository.matchingLibrary()
            var report = SongMatchingProgress(total: entries.count)
            report.candidates = try await repository.matchingSummary(migrationID: migrationID).candidates
            report.deferred = entries.filter { [.pending, .matching].contains($0.status) }.count
            await progress(report)
            for entry in entries {
                try Task.checkCancellation()
                guard let lease = try await repository.claimMatchingEntry(entry, session: session) else {
                    report.processed += 1
                    if entry.status == .ready { report.alreadyLocal += 1 }
                    else if entry.status == .needsReview {
                        let prior = try await repository.candidates(entryID: entry.id)
                        if prior.contains(where: { $0.evidence["currentAttempt"] == "true" && $0.evidence["outcome"] == "recommended" && $0.decision == .pending }) { report.recommended += 1 }
                        else { report.review += 1 }
                    }
                    await progress(report); continue
                }
                if [.pending, .matching].contains(entry.status) { report.deferred -= 1 }
                do {
                    if lease.previousCandidates.count >= 60 {
                        let decision = SongMatchDecision(outcome: .review, ranked: [], explanation: "Saved candidate history limit reached. Review existing alternatives before further discovery.", margin: 0)
                        try await repository.commitMatching(lease, decision: decision, issue: decision.explanation)
                        report.processed += 1; report.review += 1; await progress(report); continue
                    }
                    let rejected = Set(lease.previousCandidates.filter { $0.decision == .rejected }.map { $0.provider + ":" + ($0.providerTrackID ?? "") })
                    let local = index.candidates(for: entry.source)
                    var scores = local.values.filter { !rejected.contains($0.provider + ":" + $0.identity) }
                        .map { scoring.score(source: entry.source, candidate: $0) }
                    var decision = policy.decide(scores, truncated: local.truncated)
                    var issue: String?
                    var discoveryFailed = false
                    var acceptedLocal: MatchingLocalRecording?
                    if decision.outcome == .local, let best = decision.ranked.first {
                        acceptedLocal = index.recordings[best.recording.identity]
                    } else {
                        var truncated = local.truncated
                        var seen = Set(scores.map { $0.recording.provider + ":" + $0.recording.identity })
                        for (number, provider) in providers.enumerated() {
                            try Task.checkCancellation()
                            do {
                                let found = try await provider.discover(entry.source)
                                try Task.checkCancellation()
                                truncated = truncated || found.truncated
                                for recording in found.recordings.prefix(20) {
                                    let identity = recording.provider + ":" + recording.identity
                                    guard !rejected.contains(identity), seen.insert(identity).inserted else { continue }
                                    scores.append(scoring.score(source: entry.source, candidate: recording))
                                }
                                if !found.failures.isEmpty {
                                    discoveryFailed = true
                                    let reason = found.failure == .accessRestricted && found.pauseDiscovery
                                        ? "YouTube search requires access or verification."
                                        : found.failure?.localizedDescription ?? "YouTube discovery is unavailable."
                                    issue = reason + " Discovery incomplete; saved candidates are preserved. Retry later."
                                    report.message = issue
                                    if let failure = found.failure {
                                        MatchingDiagnostics.record(failure, session: migrationID, entry: entry.id, stage: "discovery", provider: "youtube")
                                    }
                                    if found.pauseDiscovery { report.discoveryPaused = true; break }
                                }
                            } catch {
                                if Task.isCancelled || error is CancellationError { throw CancellationError() }
                                MatchingDiagnostics.record(error, session: migrationID, entry: entry.id, stage: "discovery", provider: "provider-" + String(number))
                                discoveryFailed = true
                                if let failure = error as? YouTubeError {
                                    report.discoveryPaused = [.rateLimited, .networkUnavailable, .requestTimeout, .searchUnavailable, .accessRestricted].contains(failure)
                                } else { report.discoveryPaused = true }
                                let reason = (error as? YouTubeError) == .accessRestricted
                                    ? "YouTube search requires access or verification."
                                    : (error as? YouTubeError)?.localizedDescription ?? "YouTube discovery is unavailable."
                                issue = reason + " Discovery incomplete; saved candidates are preserved. Retry later."
                                report.message = issue
                                if report.discoveryPaused { break }
                            }
                        }
                        decision = policy.decide(scores, truncated: truncated)
                        if discoveryFailed && !decision.ranked.isEmpty {
                            decision = SongMatchDecision(outcome: .review, ranked: decision.ranked,
                                explanation: "Discovery is incomplete. Saved candidates require review; retry to finish comparison.", margin: decision.margin)
                        }
                        // Local uncertainty must never be promoted by remote ranking.
                        if decision.outcome == .local {
                            decision = SongMatchDecision(outcome: .review, ranked: decision.ranked, explanation: "Local identity needs review after external comparison.", margin: decision.margin)
                        }
                    }
                    do {
                        try await repository.commitMatching(lease, decision: decision, local: acceptedLocal, librarySnapshot: index.snapshot, issue: issue, discoveryFailed: discoveryFailed)
                    } catch PlaylistMigrationStorageError.invalidLocalTrack {
                        // Never try the runner-up after failed file verification.
                        decision = .init(outcome: .review, ranked: decision.ranked,
                            explanation: "Managed local audio failed verification. No alternate recording was selected.", margin: decision.margin)
                        try await repository.commitMatching(lease, decision: decision, issue: decision.explanation)
                    }
                    report.candidates += decision.ranked.prefix(40).filter { score in
                        !lease.previousCandidates.contains { $0.provider == score.recording.provider && $0.providerTrackID == score.recording.identity }
                    }.count
                    if discoveryFailed { report.discoveryFailed += 1 }
                    switch decision.outcome {
                    case .local: report.localMatches += 1
                    case .recommended: report.recommended += 1
                    case .review: report.review += 1
                    case .noMatch: if !discoveryFailed { report.noMatch += 1 }
                    }
                } catch {
                    if Task.isCancelled || error is CancellationError { throw CancellationError() }
                    let category = MatchingFailureCategory.classify(error)
                    MatchingDiagnostics.record(error, session: migrationID, entry: entry.id, stage: "occurrence")
                    guard category != .storageFatal else { throw error }
                    try await repository.recordMatchingFailure(lease, category: category)
                    report.failed += 1; report.message = category.message
                    if category == .changedRecords { index = try await repository.matchingLibrary() }
                }
                report.processed += 1
                await progress(report)
                if report.discoveryPaused { break }
            }
            try Task.checkCancellation()
            try await repository.finishMatching(session, paused: report.discoveryPaused)
            await progress(try await repository.matchingSummary(migrationID: migrationID))
        } catch {
            // A separate non-cancelled cleanup task closes only this lease. If a
            // newer run/user action owns the session, its revision wins.
            let repository = repository
            MatchingDiagnostics.record(error, session: migrationID, entry: nil, stage: "job")
            do { try await Task.detached { try await repository.finishMatching(session, paused: true) }.value }
            catch { MatchingDiagnostics.record(error, session: migrationID, entry: nil, stage: "cleanup") }
            throw error
        }
    }
}
