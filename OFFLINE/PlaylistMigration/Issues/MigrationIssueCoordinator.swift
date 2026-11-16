import Combine
import Foundation
import GRDB

/// Errors a recovery command reports to the user (never swallowed by the UI).
enum MigrationIssueCommandError: LocalizedError, Equatable {
    case alreadyRunning, unavailable, cancelled, notApplicable, changed
    var errorDescription: String? {
        switch self {
        case .alreadyRunning: "This song is already being updated."
        case .unavailable: "Recovery isn't available right now. Reopen the app and try again."
        case .cancelled: "This migration was cancelled. Use a local file or a song from your library instead."
        case .notApplicable: "That action no longer applies to this song."
        case .changed: "This song changed while you were looking at it. Review it again."
        }
    }
}

/// Outcome of Retry All Eligible Failures, counted from actual operations.
struct MigrationBulkRetryResult: Equatable, Sendable {
    var searches = 0
    var downloads = 0
    /// Unresolved songs not eligible for retry (they need review or another recording).
    var manual = 0
    var paused = false
    var message: String {
        let queued = searches + downloads
        var text = queued == 1 ? "1 song queued for retry." : "\(queued) songs queued for retry."
        if manual > 0 { text += manual == 1 ? " 1 still requires manual review." : " \(manual) still require manual review." }
        if paused && queued > 0 { text += " Retries start when you resume this playlist." }
        return text
    }
}

/// Phase 10.7. Reconciles authoritative migration state into persistent, classified
/// issue records, derives completion summaries and sends aggregate notifications.
///
/// It owns no scheduling: recovery commands are delegated to the existing owners —
/// `PlaylistMigrationCoordinator` for matching retries (Phase 10.6 scheduler, cooldowns,
/// pause and cancel), `PlaylistAcquisitionCoordinator` for download retries (which asks
/// `DownloadManager`, the sole owner of jobs), and `GRDBPlaylistMigrationRepository` for
/// candidate decisions and verified local-audio association. It never changes job
/// states or bypasses candidate verification.
@MainActor final class MigrationIssueCoordinator: ObservableObject {
    struct Configuration: Sendable {
        /// Coalesces bursts of database changes into one reconciliation.
        var debounce: Duration = .milliseconds(750)
        /// How long an attention notification may wait for the final confirmed-download
        /// batch notification it would otherwise duplicate.
        var batchWait: TimeInterval = 120
        /// Minimum spacing between attempts after a transient delivery failure.
        var deliveryBackoff: TimeInterval = 30
        static let standard = Configuration()
    }

    /// Per-migration summaries for badges and dashboards (keyed by migration ID).
    @Published private(set) var summaries: [UUID: MigrationCompletionSummary] = [:]
    @Published private(set) var reports: [UUID: MigrationIssueReport] = [:]
    @Published private(set) var states: [UUID: MigrationReportState] = [:]
    /// Occurrences with a recovery command in flight (buttons are disabled meanwhile).
    @Published private(set) var busyEntries: Set<UUID> = []
    @Published private(set) var lastError: String?
    /// Set when the user opens an attention notification.
    @Published var requestedIssuesPlaylistID: String?

    let repository: MigrationIssueRepository
    private let migrations: GRDBPlaylistMigrationRepository
    private let coordinator: PlaylistMigrationCoordinator?
    private let acquisition: PlaylistAcquisitionCoordinator?
    private let notifier: (any MigrationIssueNotifying)?
    private let configuration: Configuration
    private let now: () -> Date
    private let capacity: () -> Int64?
    private var observation: (any DatabaseCancellable)?
    private var pending: Task<Void, Never>?
    private var recheck: Task<Void, Never>?
    private var running = false
    private var rerun = false
    private var invalidated = false
    private var started = false

    // Diagnostics (also read by deterministic tests).
    private(set) var passes = 0
    private(set) var deliveryAttempts = 0

