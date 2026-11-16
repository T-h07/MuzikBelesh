import Combine
import Foundation
import GRDB

/// Phase 10.6. The single, application-scoped owner of migration lifecycle decisions:
/// what is eligible, when it runs, in which order, and what happens after restarts,
/// connectivity changes, resource restrictions, provider cooldowns, background
/// expiration and user Pause/Resume/Cancel.
///
/// It triggers existing services and never duplicates them:
/// * `PlaylistMigrationMatchingService` remains the matching engine (local-first,
///   discovery, leases, atomic commits).
/// * `PlaylistMatchingViewModel` executes the chosen unit of work under one iOS execution
///   grant and presents progress (its pause/cancel/expiration semantics are unchanged).
/// * `PlaylistAcquisitionCoordinator` remains responsible for confirmed-recording
///   acquisition, consumer accounting and verified association.
/// * `DownloadManager` remains the single owner of download jobs and transfers.
/// * SQLite is authoritative. In-memory state here is a cache and accounting only;
///   a process restart is ordinary recovery, never a reason to start again.
@MainActor final class PlaylistMigrationCoordinator: ObservableObject, MatchingScheduling {
    struct Configuration: Sendable {
        /// Occurrences per matching slice; the scheduler may rotate playlists between slices.
        var sliceSize = 40
        var retry = MigrationRetryPolicy.standard
        /// Backoff after the engine itself detected lost connectivity.
        var networkBackoff: TimeInterval = 60
        var refreshDebounce: Duration = .milliseconds(500)
        /// Upper bound on waiting for background-transfer inventory reconciliation at launch.
        var reconciliationWait: Duration = .seconds(10)
        static let standard = Configuration()
    }

    private struct PassProgress { var claimed = 0; var eligibleAtStart = Int.max }

    /// Coherent, derived per-migration status for the UI (published at a bounded cadence).
    @Published private(set) var statuses: [UUID: MigrationCoordinatorStatus] = [:]

    let repository: MigrationCoordinatorRepository
    let matching: PlaylistMatchingViewModel
    private let migrations: GRDBPlaylistMigrationRepository
    private let service: PlaylistMigrationMatchingService
    private let acquisition: PlaylistAcquisitionCoordinator?
    private let downloads: DownloadManager?
    let configuration: Configuration
    private let now: () -> Date
    private let sleep: @Sendable (Duration) async throws -> Void

    private(set) var foreground = true
    private(set) var network = NetworkPathSnapshot()
    private(set) var resourcePolicy = ResourcePolicy()
    private var started = false
    private var invalidated = false
    private var recovering = false
    private var restoreTask: Task<Void, Never>?
    private var refreshTask: Task<Void, Never>?
    private var wakeTask: Task<Void, Never>?
    private var observation: (any DatabaseCancellable)?
    private var subscriptions = Set<AnyCancellable>()
    private var passes: [UUID: PassProgress] = [:]
    private var cancelling = Set<UUID>()
    private var itemStarts: [UUID: Date] = [:]
    /// Monotonic service order for round-robin fairness within this process (wall-clock
    /// `lastScheduledAt` orders migrations after a restart).
    private var served: [UUID: Int] = [:]
    private var serveCounter = 0
    private var providerNames: [String] = []

    // Diagnostics (also read by deterministic tests).
    private(set) var scheduledItems = 0
    private(set) var refreshes = 0
    private(set) var recoveryConflicts = 0
    private(set) var restorations = 0

