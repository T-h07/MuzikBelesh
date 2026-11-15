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
    /// Explicitly confirmed YouTube selections. Matched only: not downloaded or playable.
    var selected = 0
    /// Occurrences for which an external search was actually performed.
    var externalAttempted = 0
    /// Searches that returned a response (including zero relevant candidates).
    var externalSucceeded = 0
    /// Local matching completed, but external discovery was skipped because the
    /// provider was suspended (verification, 429, provider-wide restriction).
    var externalDeferred = 0
    /// Actual search requests that failed (song-specific or restricted).
    var discoveryFailedRequests = 0
    var resolved: Int { alreadyLocal + localMatches + selected }
    var unresolved: Int { max(0, total - resolved - recommended - review) }
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
    let restriction: ProviderRestrictionPolicy
    private var running = false
    init(repository: GRDBPlaylistMigrationRepository, providers: [any ExternalCandidateDiscovery],
         configuration: SongMatchingConfiguration = .standard, restriction: ProviderRestrictionPolicy = .standard) {
        self.repository = repository; self.providers = Array(providers.prefix(3)); self.restriction = restriction
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

    /// `only` limits the attempt to specific occurrences (Retry This Song). Every
    /// other occurrence, decision and checkpoint is left untouched.
    func run(migrationID: UUID, only: Set<UUID>? = nil, progress: @escaping @Sendable (SongMatchingProgress) async -> Void) async throws {
        guard !running else { throw SongMatchingError.busy }
        running = true
        defer { running = false }
        let session = try await repository.beginMatching(migrationID: migrationID)
        do {
            let entries = try await repository.entries(migrationID: migrationID).filter { only?.contains($0.id) ?? true }
            var index = try await repository.matchingLibrary()
            var report = SongMatchingProgress(total: entries.count)
            report.candidates = try await repository.matchingSummary(migrationID: migrationID).candidates
            report.deferred = entries.filter { [.pending, .matching].contains($0.status) }.count
            let runProviders = providers.map { $0.forRun() }
            // Per-provider restriction state. Individual failures never touch it.
            var restrictions = Array(repeating: (probes: 0, suspended: false, reason: ""), count: runProviders.count)
            await progress(report)
            for entry in entries {
                try Task.checkCancellation()
                guard let lease = try await repository.claimMatchingEntry(entry, session: session) else {
                    report.processed += 1
                    if entry.status == .ready { report.alreadyLocal += 1 }
                    else if entry.status == .matched { report.selected += 1 }
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
                    var deferred = false
                    var acceptedLocal: MatchingLocalRecording?
                    if decision.outcome == .local, let best = decision.ranked.first {
                        acceptedLocal = index.recordings[best.recording.identity]
                    } else {
                        var truncated = local.truncated
                        var seen = Set(scores.map { $0.recording.provider + ":" + $0.recording.identity })
                        var attempted = false
                        for (number, provider) in runProviders.enumerated() {
                            try Task.checkCancellation()
                            if restrictions[number].suspended { continue }
                            if restrictions[number].probes > 0 {
                                // Respect the restriction: wait, then make one fresh search for THIS occurrence.
                                report.message = "YouTube requested verification or limited requests. Waiting before the next independent search."
                                await progress(report)
                                try await restriction.sleep(restriction.cooldowns[min(restrictions[number].probes, restriction.cooldowns.count) - 1])
                            }
                            attempted = true
                            do {
                                let found = try await provider.discover(entry.source)
                                try Task.checkCancellation()
                                let providerWide = found.pauseDiscovery && MatchingDiscoveryFailurePolicy.immediate(found.failure)
                                if found.searchFailed { report.discoveryFailedRequests += 1 } else { report.externalSucceeded += 1 }
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
                                }
                                if providerWide {
                                    restrictions[number].probes += 1; restrictions[number].reason = issue ?? ""
                                    if restrictions[number].probes > restriction.cooldowns.count {
                                        restrictions[number].suspended = true; report.discoveryPaused = true
                                    }
                                } else if !found.searchFailed { restrictions[number] = (0, false, "") }
                            } catch {
                                if Task.isCancelled || error is CancellationError { throw CancellationError() }
                                MatchingDiagnostics.record(error, session: migrationID, entry: entry.id, stage: "discovery", provider: "provider-" + String(number))
                                discoveryFailed = true
                                report.discoveryFailedRequests += 1
                                let tripped = MatchingDiscoveryFailurePolicy.immediate(error as? YouTubeError)
                                let reason = (error as? YouTubeError) == .accessRestricted
                                    ? "YouTube search requires access or verification."
                                    : (error as? YouTubeError)?.localizedDescription ?? "YouTube discovery is unavailable."
                                issue = reason + " Discovery incomplete; saved candidates are preserved. Retry later."
                                report.message = issue
                                if tripped {
                                    restrictions[number].probes += 1; restrictions[number].reason = reason
                                    if restrictions[number].probes > restriction.cooldowns.count {
                                        restrictions[number].suspended = true; report.discoveryPaused = true
                                    }
                                }
                            }
                        }
                        if attempted { report.externalAttempted += 1 }
                        if !runProviders.isEmpty && !attempted {
                            deferred = true; discoveryFailed = true
                            issue = "External discovery deferred. " + (restrictions.first { $0.suspended }?.reason ?? "Discovery is unavailable.")
                                + " Local matching completed; retry unfinished discovery later."
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
                        try await repository.commitMatching(lease, decision: decision, local: acceptedLocal, librarySnapshot: index.snapshot, issue: issue, discoveryFailed: discoveryFailed, deferred: deferred)
                    } catch PlaylistMigrationStorageError.invalidLocalTrack {
                        // Never try the runner-up after failed file verification.
                        decision = .init(outcome: .review, ranked: decision.ranked,
                            explanation: "Managed local audio failed verification. No alternate recording was selected.", margin: decision.margin)
                        try await repository.commitMatching(lease, decision: decision, issue: decision.explanation)
                    }
                    report.candidates += decision.ranked.prefix(40).filter { score in
                        !lease.previousCandidates.contains { $0.provider == score.recording.provider && $0.providerTrackID == score.recording.identity }
                    }.count
                    if deferred { report.externalDeferred += 1 } else if discoveryFailed { report.discoveryFailed += 1 }
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
                // One occurrence never stops the job; only cancellation or fatal
                // storage/session failures propagate out of this loop.
                report.processed += 1
                await progress(report)
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
