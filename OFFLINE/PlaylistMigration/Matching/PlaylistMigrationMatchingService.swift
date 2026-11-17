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
    /// Live per-source metrics for this attempt (not persisted).
    var providerStats: [String: DiscoveryProviderStats] = [:]
    /// The run stopped because the device appears to be offline (not a song failure).
    var waitingForConnection = false
    var resolved: Int { alreadyLocal + localMatches + selected }
    var readyToReview: Int { recommended + review }
    var needAttention: Int { discoveryFailed + failed + noMatch }
    var remaining: Int { deferred + externalDeferred }
    var unresolved: Int { max(0, total - resolved - recommended - review) }
    var discoveryPaused = false
    var message: String? = nil
}

struct DiscoveryProviderStats: Sendable, Equatable {
    var attempts = 0, succeeded = 0, failed = 0, cooldownSkips = 0
    var totalSeconds = 0.0
    var averageSeconds: Double { attempts == 0 ? 0 : totalSeconds / Double(attempts) }
}

extension SongMatchingProgress {
    mutating func record(_ provider: String, seconds duration: Duration, failed: Bool) {
        var stats = providerStats[provider, default: .init()]
        stats.attempts += 1
        if failed { stats.failed += 1 } else { stats.succeeded += 1 }
        stats.totalSeconds += Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
        providerStats[provider] = stats
    }
    mutating func recordSkip(_ provider: String) { providerStats[provider, default: .init()].cooldownSkips += 1 }
}

private struct ProviderHealth {
    var probes = 0
    var suspended = false
    var reason = ""
    var retryAt: ContinuousClock.Instant?
    var failStreak = 0
}