    init(repository: MigrationIssueRepository, migrations: GRDBPlaylistMigrationRepository, coordinator: PlaylistMigrationCoordinator?,
         acquisition: PlaylistAcquisitionCoordinator?, notifier: (any MigrationIssueNotifying)?, configuration: Configuration = .standard,
         now: @escaping () -> Date = Date.init, capacity: (() -> Int64?)? = nil) {
        self.repository = repository; self.migrations = migrations; self.coordinator = coordinator
        self.acquisition = acquisition; self.notifier = notifier; self.configuration = configuration; self.now = now
        let root = repository.paths.music
        self.capacity = capacity ?? {
            (try? root.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?.volumeAvailableCapacityForImportantUsage
        }
        // Installed during app initialization so a launch-causing tap is delivered.
        notifier?.onOpenIssues = { [weak self] playlistID in self?.requestedIssuesPlaylistID = playlistID }
    }

    // MARK: Lifecycle

    /// Observes the authoritative tables (never its own), then reconciles once.
    func start() async {
        guard !started, !invalidated else { return }
        started = true
        observation = DatabaseRegionObservation(tracking: Table("migration_entries").all(), Table("migration_candidates").all(),
            Table("migration_matching_checkpoints").all(), Table("migration_entry_retries").all(), Table("migration_acquisitions").all(),
            Table("migration_acquisition_controls").all(), Table("migration_matching_jobs").all(), Table("playlist_migrations").all(),
            Table("download_jobs").select(Column("state"), Column("errorMessage"), Column("trackID")))
            .start(in: repository.db, onError: { error in CoordinatorDiagnostics.failure(error, stage: "issue-observe", migration: nil) },
                   onChange: { [weak self] _ in Task { @MainActor in self?.requestReconcile() } })
        await reconcileNow()
    }

    func applicationDidBecomeActive() { requestReconcile(immediately: true) }

    func invalidate() async {
        guard !invalidated else { return }
        invalidated = true
        observation?.cancel(); observation = nil
        pending?.cancel(); pending = nil
        recheck?.cancel(); recheck = nil
        notifier?.onOpenIssues = nil
        while running { try? await Task.sleep(for: .milliseconds(10)) }
    }

    func requestReconcile(immediately: Bool = false) {
        guard !invalidated else { return }
        if running { rerun = true; return }
        guard pending == nil else { return }
        let delay = immediately ? Duration.zero : configuration.debounce
        pending = Task { [weak self] in
            if delay > .zero { try? await Task.sleep(for: delay) }
            guard let self, !Task.isCancelled else { return }
            self.pending = nil
            await self.reconcileNow()
        }
    }

    /// Runs (or joins) one idempotent pass over every migration.
    func reconcileNow() async {
        guard !invalidated else { return }
        if running { rerun = true; while running { try? await Task.sleep(for: .milliseconds(20)) }; return }
        running = true
        defer { running = false }
        repeat {
            rerun = false
            await pass()
            passes += 1
        } while rerun && !invalidated
    }

    private func pass() async {
        let stamp = now(), free = capacity()
        let ids: [UUID]
        do { ids = try await repository.migrationIDs() } catch { report(error); return }
        var nextSummaries: [UUID: MigrationCompletionSummary] = [:]
        var nextReports: [UUID: MigrationIssueReport] = [:]
        var nextStates: [UUID: MigrationReportState] = [:]
        var results: [MigrationIssueReconciliation] = []
        for id in ids {
            guard !invalidated else { return }
            do {
                guard let result = try await repository.reconcile(migrationID: id, now: stamp, capacity: free) else { continue }
                nextSummaries[id] = result.report.summary
                nextReports[id] = result.report
                nextStates[id] = result.state
                results.append(result)
                if result.opened + result.closed > 0 {
                    CoordinatorDiagnostics.event("issuesReconciled", migration: id, ["opened": String(result.opened), "closed": String(result.closed),
                        "attention": String(result.report.summary.attention), "outcome": result.report.summary.outcome.rawValue])
                }
            } catch { report(error) }
        }
        guard !invalidated else { return }
        if nextSummaries != summaries { summaries = nextSummaries }
        if nextReports != reports { reports = nextReports }
        if nextStates != states { states = nextStates }
        var earliest: Date?
        for result in results {
            if let date = await deliver(result, now: stamp) { earliest = min(earliest ?? date, date) }
        }
        scheduleRecheck(at: earliest)
    }

    // MARK: Presentation helpers

    func migrationID(forPlaylist playlistID: String) -> UUID? {
        summaries.first { $0.value.playlistID == playlistID }?.key
    }
    func summary(forPlaylist playlistID: String) -> MigrationCompletionSummary? {
        migrationID(forPlaylist: playlistID).flatMap { summaries[$0] }
    }
    func report(forPlaylist playlistID: String) -> MigrationIssueReport? {
        migrationID(forPlaylist: playlistID).flatMap { reports[$0] }
    }
    /// The settled completion summary has not been dismissed in the app for this cycle.
    func hasNewCompletion(_ migrationID: UUID) -> Bool {
        guard let state = states[migrationID], state.cycle > 0, state.settled else { return false }
        return state.presentedCycle < state.cycle
    }

    /// Hides the highlighted completion summary for the current cycle only.
    func dismissCompletion(_ migrationID: UUID) async {
        guard let cycle = states[migrationID]?.cycle else { return }
        do {
            try await repository.markPresented(migrationID: migrationID, cycle: cycle)
            if var state = states[migrationID] {
                state.presentedCycle = max(state.presentedCycle, cycle)
                states[migrationID] = state
            }
        } catch { report(error) }
    }

    // MARK: Recovery commands (delegated to the owning subsystem)

    /// Retry This Song / Retry Download for exactly one occurrence. Returns a message
    /// describing what was scheduled — never that it already succeeded.
    func retry(_ occurrence: MigrationOccurrenceReport) async throws -> String {
        let actions = occurrence.assessment.actions
        if actions.contains(.retryDownload) {
            guard let acquisition else { throw MigrationIssueCommandError.unavailable }
            return try await command(occurrence.id) {
                guard acquisition.link(for: occurrence.id)?.state == .failed else { throw MigrationIssueCommandError.notApplicable }
                await acquisition.retry(entryID: occurrence.id)
                return "Download queued for retry."
            }
        }
        guard actions.contains(.retrySong) else { throw MigrationIssueCommandError.notApplicable }
        guard let coordinator else { throw MigrationIssueCommandError.unavailable }
        let migrationID = occurrence.entry.migrationID
        return try await command(occurrence.id) {
            do { try await coordinator.retryEntry(migrationID, entryID: occurrence.id) }
            catch SongMatchingError.staleAttempt { throw MigrationIssueCommandError.changed }
            let paused = self.reports[migrationID]?.context.matchingPaused == true
            return paused ? "Search queued. It starts when you resume this playlist." : "Search queued for retry."
        }
    }

    /// Retry All Eligible Failures for one playlist. Only failures whose cause is
    /// temporary are queued; unsupported recordings, rejected candidates, completed songs
    /// and user Pause are respected. Matching retries run through the Phase 10.6
    /// scheduler (bounded slices, provider cooldowns); downloads through DownloadManager.
    func retryAllEligible(migrationID: UUID) async throws -> MigrationBulkRetryResult {
        await reconcileNow()
        guard let report = reports[migrationID] else { throw MigrationIssueCommandError.unavailable }
        guard !report.context.cancelled else { throw MigrationIssueCommandError.cancelled }
        let failed = report.occurrences.filter { $0.assessment.disposition == .failed }
        let searches = failed.filter { $0.assessment.actions.contains(.retrySong) }.map(\.id)
        let downloads = failed.filter { $0.assessment.actions.contains(.retryDownload) }.map(\.id)
        var result = MigrationBulkRetryResult()
        result.paused = report.context.matchingPaused || report.context.downloadsPaused
        result.manual = report.summary.attention - searches.count - downloads.count
        if !searches.isEmpty {
            guard let coordinator else { throw MigrationIssueCommandError.unavailable }
            result.searches = try await coordinator.retryEntries(migrationID, entryIDs: searches)
        }
        if !downloads.isEmpty {
            guard let acquisition else { throw MigrationIssueCommandError.unavailable }
            result.downloads = await acquisition.retry(entryIDs: downloads)
        }
        result.manual = max(0, report.summary.attention - result.searches - result.downloads)
        CoordinatorDiagnostics.event("issuesBulkRetry", migration: migrationID, ["searches": String(result.searches), "downloads": String(result.downloads)])
        requestReconcile(immediately: true)
        return result
    }

    /// Skip Song (explicit, confirmed in the UI). Shared downloads and library tracks are
    /// never removed; acquisition consumer accounting stops only work no one else needs.
    func skip(_ occurrence: MigrationOccurrenceReport) async throws {
        guard occurrence.assessment.actions.contains(.skip) else { throw MigrationIssueCommandError.notApplicable }
        let migrationID = occurrence.entry.migrationID
        _ = try await command(occurrence.id) {
            do { try await self.repository.skip(entryID: occurrence.id, migrationID: migrationID, now: self.now()) }
            catch SongMatchingError.staleAttempt { throw MigrationIssueCommandError.changed }
            return ""
        }
        afterUserTransition()
    }

    /// Restore Song (undo Skip).
    func restore(_ occurrence: MigrationOccurrenceReport) async throws {
        guard occurrence.assessment.disposition == .skipped else { throw MigrationIssueCommandError.notApplicable }
        let migrationID = occurrence.entry.migrationID
        _ = try await command(occurrence.id) {
            do { try await self.repository.restore(entryID: occurrence.id, migrationID: migrationID, now: self.now()) }
            catch SongMatchingError.staleAttempt { throw MigrationIssueCommandError.changed }
            return ""
        }
        afterUserTransition()
    }

    /// Choose Another Recording: releases the accepted (not yet downloaded) YouTube
    /// selection through the existing rejection path, so the song returns to review and
    /// that video is never proposed again. Candidate confirmation stays explicit.
    func releaseSelection(_ occurrence: MigrationOccurrenceReport) async throws {
        guard occurrence.assessment.actions.contains(.chooseOtherRecording) else { throw MigrationIssueCommandError.notApplicable }
        _ = try await command(occurrence.id) {
            let accepted = try await self.migrations.candidates(entryID: occurrence.id).first { $0.decision == .accepted && $0.provider == "youtube" }
            guard let accepted else { throw MigrationIssueCommandError.notApplicable }
            do { try await self.migrations.rejectCandidate(entryID: occurrence.id, candidateID: accepted.id) }
            catch SongMatchingError.staleAttempt { throw MigrationIssueCommandError.changed }
            return ""
        }
        afterUserTransition()
    }

    /// Prepares an occurrence whose linked audio is missing for a new association
    /// (no-op otherwise). Returns the current occurrence for the association sheet.
    func prepareReassociation(_ occurrence: MigrationOccurrenceReport) async throws -> PlaylistMigrationEntry {
        if occurrence.assessment.category == .missingLocalAudio {
            do { try await repository.releaseMissingLocalAudio(entryID: occurrence.id, migrationID: occurrence.entry.migrationID, now: now()) }
            catch SongMatchingError.staleAttempt { throw MigrationIssueCommandError.changed }
            afterUserTransition()
        }
        return try await migrations.entry(id: occurrence.id)
    }

    /// Download Again after the local audio of a confirmed recording was deleted.
    func downloadAgain(_ occurrence: MigrationOccurrenceReport) async throws -> String {
        guard occurrence.assessment.actions.contains(.downloadAgain) else { throw MigrationIssueCommandError.notApplicable }
        let migrationID = occurrence.entry.migrationID
        let message = try await command(occurrence.id) {
            do { try await self.repository.downloadAgain(entryID: occurrence.id, migrationID: migrationID, now: self.now()) }
            catch SongMatchingError.staleAttempt { throw MigrationIssueCommandError.changed }
            return "Download queued."
        }
        afterUserTransition()
        return message
    }

    private func afterUserTransition() {
        acquisition?.requestReconcile(immediately: true)
        if let coordinator { Task { await coordinator.reconcileAll() } }
        requestReconcile(immediately: true)
    }

    private func command(_ entryID: UUID, _ body: @escaping () async throws -> String) async throws -> String {
        guard !busyEntries.contains(entryID) else { throw MigrationIssueCommandError.alreadyRunning }
        busyEntries.insert(entryID)
        defer { busyEntries.remove(entryID); requestReconcile() }
        return try await body()
    }

    // MARK: Notifications

    /// Delivers the current cycle's aggregate event at most once. Returns when to look
    /// again (waiting for a batch notification or backing off after a transient failure).
    private func deliver(_ result: MigrationIssueReconciliation, now stamp: Date) async -> Date? {
        guard let event = result.pendingEvent, !invalidated else { return nil }
        let summary = result.report.summary
        if let last = event.lastAttemptAt, stamp.timeIntervalSince(last) < configuration.deliveryBackoff {
            return last.addingTimeInterval(configuration.deliveryBackoff)
        }
        let id = event.migrationID
        switch event.kind {
        case .fullyReady where result.acquisitionLinks > 0:
            // Phase 10.5 already sends "Playlist Ready Offline" for playlists it downloaded.
            await record(id, event.cycle, .coalesced, stamp)
            return nil
        case .needsAttention where result.acquisitionLinks > 0:
            if result.acquisitionBatchPending, let settled = result.state.settledAt, stamp < settled.addingTimeInterval(configuration.batchWait) {
                return settled.addingTimeInterval(configuration.batchWait)
            }
            if result.batchDelivered && result.resolvedBatch != event.batchAtSettle {
                // The final confirmed-download notification of this cycle already told the
                // user how many songs still need attention.
                await record(id, event.cycle, .coalesced, stamp)
                return nil
            }
        default: break
        }
        guard let notifier else { await record(id, event.cycle, .notPermitted, stamp); return nil }
        deliveryAttempts += 1
        let outcome = await notifier.deliverMigrationReport(identifier: MigrationIssueNotificationContent.identifier(event),
            title: MigrationIssueNotificationContent.title(event.kind), body: MigrationIssueNotificationContent.body(summary),
            playlistID: summary.playlistID, opensIssues: event.kind == .needsAttention)
        switch outcome {
        case .delivered: await record(id, event.cycle, .delivered, stamp); return nil
        case .notPermitted: await record(id, event.cycle, .notPermitted, stamp); return nil
        case .failed:
            let final = await record(id, event.cycle, nil, stamp)
            return final == nil ? stamp.addingTimeInterval(configuration.deliveryBackoff) : nil
        }
    }

    @discardableResult
    private func record(_ id: UUID, _ cycle: Int, _ outcome: MigrationReportEvent.Delivery?, _ stamp: Date) async -> MigrationReportEvent.Delivery? {
        do {
            let final = try await repository.recordDelivery(migrationID: id, cycle: cycle, outcome: outcome, now: stamp)
            CoordinatorDiagnostics.event("issueNotification", migration: id, ["cycle": String(cycle), "outcome": final?.rawValue ?? "retry"])
            return final
        } catch { report(error); return nil }
    }

    private func scheduleRecheck(at date: Date?) {
        recheck?.cancel(); recheck = nil
        guard let date, !invalidated else { return }
        let seconds = max(0.05, date.timeIntervalSince(now()))
        recheck = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(Int(seconds * 1000)))
            guard !Task.isCancelled else { return }
            self?.requestReconcile(immediately: true)
        }
    }

    private func report(_ error: Error) {
        if error is CancellationError { return }
        CoordinatorDiagnostics.failure(error, stage: "issues", migration: nil)
        lastError = "Migration issues couldn't be updated. They refresh automatically."
    }
}