    init(repository: MigrationCoordinatorRepository, migrations: GRDBPlaylistMigrationRepository, matching: PlaylistMatchingViewModel,
         service: PlaylistMigrationMatchingService, acquisition: PlaylistAcquisitionCoordinator?, downloads: DownloadManager?,
         configuration: Configuration = .standard, foreground: Bool = true, now: @escaping () -> Date = Date.init,
         sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }) {
        self.repository = repository; self.migrations = migrations; self.matching = matching; self.service = service
        self.acquisition = acquisition; self.downloads = downloads; self.configuration = configuration
        self.foreground = foreground; self.now = now; self.sleep = sleep
    }

    // MARK: Startup and recovery

    /// Startup sequence (after storage, the library, DownloadManager and acquisition):
    /// wait for background-transfer ownership, subscribe to connectivity and resource
    /// policy, then restore persisted intent and schedule eligible work.
    func start() async {
        guard !started, !invalidated else { return }
        started = true
        matching.scheduler = self
        // A launch into the background (e.g. for a finished transfer) starts no new work.
        if !foreground { matching.setForeground(false) }
        if let downloads {
            network = downloads.networkPath
            resourcePolicy = downloads.resourcePolicy
            // Never race the background URLSession inventory restoration.
            let deadline = ContinuousClock.now.advanced(by: configuration.reconciliationWait)
            while downloads.reconciling && ContinuousClock.now < deadline && !invalidated {
                try? await Task.sleep(for: .milliseconds(20))
            }
            downloads.$networkPath.dropFirst().removeDuplicates().sink { [weak self] path in
                Task { @MainActor in await self?.networkDidChange(path) }
            }.store(in: &subscriptions)
            downloads.$resourcePolicy.dropFirst().removeDuplicates().sink { [weak self] policy in
                Task { @MainActor in await self?.resourcePolicyDidChange(policy) }
            }.store(in: &subscriptions)
        }
        providerNames = await service.enabledProviderNames()
        // Committed decisions, intent, links and job states change derived status. The
        // coordinator's own tables are not observed, so refreshes converge.
        observation = DatabaseRegionObservation(tracking: Table("migration_entries").all(), Table("migration_acquisitions").all(),
                                                Table("migration_matching_jobs").all(), Table("playlist_migrations").all(), Table("download_jobs").all())
            .start(in: repository.db, onError: { error in CoordinatorDiagnostics.failure(error, stage: "observe", migration: nil) },
                   onChange: { [weak self] _ in Task { @MainActor in self?.scheduleRefresh() } })
        await restoreUnfinishedMigrations()
    }

    /// Idempotent; overlapping calls join one pass. Abandoned app-owned matching work is
    /// recovered only while no worker exists in this process (so a live run is never
    /// reclaimed). OS-owned transfers are reconciled by DownloadManager, not here.
    func restoreUnfinishedMigrations() async {
        guard started, !invalidated else { return }
        if let restoreTask { await restoreTask.value; return }
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            if !matching.busy {
                recovering = true
                do {
                    let recovered = try await repository.recoverAbandonedWork(now: now())
                    restorations += 1
                    CoordinatorDiagnostics.event("migrationRestored", ["recoveredSessions": String(recovered.count), "launchRecovery": String(restorations)])
                } catch { CoordinatorDiagnostics.failure(error, stage: "restore", migration: nil) }
                recovering = false
            }
            requestAcquisitionReconciliation()
            await refresh()
            await ensureWorker()
            scheduleWake()
        }
        restoreTask = task
        await task.value
        restoreTask = nil
    }

    /// Stops this instance as process termination would. Persisted state is left for the
    /// next instance; the matching worker is cancelled without writing intent.
    func invalidate() async {
        guard !invalidated else { return }
        invalidated = true
        observation?.cancel(); observation = nil
        subscriptions.removeAll()
        refreshTask?.cancel(); refreshTask = nil
        wakeTask?.cancel(); wakeTask = nil
        await matching.abandon()
    }

    func reconcileAll() async {
        guard started, !invalidated else { return }
        await refresh()
        await ensureWorker()
        scheduleWake()
    }

    func reconcileMigration(_ migrationID: UUID) async { await reconcileAll() }

    func status(for migrationID: UUID) -> MigrationCoordinatorStatus? { statuses[migrationID] }

    // MARK: Lifecycle, network and resources

    func applicationDidBecomeActive() async {
        foreground = true
        matching.setForeground(true)
        requestAcquisitionReconciliation()
        await refresh()
        await ensureWorker()
        scheduleWake()
    }

    /// Timers do not run while iOS suspends the app; deadlines are wall-clock values in
    /// SQLite and are honored on the next activation.
    func applicationDidEnterBackground() async {
        foreground = false
        matching.setForeground(false)
        wakeTask?.cancel(); wakeTask = nil
        await refresh()
    }

    func networkDidChange(_ path: NetworkPathSnapshot) async {
        guard !invalidated else { return }
        let regained = path.connected && (!network.known || !network.connected)
        let lost = path.known && !path.connected && (!network.known || network.connected)
        network = path
        if lost { CoordinatorDiagnostics.event("networkWaitEntered") }
        if regained {
            let cleared = (try? await repository.clearNetworkWaits(now: now())) ?? 0
            CoordinatorDiagnostics.event("networkWaitCleared", ["migrations": String(cleared)])
            requestAcquisitionReconciliation()
            await ensureWorker()
        }
        scheduleRefresh()
    }

    func resourcePolicyDidChange(_ policy: ResourcePolicy) async {
        guard !invalidated else { return }
        let wasDeferred = resourcePolicy.defersNewWork
        resourcePolicy = policy
        if policy.defersNewWork && !wasDeferred {
            CoordinatorDiagnostics.event("resourceDeferralEntered", ["thermal": policy.thermalLabel, "lowPower": String(policy.lowPower)])
        }
        if wasDeferred && !policy.defersNewWork {
            CoordinatorDiagnostics.event("resourceDeferralCleared")
            await ensureWorker()
        }
        scheduleRefresh()
    }

    // MARK: User commands

    func startMigration(_ migrationID: UUID) async throws {
        guard let session = try await migrations.session(id: migrationID), !session.status.isTerminal else {
            throw PlaylistMigrationFoundationError.illegalSessionTransition
        }
        try await migrations.setMatchingIntent(migrationID, intent: "running")
        matching.presentIntent(migrationID, "running")
        try await repository.updateState(migrationID, now: now()) { record in
            record.state = .matching; record.cursorPosition = -1; record.reason = nil; record.waitUntil = nil
        }
        passes[migrationID] = nil
        CoordinatorDiagnostics.event("migrationScheduled", migration: migrationID)
        await ensureWorker()
        scheduleRefresh()
    }

    /// Resume Matching (matching only). Same durable effect as starting it.
    func resumeMatching(_ migrationID: UUID) async throws { try await startMigration(migrationID) }

    /// Pause Matching (matching only; downloads are governed by their own Pause).
    func pauseMatching(_ migrationID: UUID) async throws {
        try await migrations.setMatchingIntent(migrationID, intent: "userPaused")
        matching.presentIntent(migrationID, "userPaused")
        if matching.busy && matching.activeID == migrationID { matching.pause(); await matching.waitForCompletion() }
        try await repository.updateState(migrationID, now: now()) { $0.state = .userPaused; $0.reason = "Paused by user"; $0.generation = nil }
        CoordinatorDiagnostics.event("migrationPaused", migration: migrationID, ["scope": "matching"])
        scheduleRefresh()
    }

    /// Pause Playlist: intent is persisted (matching and downloads, one transaction)
    /// before anything else; then the worker stops cooperatively and playlist-only
    /// downloads pause. Other playlists and shared downloads are unaffected.
    func pauseMigration(_ migrationID: UUID) async throws {
        try await repository.pause(migrationID: migrationID, now: now())
        matching.presentIntent(migrationID, "userPaused")
        if matching.busy && matching.activeID == migrationID { matching.pause(); await matching.waitForCompletion() }
        await acquisition?.pause(migrationID: migrationID.uuidString)
        CoordinatorDiagnostics.event("migrationPaused", migration: migrationID, ["scope": "playlist"])
        await refresh()
        await ensureWorker()
    }

    func resumeMigration(_ migrationID: UUID) async throws {
        try await repository.resume(migrationID: migrationID, now: now())
        if let intent = try await migrations.matchingIntent(migrationID) { matching.presentIntent(migrationID, intent) }
        passes[migrationID] = nil
        await acquisition?.continueDownloads(migrationID: migrationID.uuidString)
        CoordinatorDiagnostics.event("migrationResumed", migration: migrationID)
        await refresh()
        await ensureWorker()
        scheduleWake()
    }

    /// Cancel: further matching and automatic acquisition stop for this migration and
    /// it never resumes automatically. Existing library tracks, audio files, verified
    /// occurrences, the destination playlist and shared downloads other consumers need
    /// are preserved (acquisition consumer accounting decides what may be paused).
    func cancelMigration(_ migrationID: UUID) async throws {
        cancelling.insert(migrationID)
        defer { cancelling.remove(migrationID) }
        try? await repository.updateState(migrationID, now: now()) { $0.state = .cancelling; $0.reason = "Cancelling" }
        if matching.busy && matching.activeID == migrationID { matching.cancel(); await matching.waitForCompletion() }
        try await repository.cancel(migrationID: migrationID, now: now())
        matching.presentIntent(migrationID, "userCancelled")
        passes[migrationID] = nil
        CoordinatorDiagnostics.event("migrationCancelled", migration: migrationID)
        requestAcquisitionReconciliation()
        await acquisition?.reconcileNow()
        await refresh()
        await ensureWorker()
    }

    /// Retry This Song: explicit, resets the automatic budget, honored on the next slice.
    func retryEntry(_ migrationID: UUID, entryID: UUID) async throws {
        try await migrations.markRetryable(entryID: entryID)
        try await prepareExplicitRetry(migrationID)
        try await repository.scheduleExplicitRetry([entryID], migrationID: migrationID, now: now())
        if let link = acquisition?.link(for: entryID), link.state == .failed { await acquisition?.retry(entryID: entryID) }
        await ensureWorker()
        scheduleRefresh()
    }

    /// Retry songs whose search or download failed (explicit; bounded automatic retries
    /// start again from zero).
    func retryFailedEntries(_ migrationID: UUID) async throws {
        let ids = try await repository.retryableFailures(migrationID: migrationID)
        try await prepareExplicitRetry(migrationID)
        try await repository.scheduleExplicitRetry(ids, migrationID: migrationID, now: now())
        await acquisition?.retryFailed(migrationID: migrationID.uuidString)
        CoordinatorDiagnostics.event("retryScheduled", migration: migrationID, ["explicit": String(ids.count)])
        await ensureWorker()
        scheduleRefresh()
    }

    /// A `fatal` intent only changes through an explicit supported action.
    private func prepareExplicitRetry(_ migrationID: UUID) async throws {
        if try await migrations.matchingIntent(migrationID) == "fatal" {
            try await migrations.setMatchingIntent(migrationID, intent: "completed")
            matching.presentIntent(migrationID, "completed")
        }
        try await repository.updateState(migrationID, now: now()) { record in
            if record.state == .waitingForNetwork { record.waitUntil = nil }
        }
    }

    // MARK: MatchingScheduling

    func nextMatchingWork() async -> MatchingWorkItem? {
        guard started, !invalidated, !recovering else { return nil }
        if resourcePolicy.defersNewWork { scheduleRefresh(); return nil }
        if network.known && !network.connected { scheduleRefresh(); return nil }
        let stamp = now()
        let overview: [MigrationOverview]
        do { overview = try await repository.overview(algorithm: CandidateScoringEngine.algorithmVersion, now: stamp) }
        catch { CoordinatorDiagnostics.failure(error, stage: "schedule", migration: nil); return nil }
        let cooldowns = (try? await repository.providerCooldowns()) ?? [:]
        let allCooling = !providerNames.isEmpty && providerNames.allSatisfy { (cooldowns[$0]?.expiresAt ?? .distantPast) > stamp }
        var candidates: [(MigrationOverview, MatchingWorkItem.Kind)] = []
        for value in overview where value.schedulable && !value.cancelled && !cancelling.contains(value.migrationID) {
            let intent = value.intent
            if value.state?.waitUntil.map({ $0 > stamp }) ?? false { continue }
            let retriesAllowed = !["userPaused", "userCancelled", "fatal"].contains(intent ?? "")
            if retriesAllowed && !allCooling && value.dueRetries > 0 { candidates.append((value, .retry)); continue }
            if ["running", "systemPaused"].contains(intent ?? ""), value.eligible > 0 { candidates.append((value, .ordinary)) }
        }
        // Fairness: least recently served first; ties by import order (never dictionary order).
        candidates.sort { lhs, rhs in
            let ls = served[lhs.0.migrationID] ?? -1, rs = served[rhs.0.migrationID] ?? -1
            if ls != rs { return ls < rs }
            let l = lhs.0.state?.lastScheduledAt ?? .distantPast, r = rhs.0.state?.lastScheduledAt ?? .distantPast
            if l != r { return l < r }
            if lhs.0.createdAt != rhs.0.createdAt { return lhs.0.createdAt < rhs.0.createdAt }
            return lhs.0.migrationID.uuidString < rhs.0.migrationID.uuidString
        }
        for (value, kind) in candidates {
            if let item = await makeItem(value, kind: kind, now: stamp) {
                serveCounter += 1; served[value.migrationID] = serveCounter
                return item
            }
        }
        scheduleRefresh()
        return nil
    }

    private func makeItem(_ value: MigrationOverview, kind: MatchingWorkItem.Kind, now stamp: Date) async -> MatchingWorkItem? {
        let id = value.migrationID, generation = UUID()
        do {
            switch kind {
            case .retry:
                let ids = try await repository.dueRetries(migrationID: id, now: stamp, limit: configuration.sliceSize, automatic: true)
                guard !ids.isEmpty else { return nil }
                try await repository.claimRetries(ids, now: stamp, lease: stamp.addingTimeInterval(configuration.retry.maximumDelay))
                try await repository.beginRun(id, generation: generation, cursorReset: false, now: stamp)
                record(generation)
                CoordinatorDiagnostics.event("matchingJobClaimed", migration: id, ["kind": "retry", "occurrences": String(ids.count)])
                return MatchingWorkItem(migrationID: id, only: Set(ids), retryFailed: true, generation: generation, kind: .retry,
                                        sliceEnd: nil, previousIntent: value.intent)
            case .ordinary:
                var cursor = value.state?.cursorPosition ?? -1
                var slice = try await repository.nextSlice(migrationID: id, after: cursor, limit: configuration.sliceSize,
                                                           algorithm: CandidateScoringEngine.algorithmVersion)
                if slice.isEmpty && cursor >= 0 {
                    // A restart or reset left eligible work before the cursor: new pass.
                    cursor = -1
                    slice = try await repository.nextSlice(migrationID: id, after: -1, limit: configuration.sliceSize,
                                                           algorithm: CandidateScoringEngine.algorithmVersion)
                }
                guard let last = slice.last else { return nil }
                if cursor < 0 { passes[id] = PassProgress(claimed: 0, eligibleAtStart: value.eligible) }
                try await repository.beginRun(id, generation: generation, cursorReset: cursor < 0, now: stamp)
                record(generation)
                CoordinatorDiagnostics.event("matchingJobClaimed", migration: id, ["kind": "ordinary", "occurrences": String(slice.count),
                    "from": String(slice.first?.position ?? -1), "to": String(last.position)])
                return MatchingWorkItem(migrationID: id, only: Set(slice.map(\.id)), retryFailed: false, generation: generation, kind: .ordinary,
                                        sliceEnd: last.position, previousIntent: value.intent)
            }
        } catch {
            CoordinatorDiagnostics.failure(error, stage: "claim", migration: id)
            return nil
        }
    }

    private func record(_ generation: UUID) {
        scheduledItems += 1
        itemStarts[generation] = Date()
        if itemStarts.count > 64 { itemStarts.removeAll() } // Bounded; only the current item matters.
    }

    func intentAfterRun(_ migrationID: UUID, item: MatchingWorkItem?, report: SongMatchingProgress, startedAt: Date) async -> String {
        let stamp = now()
        let previous = (try? await migrations.matchingIntent(migrationID)) ?? "running"
        // Retry bookkeeping for every occurrence this run attempted (also direct commands).
        if let outcome = try? await repository.recordOutcomes(migrationID: migrationID, since: startedAt, policy: configuration.retry, now: stamp),
           outcome.scheduled + outcome.exhausted > 0 {
            CoordinatorDiagnostics.event("retryScheduled", migration: migrationID, ["scheduled": String(outcome.scheduled), "exhausted": String(outcome.exhausted)])
        }
        let claimed = await service.lastClaimed
        let eligible = (try? await repository.eligibleCount(migrationID: migrationID, algorithm: CandidateScoringEngine.algorithmVersion)) ?? 0
        guard let item else {
            // A direct command (no coordinator item): settle by the remaining work.
            if report.waitingForConnection { return "systemPaused" }
            return eligible > 0 && ["running", "systemPaused"].contains(previous) ? "running" : "completed"
        }
        itemStarts[item.generation] = nil
        guard let state = try? await repository.state(migrationID), state.generation == item.generation.uuidString else {
            recoveryConflicts += 1
            CoordinatorDiagnostics.conflict("staleCompletion", migration: migrationID, ["generation": item.generation.uuidString])
            return previous
        }
        let generation = item.generation
        if report.waitingForConnection {
            let until = stamp.addingTimeInterval(configuration.networkBackoff)
            _ = try? await repository.endRun(migrationID, generation: generation, now: stamp) { record in
                record.state = .waitingForNetwork; record.waitUntil = until; record.reason = "Waiting for connection"
                record.errorCategory = MigrationFailureCategory.networkUnavailable.rawValue
            }
            CoordinatorDiagnostics.event("networkWaitEntered", migration: migrationID)
            return "systemPaused"
        }
        switch item.kind {
        case .retry:
            _ = try? await repository.endRun(migrationID, generation: generation, now: stamp) { $0.errorCategory = nil }
            CoordinatorDiagnostics.event("matchingJobCompleted", migration: migrationID, ["kind": "retry", "claimed": String(claimed)])
            let previousIntent = item.previousIntent ?? "completed"
            return eligible > 0 && ["running", "systemPaused"].contains(previousIntent) ? "running" : "completed"
        case .ordinary:
            var pass = passes[migrationID] ?? PassProgress()
            pass.claimed += claimed
            let sliceEnd = item.sliceEnd ?? -1
            let more = !((try? await repository.nextSlice(migrationID: migrationID, after: sliceEnd, limit: 1,
                                                         algorithm: CandidateScoringEngine.algorithmVersion)) ?? []).isEmpty
            if more {
                passes[migrationID] = pass
                _ = try? await repository.endRun(migrationID, generation: generation, now: stamp) { $0.cursorPosition = sliceEnd; $0.errorCategory = nil }
                CoordinatorDiagnostics.event("matchingJobCompleted", migration: migrationID, ["kind": "ordinary", "claimed": String(claimed), "cursor": String(sliceEnd)])
                return "running"
            }
            // The pass is complete.
            passes[migrationID] = nil
            let cooldowns = (try? await repository.providerCooldowns()) ?? [:]
            let coolingUntil = providerNames.compactMap { cooldowns[$0]?.expiresAt }.filter { $0 > stamp }.min()
            let intent: String
            if eligible == 0 {
                intent = "completed"
                _ = try? await repository.endRun(migrationID, generation: generation, now: stamp) { $0.cursorPosition = -1; $0.waitUntil = nil; $0.errorCategory = nil }
            } else if let coolingUntil {
                // Deferred by a provider restriction: resume after the deadline, durably.
                intent = "running"
                _ = try? await repository.endRun(migrationID, generation: generation, now: stamp) { record in
                    record.cursorPosition = -1; record.state = .coolingDown; record.waitUntil = coolingUntil
                    record.reason = "Search temporarily limited"; record.errorCategory = MigrationFailureCategory.rateLimited.rawValue
                }
            } else if pass.claimed > 0 && eligible < pass.eligibleAtStart {
                // Progress was made but earlier occurrences became eligible again: one more pass.
                intent = "running"
                _ = try? await repository.endRun(migrationID, generation: generation, now: stamp) { $0.cursorPosition = -1 }
            } else {
                // No further progress is possible automatically (e.g. no source enabled).
                intent = "completed"
                _ = try? await repository.endRun(migrationID, generation: generation, now: stamp) { $0.cursorPosition = -1 }
            }
            CoordinatorDiagnostics.event("matchingJobCompleted", migration: migrationID, ["kind": "pass", "claimed": String(pass.claimed),
                "remaining": String(eligible), "intent": intent])
            return intent
        }
    }

    func matchingWorkerDidStop(_ migrationID: UUID?, reason: MatchingFailureCategory?) {
        guard !invalidated else { return }
        if let migrationID, let reason {
            let stamp = now()
            let interrupted = reason == .interrupted
            if interrupted { CoordinatorDiagnostics.event("backgroundExecutionExpired", migration: migrationID) }
            let since = itemStarts.values.max()
            let policy = configuration.retry
            Task { [repository] in
                if let since { _ = try? await repository.recordOutcomes(migrationID: migrationID, since: since, policy: policy, now: stamp) }
                try? await repository.updateState(migrationID, now: stamp) { record in
                    record.generation = nil
                    switch reason {
                    case .interrupted: record.state = .systemSuspended; record.interruptedBySystem = true
                        record.errorCategory = MigrationFailureCategory.backgroundExpired.rawValue
                    case .userPaused: record.state = .userPaused; record.reason = "Paused by user"
                    case .cancelled: break
                    default: record.state = .failed; record.errorCategory = MigrationFailureCategory.storage.rawValue
                    }
                }
            }
        }
        scheduleRefresh()
        // One playlist pausing or cancelling never stops the others.
        if reason == .userPaused || reason == .cancelled { Task { await self.ensureWorker() } }
        scheduleWake()
    }

    // MARK: Worker, timers and presentation

    /// Starts the single matching worker when eligible work exists. Only in the
    /// foreground: background work continues solely under an existing iOS grant.
    func ensureWorker() async {
        guard started, !invalidated, foreground, !recovering, !matching.busy else { return }
        await matching.restoreIfNeeded()
    }

    private func requestAcquisitionReconciliation() {
        guard let acquisition else { return }
        CoordinatorDiagnostics.event("acquisitionReconciliationRequested")
        acquisition.requestReconcile(immediately: true)
    }

    private func scheduleRefresh() {
        guard started, !invalidated, refreshTask == nil else { return }
        let delay = configuration.refreshDebounce
        refreshTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard let self, !Task.isCancelled else { return }
            self.refreshTask = nil
            await self.refresh()
        }
    }

    /// One aggregate read; publishes only when something changed and persists derived
    /// lifecycle transitions in one transaction.
    func refresh() async {
        guard started, !invalidated else { return }
        refreshes += 1
        let stamp = now()
        guard let overview = try? await repository.overview(algorithm: CandidateScoringEngine.algorithmVersion, now: stamp) else { return }
        let cooldowns = (try? await repository.providerCooldowns()) ?? [:]
        let coolingUntil = providerNames.compactMap { cooldowns[$0]?.expiresAt }.filter { $0 > stamp }.min()
        var next: [UUID: MigrationCoordinatorStatus] = [:]
        var changes: [UUID: (MigrationLifecycleState, String?)] = [:]
        for value in overview {
            let active = matching.busy && matching.activeID == value.migrationID
            let derived = Self.derive(value, active: active, foreground: foreground, network: network, policy: resourcePolicy,
                                      now: stamp, coolingUntil: coolingUntil)
            next[value.migrationID] = MigrationCoordinatorStatus(state: derived.state, progress: Self.progress(value),
                                                                 waitUntil: derived.waitUntil, isActive: active, message: derived.message)
            let stored = value.state?.state
            if stored != derived.state && !(stored == nil && derived.state == .pending) {
                changes[value.migrationID] = (derived.state, derived.message)
                if derived.state == .completed { CoordinatorDiagnostics.event("migrationCompleted", migration: value.migrationID, ["total": String(value.total)]) }
                if derived.state == .resourceDeferred { CoordinatorDiagnostics.event("resourceDeferralEntered", migration: value.migrationID) }
            }
        }
        if next != statuses { statuses = next }
        if !changes.isEmpty, !invalidated {
            do { try await repository.setLifecycle(changes, now: stamp) }
            catch { CoordinatorDiagnostics.failure(error, stage: "persist-state", migration: nil) }
        }
    }

    /// Wakes for the earliest persisted deadline (cooldown, retry, connectivity backoff)
    /// while in the foreground. Deadlines survive suspension because they are stored.
    private func scheduleWake() {
        wakeTask?.cancel(); wakeTask = nil
        guard started, !invalidated, foreground else { return }
        let sleep = sleep
        wakeTask = Task { [weak self] in
            guard let self else { return }
            let stamp = self.now()
            guard let overview = try? await self.repository.overview(algorithm: CandidateScoringEngine.algorithmVersion, now: stamp) else { return }
            let cooldowns = (try? await self.repository.providerCooldowns()) ?? [:]
            var deadlines = overview.compactMap { $0.state?.waitUntil }.filter { $0 > stamp }
            deadlines += overview.compactMap(\.nextRetryAt)
            deadlines += cooldowns.values.map(\.expiresAt).filter { $0 > stamp }
            guard let earliest = deadlines.min(), !Task.isCancelled else { return }
            let milliseconds = max(50, Int(earliest.timeIntervalSince(stamp) * 1000) + 10)
            do { try await sleep(.milliseconds(milliseconds)) } catch { return }
            guard !Task.isCancelled else { return }
            self.wakeTask = nil
            await self.reconcileAll()
        }
    }

    static func progress(_ value: MigrationOverview) -> MigrationCoordinatorProgress {
        MigrationCoordinatorProgress(total: value.total, matchingCompleted: max(0, value.total - value.unmatched), matchingRemaining: value.eligible,
            awaitingReview: value.review, confirmed: value.confirmed, queuedDownloads: value.linkWaitingQueued, downloading: value.linkDownloading,
            verifying: value.linkVerifying, availableOffline: value.ready, failedOrUnsupported: value.issues + value.acquisitionIssues,
            dueRetries: value.dueRetries)
    }

    /// Pure state machine over authoritative rows plus live conditions. "Matched",
    /// "confirmed", "downloaded", "verified" and "available offline" stay distinct:
    /// only verified, present local audio counts toward `completed`.
    static func derive(_ value: MigrationOverview, active: Bool, foreground: Bool, network: NetworkPathSnapshot, policy: ResourcePolicy,
                       now: Date, coolingUntil: Date?) -> (state: MigrationLifecycleState, message: String, waitUntil: Date?) {
        func result(_ state: MigrationLifecycleState, _ message: String? = nil, _ wait: Date? = nil)
            -> (state: MigrationLifecycleState, message: String, waitUntil: Date?) {
            (state: state, message: message ?? state.message, waitUntil: wait)
        }
        if value.cancelled { return result(.cancelled) }
        if value.state?.state == .cancelling { return result(.cancelling) }
        let intent = value.intent
        if intent == "fatal" { return result(.failed) }
        if intent == "userPaused" && value.eligible > 0 { return result(.userPaused) }
        if active { return result(.matching) }
        let matchingOpen = (["running", "systemPaused"].contains(intent ?? "") && value.eligible > 0)
            || (value.dueRetries > 0 && !["userPaused", "userCancelled"].contains(intent ?? ""))
        if matchingOpen {
            if network.known && !network.connected { return result(.waitingForNetwork) }
            if policy.defersNewWork { return result(.resourceDeferred) }
            if let wait = value.state?.waitUntil, wait > now {
                if value.state?.state == .waitingForNetwork { return result(.waitingForNetwork, nil, wait) }
                return result(.coolingDown, "Search provider cooling down", wait)
            }
            if let coolingUntil, value.state?.state == .coolingDown { return result(.coolingDown, "Search provider cooling down", coolingUntil) }
            if !foreground { return result(.systemSuspended) }
            return result(.matching, "Waiting to match")
        }
        if value.acquiringOpen > 0 || value.confirmed > 0 {
            if value.downloadsPaused { return result(.userPaused, "Downloads paused by you") }
            if network.known && !network.connected { return result(.acquiring, "Waiting for connection") }
            if policy.defersNewWork { return result(.acquiring, "Paused to protect the device") }
            if value.linkVerifying > 0 && value.linkDownloading == 0 { return result(.acquiring, "Verifying downloaded audio") }
            if value.linkDownloading == 0 && value.linkWaitingQueued > 0 { return result(.acquiring, "Waiting for available download slot") }
            return result(.acquiring)
        }
        if intent == nil && value.links == 0 { return result(.pending) }
        if value.total > 0 && value.ready == value.total { return result(.completed) }
        if value.review > 0 { return result(.awaitingReview) }
        return result(.completedWithIssues)
    }
}
