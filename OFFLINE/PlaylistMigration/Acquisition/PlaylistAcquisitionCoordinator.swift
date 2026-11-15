import Combine
import Foundation
import GRDB
import OSLog

/// Confirmed recording → shared download job → verified local track → occurrences.
///
/// Owns orchestration only. `DownloadManager` remains the single queue and scheduler
/// (global concurrency, Wi-Fi policy, background URLSession, verification and import);
/// `GRDBPlaylistMigrationRepository` remains the owner of decisions and occurrences.
///
/// Reconciliation is idempotent and is the only code path: launch, foreground return,
/// a committed matching decision, a job state change, Pause/Continue and Retry all
/// request the same pass. Passes never overlap; a request during a pass reruns it once.
@MainActor final class PlaylistAcquisitionCoordinator: ObservableObject {
    /// Per-occurrence state derived from persisted links and shared job rows.
    @Published private(set) var displayStates: [UUID: AcquisitionDisplayState] = [:]
    @Published private(set) var pausedMigrations: Set<String> = []
    @Published private(set) var lastError: String?
    /// Set when the user opens a completion notification.
    @Published var requestedPlaylistID: String?

    let repository: PlaylistAcquisitionRepository
    private let migrations: GRDBPlaylistMigrationRepository
    private let downloads: DownloadManager
    private let preferences: YouTubePreferences
    private let notifier: any PlaylistAcquisitionNotifying
    private let execution: (any BackgroundExecutionGranting)?
    private let now: () -> Date
    private let retryDelay: (Int) -> TimeInterval
    private let debounce: Duration
    private var links: [String: AcquisitionLinkRecord] = [:]
    private var controls: [String: AcquisitionControlRecord] = [:]
    private var playlists: [String: AcquisitionPlaylist] = [:]
    private var observation: (any DatabaseCancellable)?
    private var subscriptions = Set<AnyCancellable>()
    private var running = false
    private var rerun = false
    private var pending: Task<Void, Never>?
    private var retryTimer: Task<Void, Never>?
    private var jobStates: [String: StoredDownloadState] = [:]
    /// Playlists that had outstanding acquisition work during this process. Partial-result
    /// notifications are only considered for them, never for untouched playlists at launch.
    private var activeThisProcess = Set<String>()
    private var repaired = Set<String>()
    private var requestedAuthorization = false
    private let log = Logger(subsystem: "com.th07.muzikbelesh", category: "PlaylistAcquisition")
    /// Completed passes (diagnostics and deterministic tests).
    private(set) var passes = 0

    init(storage: StorageCoordinator, downloads: DownloadManager, preferences: YouTubePreferences,
         notifier: any PlaylistAcquisitionNotifying, execution: (any BackgroundExecutionGranting)? = nil,
         now: @escaping () -> Date = Date.init, retryDelay: @escaping (Int) -> TimeInterval = { 30 * pow(2, Double(max(0, $0 - 1))) },
         debounce: Duration = .milliseconds(250)) {
        repository = PlaylistAcquisitionRepository(db: storage.database.dbQueue)
        migrations = storage.playlistMigrations
        self.downloads = downloads
        self.preferences = preferences
        self.notifier = notifier
        self.execution = execution
        self.now = now
        self.retryDelay = retryDelay
        self.debounce = debounce
        notifier.onOpenPlaylist = { [weak self] id in self?.requestedPlaylistID = id }
    }

    /// Startup sequence step 5+: called once, after storage, the library snapshot and
    /// DownloadManager (with its background-transfer reconciliation) exist.
    func start() {
        guard observation == nil else { return }
        // Any committed decision, occurrence or session change. The coordinator's own
        // link/control tables are deliberately not observed, so passes converge.
        observation = DatabaseRegionObservation(tracking: Table("migration_entries").all(), Table("migration_candidates").all(), Table("playlist_migrations").all())
            .start(in: migrations.db, onError: { [weak self] _ in
                Task { @MainActor in self?.lastError = "Playlist download updates could not be observed. Reopen the app." }
            }, onChange: { [weak self] _ in
                Task { @MainActor in self?.requestReconcile() }
            })
        // `$jobs` publishes the new value before the property changes.
        downloads.$jobs.sink { [weak self] jobs in self?.jobsChanged(jobs) }.store(in: &subscriptions)
        requestReconcile(immediately: true)
    }

    // MARK: User intent