/// One app-owned worker, one in-flight provider call, incremental atomic commits.
/// This service has no playback, download, stream resolver or track-creation dependency.
actor PlaylistMigrationMatchingService: PlaylistMigrationMatching {
    let repository: GRDBPlaylistMigrationRepository
    let providers: [any ExternalCandidateDiscovery]
    let scoring: CandidateScoringEngine
    let policy: MatchDecisionPolicy
    let restriction: ProviderRestrictionPolicy
    /// Phase 10.6: provider-wide restriction deadlines shared across runs, migrations and
    /// launches. Nil keeps the original per-run behavior exactly.
    let cooldowns: (any ProviderCooldownPersisting)?
    private let now: @Sendable () -> Date
    private var running = false
    /// Final report of the last completed run (read by the view model after `run` returns).
    private(set) var lastReport = SongMatchingProgress()
    /// Occurrences the last run actually claimed (coordinator pass accounting).
    private(set) var lastClaimed = 0
    init(repository: GRDBPlaylistMigrationRepository, providers: [any ExternalCandidateDiscovery],
         configuration: SongMatchingConfiguration = .standard, restriction: ProviderRestrictionPolicy = .standard,
         cooldowns: (any ProviderCooldownPersisting)? = nil, now: @escaping @Sendable () -> Date = { Date() }) {
        self.repository = repository; self.providers = Array(providers.prefix(3)); self.restriction = restriction
        self.cooldowns = cooldowns; self.now = now
        scoring = CandidateScoringEngine(configuration: configuration)
        policy = MatchDecisionPolicy(configuration: configuration)
    }

    /// Enabled discovery sources for the next run, in preference order.
    func enabledProviderNames() -> [String] {
        providers.map { $0.forRun() }.filter(\.isEnabled).map(\.discoveryName)
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
    /// `retryFailed == false` is an ordinary resume: only unfinished/deferred songs are
    /// searched. `true` additionally retries songs whose earlier search failed.
    func run(migrationID: UUID, only: Set<UUID>? = nil, retryFailed: Bool = true,
             progress: @escaping @Sendable (SongMatchingProgress) async -> Void) async throws {
        guard !running else { throw SongMatchingError.busy }
        running = true
        lastClaimed = 0
        defer { running = false }
        let session = try await repository.beginMatching(migrationID: migrationID)
        do {
            let entries = try await repository.entries(migrationID: migrationID).filter { only?.contains($0.id) ?? true }
            var index = try await repository.matchingLibrary()
            // Progress starts from authoritative persisted state, never from zero.
            var report = try await repository.matchingSummary(migrationID: migrationID)
            report.discoveryPaused = false; report.message = nil
            var lastRefresh = ContinuousClock.now
            var connectivityStreak = 0
            var claimed = 0, skippedCompleted = 0
            // Enabled sources only, in preference order (e.g. SearXNG, then direct YouTube).
            let runProviders = providers.map { $0.forRun() }.filter(\.isEnabled)
            // Independent health per source: restriction cooldowns/probes and failure streaks.
            var restrictions = Array(repeating: ProviderHealth(), count: runProviders.count)
            let clock = ContinuousClock()
            // Durable cooldowns (Phase 10.6): a source still restricted by an earlier run,
            // migration or launch is not called; its songs are deferred after local
            // matching and the coordinator resumes them once the deadline has passed.
            var cooldownWrites: [String: PersistedProviderCooldown?] = [:]
            var cooling = Set<String>()
            if let cooldowns, let saved = try? await cooldowns.providerCooldowns() {
                let wall = now()
                for number in runProviders.indices {
                    let name = runProviders[number].discoveryName
                    guard let entry = saved[name] else { continue }
                    cooling.insert(name)
                    restrictions[number].probes = min(entry.probes, restriction.cooldowns.count)
                    if entry.expiresAt > wall {
                        restrictions[number].suspended = true
                        restrictions[number].reason = entry.reason ?? "Search temporarily limited."
                    }
                }
            }
            func flushCooldowns() async {
                guard let cooldowns, !cooldownWrites.isEmpty else { return }
                let writes = cooldownWrites
                cooldownWrites.removeAll()
                for (name, write) in writes {
                    if let value = write { try? await cooldowns.saveProviderCooldown(value) }
                    else { try? await cooldowns.clearProviderCooldown(name) }
                }
            }
            await progress(report)
            for entry in entries {
                try Task.checkCancellation()
                guard let lease = try await repository.claimMatchingEntry(entry, session: session, retryFailed: retryFailed) else {
                    skippedCompleted += 1 // Already counted by the persisted summary.
                    continue
                }
                claimed += 1
                let wasUnfinished = [.pending, .matching].contains(entry.status)
                if wasUnfinished { report.deferred -= 1 }
                do {
                    if lease.previousCandidates.count >= 60 {
                        let decision = SongMatchDecision(outcome: .review, ranked: [], explanation: "Saved candidate history limit reached. Review existing alternatives before further discovery.", margin: 0)
                        try await repository.commitMatching(lease, decision: decision, issue: decision.explanation)
                        if wasUnfinished { report.processed += 1 }
                        report.review += 1; await progress(report); continue
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
                        var attempted = false, foundCandidates = false, failedAny = false
                        var connectivityOnly = true, sawConnectivityFailure = false
                        var attemptedProviders = Set<Int>(), skipped = Set<Int>()
                        func escalate(_ number: Int, _ reason: String, retryAfter: Duration? = nil) {
                            restrictions[number].probes += 1; restrictions[number].reason = reason; restrictions[number].failStreak = 0
                            var wait = restriction.suspendedCooldown
                            if restrictions[number].probes > restriction.cooldowns.count { restrictions[number].suspended = true }
                            else {
                                wait = restriction.cooldowns[restrictions[number].probes - 1]
                                // A valid Retry-After is honored, bounded to one hour.
                                if let retryAfter, retryAfter > .zero { wait = max(wait, min(retryAfter, .seconds(3600))) }
                                restrictions[number].retryAt = clock.now.advanced(by: wait)
                            }
                            guard cooldowns != nil else { return }
                            let name = runProviders[number].discoveryName, stamp = now()
                            cooling.insert(name)
                            cooldownWrites[name] = .some(PersistedProviderCooldown(provider: name, expiresAt: stamp.addingTimeInterval(wait.matchingSeconds),
                                probes: restrictions[number].probes, reason: String(reason.prefix(300)), updatedAt: stamp))
                        }
                        func songFailure(_ number: Int) {
                            restrictions[number].failStreak += 1
                            // Health cooldown only when another source can continue; a sole
                            // provider keeps searching every song independently.
                            if runProviders.count > 1 && restrictions[number].failStreak >= 3 {
                                restrictions[number].failStreak = 0
                                restrictions[number].retryAt = clock.now.advanced(by: restriction.healthCooldown)
                            }
                        }
                        func attempt(_ number: Int) async throws {
                            let name = runProviders[number].discoveryName, started = clock.now
                            attempted = true; attemptedProviders.insert(number)
                            do {
                                let found = try await runProviders[number].discover(entry.source)
                                try Task.checkCancellation()
                                report.record(name, seconds: started.duration(to: clock.now), failed: found.searchFailed)
                                let providerWide = found.pauseDiscovery && MatchingDiscoveryFailurePolicy.immediate(found.failure)
                                if found.searchFailed { report.discoveryFailedRequests += 1 } else { report.externalSucceeded += 1 }
                                truncated = truncated || found.truncated
                                for recording in found.recordings.prefix(20) {
                                    let identity = recording.provider + ":" + recording.identity
                                    guard !rejected.contains(identity), seen.insert(identity).inserted else { continue }
                                    scores.append(scoring.score(source: entry.source, candidate: recording))
                                }
                                if found.failure == .networkUnavailable { sawConnectivityFailure = true } else { connectivityOnly = false }
                                if found.failures.isEmpty {
                                    restrictions[number] = ProviderHealth()
                                    let healthy = runProviders[number].discoveryName
                                    if cooling.remove(healthy) != nil { cooldownWrites[healthy] = .some(nil) }
                                    if !found.recordings.isEmpty { foundCandidates = true }
                                    return
                                }
                                failedAny = true
                                let reason = found.failure == .accessRestricted && found.pauseDiscovery
                                    ? "YouTube search requires access or verification."
                                    : found.failure?.localizedDescription ?? "Discovery is unavailable."
                                issue = (runProviders.count > 1 ? name + ": " : "") + reason + " Discovery incomplete; saved candidates are preserved. Retry later."
                                report.message = issue
                                if let failure = found.failure {
                                    MatchingDiagnostics.record(failure, session: migrationID, entry: entry.id, stage: "discovery", provider: name)
                                }
                                if providerWide { escalate(number, reason, retryAfter: found.retryAfter) }
                                else if found.searchFailed && found.failure != .networkUnavailable { songFailure(number) }
                            } catch {
                                if Task.isCancelled || error is CancellationError { throw CancellationError() }
                                MatchingDiagnostics.record(error, session: migrationID, entry: entry.id, stage: "discovery", provider: name)
                                report.record(name, seconds: started.duration(to: clock.now), failed: true)
                                failedAny = true
                                report.discoveryFailedRequests += 1
                                let reason = (error as? YouTubeError) == .accessRestricted
                                    ? "YouTube search requires access or verification."
                                    : (error as? YouTubeError)?.localizedDescription ?? "Discovery is unavailable."
                                issue = (runProviders.count > 1 ? name + ": " : "") + reason + " Discovery incomplete; saved candidates are preserved. Retry later."
                                report.message = issue
                                let offline = (error as? YouTubeError) == .networkUnavailable
                                if offline { sawConnectivityFailure = true } else { connectivityOnly = false }
                                if MatchingDiscoveryFailurePolicy.immediate(error as? YouTubeError) { escalate(number, reason) }
                                else if !offline { songFailure(number) }
                            }
                        }
                        // Pass 1: sources in preference order. A cooling source is skipped,
                        // never waited on, while another source can serve this occurrence.
                        for number in runProviders.indices {
                            try Task.checkCancellation()
                            if restrictions[number].suspended { continue }
                            if let until = restrictions[number].retryAt, clock.now < until {
                                skipped.insert(number); report.recordSkip(runProviders[number].discoveryName); continue
                            }
                            try await attempt(number)
                            await flushCooldowns()
                            if foundCandidates { break }
                        }
                        // Durable mode: a long restriction is never waited out while holding the
                        // single worker. The song is deferred and resumed after the deadline.
                        if !attempted, let limit = restriction.inlineWaitLimit, cooldowns != nil,
                           let number = skipped.min(by: { (restrictions[$0].retryAt ?? clock.now) < (restrictions[$1].retryAt ?? clock.now) }),
                           clock.now.duration(to: restrictions[number].retryAt ?? clock.now) > limit {
                            for value in skipped { restrictions[value].suspended = true }
                            skipped.removeAll()
                        }
                        // Pass 2: every usable source is cooling down. Respect the restriction:
                        // wait for the earliest one, then make one fresh search for THIS occurrence.
                        if !attempted, let number = skipped.min(by: { (restrictions[$0].retryAt ?? clock.now) < (restrictions[$1].retryAt ?? clock.now) }) {
                            report.message = "Discovery sources requested verification or limited requests. Waiting before the next independent search."
                            await progress(report)
                            try await restriction.sleep(max(.zero, clock.now.duration(to: restrictions[number].retryAt ?? clock.now)))
                            try await attempt(number)
                            await flushCooldowns()
                        }
                        report.discoveryPaused = !providers.isEmpty && runProviders.indices.allSatisfy { restrictions[$0].suspended }
                        if attempted { report.externalAttempted += 1 }
                        let offline = failedAny && !foundCandidates && connectivityOnly && sawConnectivityFailure
                        connectivityStreak = offline ? connectivityStreak + 1 : (attempted ? 0 : connectivityStreak)
                        if foundCandidates {
                            issue = nil // An earlier source failed, but a later one completed discovery.
                        } else if offline {
                            // Lost connectivity (e.g. while locked/suspended) is not a song failure:
                            // the song stays unfinished and an ordinary resume searches it again.
                            deferred = true; discoveryFailed = true
                            issue = "External discovery deferred. Waiting for an internet connection."
                        } else if !providers.isEmpty && !attempted {
                            deferred = true; discoveryFailed = true
                            issue = "External discovery deferred. " + (restrictions.first { $0.suspended }?.reason ?? "No discovery source is enabled.")
                                + " Local matching completed; retry unfinished discovery later."
                        } else if failedAny || !skipped.subtracting(attemptedProviders).isEmpty {
                            discoveryFailed = true
                            if issue == nil { issue = "A fallback discovery source was cooling down and was skipped. Retry later." }
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
                // One occurrence never stops the job; only cancellation, fatal storage/session
                // failures, or a lost connection (saved as unfinished) end the loop.
                if wasUnfinished { report.processed += 1 }
                if ContinuousClock.now - lastRefresh > .seconds(2) {
                    // Coalesced: correct counters for re-searched songs from persisted state.
                    var fresh = try await repository.matchingSummary(migrationID: migrationID)
                    fresh.providerStats = report.providerStats; fresh.discoveryPaused = report.discoveryPaused
                    fresh.message = report.message
                    report = fresh; lastRefresh = .now
                }
                await progress(report)
                if connectivityStreak >= 3 { report.waitingForConnection = true; break }
            }
            await flushCooldowns()
            lastClaimed = claimed
            MatchingDiagnostics.run(session: migrationID, claimed: claimed, skippedCompleted: skippedCompleted,
                                    retryFailed: retryFailed, offline: report.waitingForConnection)
            try Task.checkCancellation()
            try await repository.finishMatching(session, paused: report.discoveryPaused || report.waitingForConnection)
            var final = try await repository.matchingSummary(migrationID: migrationID)
            final.waitingForConnection = report.waitingForConnection; final.providerStats = report.providerStats
            if final.discoveryPaused == false { final.discoveryPaused = report.discoveryPaused }
            lastReport = final
            await progress(final)
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

extension Duration {
    /// Seconds as a floating-point value (cooldown deadlines are stored as wall-clock dates).
    var matchingSeconds: TimeInterval { Double(components.seconds) + Double(components.attoseconds) / 1e18 }
}