    func pause(migrationID: String) async {
        do {
            try await repository.setPaused(true, migrationID: migrationID)
            pausedMigrations.insert(migrationID)
            refreshDisplay(downloads.jobs)
        } catch { report(error) }
        await reconcileNow()
    }

    func continueDownloads(migrationID: String) async {
        do {
            try await repository.setPaused(false, migrationID: migrationID)
            pausedMigrations.remove(migrationID)
            // Resume transfers the pause stopped. Wi-Fi-only and concurrency still apply.
            for link in links.values where link.migrationID == migrationID && link.state == .waiting {
                if let id = link.downloadJobID, downloads.jobs.first(where: { $0.id == id })?.state == .paused { downloads.retry(id) }
            }
        } catch { report(error) }
        await reconcileNow()
    }

    /// Clears automatic-retry exhaustion for retryable failures in one playlist.
    func retryFailed(migrationID: String) async {
        await retry(links.values.filter { $0.migrationID == migrationID && $0.state == .failed })
    }

    func retry(entryID: UUID) async {
        guard let link = links[entryID.uuidString], link.state == .failed else { return }
        await retry([link])
    }

    private func retry(_ failed: [AcquisitionLinkRecord]) async {
        guard !failed.isEmpty else { return }
        var reset: [AcquisitionLinkRecord] = []
        for var link in failed {
            link.state = .waiting; link.retries = 0; link.nextRetryAt = nil; link.failure = nil; link.updatedAt = now()
            reset.append(link)
        }
        do {
            try await repository.save(reset)
            for link in reset { links[link.entryID] = link }
            for id in Set(reset.compactMap(\.downloadJobID)) {
                guard let job = downloads.jobs.first(where: { $0.id == id }) else { continue }
                if job.state == .completed { repaired.remove(id); downloads.retry(id, repair: true) }
                else if [.failed, .cancelled, .paused, .interrupted].contains(job.state) { downloads.retry(id) }
            }
        } catch { report(error) }
        await reconcileNow()
    }

    // MARK: Presentation

    func summary(for presentation: MigrationPlaylistPresentation) -> PlaylistAcquisitionSummary {
        var value = PlaylistAcquisitionSummary()
        value.total = presentation.rows.count
        value.userPaused = pausedMigrations.contains(presentation.session.id.uuidString)
        for row in presentation.rows {
            if row.playableTrack != nil { value.availableOffline += 1; continue }
            if let state = displayStates[row.id] {
                switch state {
                case .availableOffline: value.verifying += 1 // Association visible before the snapshot catches up.
                case .queued, .preparing, .waitingForConnection, .waitingForDevice: value.queued += 1
                case .downloading: value.downloading += 1
                case .waitingForWiFi: value.waitingForWiFi += 1
                case .verifying: value.verifying += 1
                case .playlistPaused, .paused: value.paused += 1
                case .failed: value.failed += 1
                case .unsupported: value.unsupported += 1
                }
                continue
            }
            switch row.effectiveStatus {
            // Not yet confirmed (including songs without a usable match): review, not download.
            case .pending, .matching, .needsReview, .unavailable, .failed: value.awaitingReview += 1
            case .matched, .queued, .downloading, .verifying: value.queued += 1
            case .ready, .skipped: break
            }
        }
        return value
    }

    func link(for entryID: UUID) -> AcquisitionLinkRecord? { links[entryID.uuidString] }

    /// Source playlists a shared job serves, for the global Downloads page.
    func playlistNames(forJob id: String) -> [String] {
        let names = Set(links.values.filter { $0.downloadJobID == id }.compactMap { playlists[$0.migrationID]?.name })
        return names.sorted()
    }

    // MARK: Scheduling of passes

    func requestReconcile(immediately: Bool = false) {
        if running { rerun = true; return }
        guard pending == nil else { return }
        let delay = immediately ? Duration.zero : debounce
        pending = Task { [weak self] in
            if delay > .zero { try? await Task.sleep(for: delay) }
            guard let self else { return }
            self.pending = nil
            await self.reconcileNow()
        }
    }

    /// Runs (or joins) a pass and returns after it, including any rerun it requested.
    func reconcileNow() async {
        if running { rerun = true; while running { try? await Task.sleep(for: .milliseconds(20)) }; return }
        running = true
        let token = execution?.begin("Playlist downloads") { }
        defer {
            running = false
            if let token { execution?.end(token) }
        }
        repeat {
            rerun = false
            await pass()
            passes += 1
        } while rerun
    }

    private func jobsChanged(_ jobs: [StoredDownloadJob]) {
        let linked = Set(links.values.compactMap(\.downloadJobID))
        var transition = false
        var states: [String: StoredDownloadState] = [:]
        for job in jobs where linked.contains(job.id) {
            states[job.id] = job.state
            if jobStates[job.id] != job.state { transition = true }
        }
        jobStates = states
        refreshDisplay(jobs)
        if transition { requestReconcile() }
    }

    // MARK: Reconciliation

    private func pass() async {
        let plan: AcquisitionPlan
        do { plan = try await repository.plan() } catch { report(error); return }
        playlists = plan.playlists
        controls = plan.controls
        pausedMigrations = Set(plan.controls.values.filter(\.userPaused).map(\.migrationID))
        let original = Dictionary(uniqueKeysWithValues: plan.links.map { ($0.entryID, $0) })
        var current = original
        let demands = Dictionary(plan.demands.map { ($0.entryID, $0) }, uniquingKeysWith: { first, _ in first })
        var removed: [AcquisitionLinkRecord] = []
        let stamp = now()

        // 1. Stale or superseded links. A changed decision never inherits an old result.
        for (entryID, link) in original {
            let entry = plan.entries[entryID]
            let sameDecision = entry?.acceptedCandidateID == link.candidateID
            if entry?.status == .ready, sameDecision, let trackID = entry?.localTrackID {
                if link.state != .ready || link.trackID != trackID {
                    var ready = link; ready.state = .ready; ready.trackID = trackID; ready.failure = nil
                    ready.completedAt = link.completedAt ?? stamp; ready.updatedAt = stamp
                    current[entryID] = ready
                }
                continue
            }
            if let demand = demands[entryID], demand.candidateID == link.candidateID, demand.videoID == link.providerIdentity,
               link.state != .ready { continue }
            removed.append(link); current[entryID] = nil
        }

        // 2. New confirmed occurrences.
        for demand in plan.demands where current[demand.entryID] == nil {
            let valid = YouTubeURLValidator.isValidID(demand.videoID)
            current[demand.entryID] = AcquisitionLinkRecord(entryID: demand.entryID, migrationID: demand.migrationID, candidateID: demand.candidateID,
                provider: "youtube", providerIdentity: demand.videoID, downloadJobID: nil, createdJob: false,
                state: valid ? .waiting : .unsupported, trackID: nil, failure: valid ? nil : AcquisitionFailureCategory.unsupportedFormat.message,
                retries: 0, nextRetryAt: nil, createdAt: stamp, updatedAt: stamp, completedAt: nil)
        }

        // 3. One shared job per recording identity. Paused playlists never create work.
        let paused = pausedMigrations
        let open = current.values.filter { $0.state == .waiting || $0.state == .associating || $0.state == .failed }
        var createdAny = false
        for (videoID, group) in Dictionary(grouping: open, by: \.providerIdentity) {
            let active = group.filter { !paused.contains($0.migrationID) }
            var job = downloads.job(for: videoID)
            var created = false
            if job == nil, !active.isEmpty, let demand = active.compactMap({ demands[$0.entryID] }).first {
                let video = YouTubeVideo(id: videoID, title: demand.title, channel: demand.channel, thumbnailURL: demand.thumbnail,
                                         duration: demand.durationMs.map { Double($0) / 1000 })
                if let result = downloads.acquisitionJob(for: video, quality: preferences.quality) {
                    job = result.job; created = result.created; createdAny = createdAny || created
                }
            }
            guard let job else { continue }
            // A newly confirmed occurrence revives a stopped existing job, unless its
            // failure is permanent. Jobs the user paused for links already attached stay paused.
            let newlyLinked = active.contains { $0.downloadJobID != job.id && $0.state == .waiting }
            if newlyLinked, !created {
                switch job.state {
                case .paused, .cancelled, .interrupted: downloads.retry(job.id)
                case .failed where AcquisitionFailureCategory.classify(job.errorMessage).retryable: downloads.retry(job.id)
                default: break
                }
            }
            for link in group where link.downloadJobID != job.id || (created && !link.createdJob) {
                var updated = link; updated.downloadJobID = job.id; updated.createdJob = link.createdJob || created; updated.updatedAt = stamp
                current[link.entryID] = updated
            }
        }
        if createdAny, !requestedAuthorization {
            requestedAuthorization = true
            let notifier = notifier
            Task { await notifier.requestAuthorizationIfUndetermined() }
        }

        // 4. Evaluate shared job outcomes, once per job.
        var jobsByID: [String: StoredDownloadJob] = [:]
        for job in downloads.jobs { jobsByID[job.id] = job }
        var associations: [String: [AcquisitionLinkRecord]] = [:]
        var earliestRetry: Date?
        let linkedOpen = current.values.filter { [.waiting, .associating, .failed].contains($0.state) && $0.downloadJobID != nil }
        for (jobID, group) in Dictionary(grouping: linkedOpen, by: { $0.downloadJobID! }) {
            guard let job = jobsByID[jobID] else { continue }
            let groupPaused = group.allSatisfy { paused.contains($0.migrationID) }
            switch job.state {
            case .completed:
                // Failed links wait for an explicit Retry (which repairs the download);
                // re-verifying the same invalid file on every pass would be wasted work.
                guard let trackID = job.trackID else {
                    // A completed job whose library track was removed: repair it once for
                    // occurrences that still need it, never in a loop.
                    if !groupPaused, !repaired.contains(jobID), group.contains(where: { $0.state == .waiting }) {
                        repaired.insert(jobID); downloads.retry(jobID, repair: true)
                    }
                    continue
                }
                for link in group where link.state != .failed {
                    var next = link; next.state = .associating; next.trackID = trackID; next.failure = nil; next.updatedAt = stamp
                    current[link.entryID] = next
                }
                associations[trackID, default: []].append(contentsOf: group.compactMap { current[$0.entryID] }.filter { $0.state == .associating })
            case .failed, .cancelled:
                let category: AcquisitionFailureCategory = job.state == .cancelled ? .userCancelled : .classify(job.errorMessage)
                let retries = group.map(\.retries).max() ?? 0
                let due = group.compactMap(\.nextRetryAt).min()
                if group.allSatisfy({ $0.state == .failed }) { continue } // Waiting for the user.
                if let due, retries > 0, group.contains(where: { $0.state == .waiting }) {
                    // A paused playlist keeps its retry state; Continue requests a new pass.
                    if groupPaused { continue }
                    if due <= stamp {
                        downloads.retry(job.id)
                        for link in group { var next = link; next.nextRetryAt = nil; next.updatedAt = stamp; current[link.entryID] = next }
                    } else { earliestRetry = min(earliestRetry ?? due, due) }
                    continue
                }
                let retryable = category.retryable && retries < category.automaticRetries && !groupPaused
                for link in group {
                    var next = link; next.failure = category.message; next.updatedAt = stamp
                    if retryable {
                        next.state = .waiting; next.retries = retries + 1; next.nextRetryAt = stamp.addingTimeInterval(retryDelay(retries + 1))
                        earliestRetry = min(earliestRetry ?? next.nextRetryAt!, next.nextRetryAt!)
                    } else if !groupPaused {
                        next.state = category.retryable ? .failed : .unsupported
                    }
                    current[link.entryID] = next
                }
            default:
                // An externally retried job (Downloads page) brings failed links back.
                for link in group where link.state == .failed {
                    var next = link; next.state = .waiting; next.failure = nil; next.updatedAt = stamp
                    current[link.entryID] = next
                }
            }
        }

        // 5. Pause enforcement with consumer accounting. A shared job keeps running while
        //    any non-paused playlist needs it. Only jobs created for playlists are paused,
        //    never an ordinary download the user started independently.
        let consumers = Dictionary(grouping: current.values.filter { $0.state == .waiting && $0.downloadJobID != nil }, by: { $0.downloadJobID! })
        for (jobID, group) in consumers {
            guard let job = jobsByID[jobID], job.state.stoppable,
                  group.allSatisfy({ paused.contains($0.migrationID) }), group.contains(where: \.createdJob) else { continue }
            downloads.pause(job)
        }
        // Orphans: a job created only for occurrences whose decision changed.
        for link in removed where link.createdJob {
            guard let jobID = link.downloadJobID, consumers[jobID] == nil, let job = jobsByID[jobID], job.state.stoppable else { continue }
            downloads.pause(job)
        }

        // 6. Persist (only what changed), then attach verified results.
        let changed = current.values.filter { link in original[link.entryID].map { !$0.sameContent(as: link) } ?? true }
        do {
            try await repository.delete(entryIDs: removed.map(\.entryID))
            try await repository.save(changed)
        } catch { report(error) }
        links = current
        for (trackID, group) in associations where !group.isEmpty {
            await associate(trackID: trackID, group)
        }

        // 7. Retry timer, presentation and notifications.
        scheduleRetry(at: earliestRetry)
        for link in links.values where link.state == .waiting || link.state == .associating { activeThisProcess.insert(link.migrationID) }
        refreshDisplay(downloads.jobs)
        await reconcileNotifications()
        if !links.values.filter({ $0.state == .waiting && !pausedMigrations.contains($0.migrationID) }).isEmpty {
            downloads.continueInBackgroundIfPossible()
        }
    }

    private func associate(trackID: String, _ group: [AcquisitionLinkRecord]) async {
        let occurrences = group.compactMap { link -> (entryID: UUID, candidateID: UUID)? in
            guard let entry = UUID(uuidString: link.entryID), let candidate = UUID(uuidString: link.candidateID) else { return nil }
            return (entry, candidate)
        }
        let outcomes: [UUID: AcquisitionAssociation]
        do { outcomes = try await migrations.associateAcquiredTrack(trackID: trackID, occurrences: occurrences) }
        catch { report(error); return } // Retried by the next pass; the imported track is kept.
        var save: [AcquisitionLinkRecord] = []
        var stale: [String] = []
        let stamp = now()
        var repair: String?
        for link in group {
            guard let id = UUID(uuidString: link.entryID), let outcome = outcomes[id] else { continue }
            var next = link; next.updatedAt = stamp
            switch outcome {
            case .associated:
                next.state = .ready; next.completedAt = stamp; next.failure = nil
                save.append(next)
            case .stale:
                stale.append(link.entryID)
            case .invalidAudio:
                // The managed file is missing or fails verification: repair the shared
                // download once (never a silent re-download loop), otherwise surface it.
                next.trackID = nil
                if let jobID = link.downloadJobID, !repaired.contains(jobID), !pausedMigrations.contains(link.migrationID) {
                    repair = jobID; next.state = .waiting
                } else {
                    next.state = .failed; next.failure = AcquisitionFailureCategory.verificationFailed.message
                }
                save.append(next)
            }
        }
        if let repair { repaired.insert(repair); downloads.retry(repair, repair: true) }
        do {
            try await repository.delete(entryIDs: stale)
            try await repository.save(save)
        } catch { report(error) }
        for link in save { links[link.entryID] = link }
        for id in stale { links[id] = nil }
    }

    private func scheduleRetry(at date: Date?) {
        retryTimer?.cancel(); retryTimer = nil
        guard let date else { return }
        let seconds = max(0.05, date.timeIntervalSince(now()))
        retryTimer = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(Int(seconds * 1000)))
            guard !Task.isCancelled else { return }
            self?.requestReconcile(immediately: true)
        }
    }

    private func refreshDisplay(_ jobs: [StoredDownloadJob]) {
        var jobsByID: [String: StoredDownloadJob] = [:]
        for job in jobs { jobsByID[job.id] = job }
        var next: [UUID: AcquisitionDisplayState] = [:]
        for link in links.values {
            guard let id = UUID(uuidString: link.entryID) else { continue }
            next[id] = display(link, job: link.downloadJobID.flatMap { jobsByID[$0] }, paused: pausedMigrations.contains(link.migrationID))
        }
        if next != displayStates { displayStates = next }
    }

    private func display(_ link: AcquisitionLinkRecord, job: StoredDownloadJob?, paused: Bool) -> AcquisitionDisplayState {
        switch link.state {
        case .ready: return .availableOffline
        case .unsupported: return .unsupported(link.failure ?? AcquisitionFailureCategory.unsupportedFormat.message)
        case .failed: return .failed(link.failure ?? AcquisitionFailureCategory.unknown.message, retryable: true)
        case .associating: return .verifying
        case .waiting: break
        }
        guard let job else { return paused ? .playlistPaused : .queued }
        switch job.state {
        case .queued:
            if paused { return .playlistPaused }
            return downloads.stateLabel(for: job) == "Waiting for device to cool" ? .waitingForDevice : .queued
        case .waitingForWiFi: return paused ? .playlistPaused : .waitingForWiFi
        case .resolving: return .preparing
        case .downloading:
            if downloads.stateLabel(for: job) == "Waiting for Wi-Fi" { return .waitingForWiFi }
            return .downloading(progress: job.expected != nil && job.expected! > 0 ? job.progress : nil)
        case .verifying, .importing, .completed: return .verifying
        case .paused: return paused ? .playlistPaused : .paused
        case .interrupted: return paused ? .playlistPaused : .waitingForConnection
        case .failed, .cancelled:
            // Waiting for a scheduled automatic retry: queued, not active.
            return paused ? .playlistPaused : .queued
        }
    }

    // MARK: Notifications

    /// Completion reflects verified availability only: every imported occurrence is
    /// associated with present, managed local audio (`MigrationLocalAudio`), after the
    /// association itself performed decoding and SHA-256 verification.
    private func reconcileNotifications() async {
        for (migrationID, playlist) in playlists where !playlist.cancelled {
            let migrationLinks = links.values.filter { $0.migrationID == migrationID }
            // Only playlists that Phase 10.5 acquired for; never a surprise at upgrade.
            guard !migrationLinks.isEmpty else { continue }
            let rows: [MigrationPlaylistRow]
            let occurrences = migrations, playlistID = playlist.playlistID
            // Bounded file checks run off the main actor.
            do { rows = try await Task.detached(priority: .utility) { try occurrences.rows(playlistID: playlistID) }.value } catch { continue }
            let ready = rows.filter { $0.playableTrack != nil }.count
            let complete = !rows.isEmpty && ready == rows.count
            let control = controls[migrationID]
            do {
                if complete {
                    guard control?.readyNotifiedAt == nil else { continue }
                    let songs = rows.count == 1 ? "1 song" : "All \(rows.count) songs"
                    _ = await notifier.deliver(identifier: "playlist-ready-" + migrationID, title: "Playlist Ready Offline",
                        body: "\(songs) in “\(playlist.name)” \(rows.count == 1 ? "is" : "are") available offline. Open Muzik Belesh to start listening.",
                        playlistID: playlist.playlistID)
                    // Handled once whether or not permission allowed delivery: no repeats.
                    let delivered = now()
                    try await repository.markReadyNotified(migrationID: migrationID, at: delivered)
                    controls[migrationID] = control.map { var c = $0; c.readyNotifiedAt = delivered; return c }
                        ?? AcquisitionControlRecord(migrationID: migrationID, userPaused: false, readyNotifiedAt: delivered, partialNotifiedSummary: nil, updatedAt: delivered)
                    activeThisProcess.remove(migrationID)
                    continue
                }
                if control?.readyNotifiedAt != nil {
                    // No longer complete (audio removed): a later completion is legitimate again.
                    try await repository.markReadyNotified(migrationID: migrationID, at: nil)
                    controls[migrationID]?.readyNotifiedAt = nil
                }
                let outstanding = migrationLinks.contains { $0.state == .waiting || $0.state == .associating }
                let attention = migrationLinks.filter { $0.state == .failed || $0.state == .unsupported }.count
                guard activeThisProcess.contains(migrationID), !outstanding, attention > 0 else { continue }
                let summary = "\(ready)/\(rows.count)"
                activeThisProcess.remove(migrationID)
                guard control?.partialNotifiedSummary != summary else { continue }
                let remaining = rows.count - ready
                _ = await notifier.deliver(identifier: "playlist-partial-" + migrationID, title: "Playlist Downloads Finished",
                    body: "\(ready) of \(rows.count) songs in “\(playlist.name)” are available offline. \(remaining) still need attention.",
                    playlistID: playlist.playlistID)
                try await repository.markPartialNotified(migrationID: migrationID, summary: summary)
                controls[migrationID] = control.map { var c = $0; c.partialNotifiedSummary = summary; return c }
                    ?? AcquisitionControlRecord(migrationID: migrationID, userPaused: false, readyNotifiedAt: nil, partialNotifiedSummary: summary, updatedAt: now())
            } catch { report(error) }
        }
    }

    private func report(_ error: Error) {
        if error is CancellationError { return }
        log.error("Playlist acquisition pass failed: \(String(describing: error), privacy: .public)")
        lastError = "Playlist downloads could not be updated. They will retry automatically."
    }
}
