import Combine
import OSLog
import Foundation
import Network
import UIKit

extension StoredDownloadState {
    var pending: Bool { self == .queued || self == .waitingForWiFi }
    var stoppable: Bool { pending || self == .resolving || self == .downloading }
    var label: String {
        switch self {
        case .waitingForWiFi: "Waiting for Wi-Fi"
        case .importing: "Adding to Library"
        case .completed: "Downloaded"
        default: rawValue.capitalized
        }
    }
}

@MainActor final class DownloadManager: ObservableObject {
    @Published private(set) var jobs: [StoredDownloadJob] = []
    @Published private(set) var rates: [String: Double] = [:]
    @Published var issue: String?
    private let storage: StorageCoordinator?
    private let preferences: YouTubePreferences
    private let preparer: any YouTubeDownloadPreparing
    private let transfer: any AudioTransferring
    private let system: (any SystemDownloading)?
    private var reconciling = false
    private let artwork: YouTubeArtworkLoader
    private let monitor = NWPathMonitor()
    private var subscriptions = Set<AnyCancellable>()
    private var connected = false
    @Published private var wifi = false
    private var workers: [String: Task<Void, Never>] = [:]
    private var checkpoints: [String: ProgressCadence] = [:]
    private var samples: [String: TransferRate] = [:]
    private var attempts: [String: UUID] = [:]
    @Published private(set) var resourcePolicy = ResourcePolicy()
    private var foreground = true
    private var storageFailed = false
    /// Set by `invalidate()`: this instance never writes or schedules again.
    private var invalidated = false
    private var halted: Bool { storageFailed || invalidated }
    /// Bounded execution granted while iOS has woken the suspended app (Phase 10.5).
    private let execution: (any BackgroundExecutionGranting)?
    private var opportunity: Int?
    /// Staged (already transferred) audio being verified and imported. Verification uses
    /// no network, so it never waits for, or occupies, a transfer slot.
    private var verifying = Set<String>()
    static let verificationLimit = 2
    private let schedulerLog = Logger(subsystem: "com.th07.muzikbelesh", category: "DownloadScheduler")
    private var lastDecision = ""
    /// Jobs whose current system task was created while the app was not in the
    /// foreground. iOS treats such tasks as discretionary and may defer them
    /// indefinitely, so a zero-byte one is recreated when the app is active again.
    private var createdInBackground = Set<String>()
    /// Jobs whose stalled reservation was already recreated during this foreground
    /// session: each job is repaired at most once per activation (no restart loops).
    private var repairedThisActivation = Set<String>()
    /// Foreground-only queue health check (cancelled whenever the app leaves the foreground).
    private var watchdog: Task<Void, Never>?
    private let recoveryInterval: Duration
    private let stallThreshold: TimeInterval
    private var progressAtLastCheck: [String: Int64] = [:]
    private var lastStallLog: [String: String] = [:]
    /// Bumped on lifecycle, network and policy changes so observers refresh wait reasons.
    @Published private(set) var schedulingRevision = 0
    private var staging: URL? { storage?.paths.applicationSupport.appendingPathComponent("DownloadStaging", isDirectory: true) }

    init(storage: StorageCoordinator?, preferences: YouTubePreferences, preparer: any YouTubeDownloadPreparing,
         transfer: any AudioTransferring, artwork: YouTubeArtworkLoader, observeNetwork: Bool = true,
         system: (any SystemDownloading)? = nil, execution: (any BackgroundExecutionGranting)? = nil,
         recoveryInterval: Duration = .seconds(20), stallThreshold: TimeInterval = 90) {
        self.system = system
        self.execution = execution
        self.recoveryInterval = recoveryInterval
        self.stallThreshold = stallThreshold
        if system != nil { foreground = UIApplication.shared.applicationState != .background }
        self.storage = storage
        self.preferences = preferences
        self.preparer = preparer
        self.transfer = transfer
        self.artwork = artwork
        do {
            guard let storage, let staging else { throw DownloadFailure.disk }
            try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
            jobs = try storage.downloads.all().filter { $0.position != nil }.sorted { ($0.position ?? 0) < ($1.position ?? 0) }
            let retained = Set(jobs.filter { $0.state != .completed && $0.state != .cancelled }.map(\.id))
            let generations = Set(jobs.compactMap(\.transferGeneration))
            for file in try FileManager.default.contentsOfDirectory(at: staging, includingPropertiesForKeys: nil) {
                let id = file.deletingPathExtension().lastPathComponent
                if file.pathExtension == "m4a", UUID(uuidString: id) != nil, !retained.contains(id) {
                    try FileManager.default.removeItem(at: file)
                }
                if file.pathExtension == "incoming", UUID(uuidString: id) != nil, !generations.contains(id) {
                    try FileManager.default.removeItem(at: file)
                }
            }
            for job in jobs where [.downloading, .verifying, .importing, .resolving].contains(job.state) && job.transferGeneration == nil {
                update(job.id) { $0.state = .queued }
            }
        } catch { failStorage() }
        if let system {
            system.owner = self
            reconcileSystem(repairStalled: foreground)
        }
        if observeNetwork {
            monitor.pathUpdateHandler = { [weak self] path in
                Task { @MainActor in self?.setPath(connected: path.status == .satisfied, wifi: path.usesInterfaceType(.wifi)) }
            }
            monitor.start(queue: DispatchQueue(label: "offline.download.path"))
        }
        preferences.$wifiOnly.dropFirst().sink { [weak self] enabled in
            self?.policyChanged(strict: enabled)
            Task { @MainActor in self?.schedule() }
        }.store(in: &subscriptions)
        preferences.$simultaneous.dropFirst().sink { [weak self] _ in Task { @MainActor in self?.schedule() } }.store(in: &subscriptions)
        if foreground { startWatchdog() }
    }
    deinit { monitor.cancel() }
    /// Ends this instance's ownership of the queue, as process termination would: cancels
    /// app workers (their persisted state is recovered by the next instance), stops
    /// observers and refuses every later write. System transfers are left to iOS.
    func invalidate() {
        guard !invalidated else { return }
        invalidated = true
        subscriptions.removeAll()
        monitor.cancel()
        workers.values.forEach { $0.cancel() }
        watchdog?.cancel(); watchdog = nil
        if system?.owner === self { system?.owner = nil }
        endOpportunity()
    }
    func setPath(connected: Bool, wifi: Bool) {
        let regainedConnection = connected && (!self.connected || (wifi && !self.wifi))
        self.connected = connected
        self.wifi = wifi
        if system == nil && (!connected || (preferences.wifiOnly && !wifi)) { policyChanged(strict: true) }
        if regainedConnection {
            for job in jobs where job.state == .interrupted { update(job.id) { $0.state = .queued; $0.errorMessage = nil } }
        }
        schedulingRevision += 1
        schedule()
    }
    func setResourcePolicy(_ policy: ResourcePolicy) {
        guard policy != resourcePolicy else { return }
        resourcePolicy = policy
        schedulingRevision += 1
        schedule()
    }
    func setForeground(_ active: Bool) {
        foreground = active
        schedulingRevision += 1
        if active {
            endOpportunity()
            rates.removeAll(); samples.removeAll()
            repairedThisActivation.removeAll()
            // Refreshes the URLSession inventory, clears vanished reservations and
            // recreates deferred zero-byte tasks, then schedules.
            reconcileSystem(repairStalled: true)
            for job in jobs where job.state == .interrupted { update(job.id) { $0.state = .queued; $0.errorMessage = nil } }
            schedule()
            startWatchdog()
        } else {
            watchdog?.cancel(); watchdog = nil
        }
    }

    // MARK: Queue health (foreground only)

    /// Why a pending job is not transferring right now.
    enum QueueWait: Equatable, Sendable {
        case eligible, verificationCapacity, waitingForWiFi, noNetwork, waitingForExecution, resourceDeferred, reconciling
        case waitingForSlot(limited: Bool)
    }
    func queueWait(for job: StoredDownloadJob) -> QueueWait? {
        guard job.state.pending, workers[job.id] == nil else { return nil }
        if resourcePolicy.defersNewWork { return .resourceDeferred }
        if !(foreground || opportunity != nil) { return .waitingForExecution }
        if reconciling { return .reconciling }
        if isStaged(job) { return verifying.count < Self.verificationLimit ? .eligible : .verificationCapacity }
        if preferences.wifiOnly && !wifi { return .waitingForWiFi }
        if !connected { return .noNetwork }
        let limit = resourcePolicy.downloadLimit(preferences.simultaneous)
        if transferSlotsInUse >= limit { return .waitingForSlot(limited: limit < preferences.simultaneous) }
        return .eligible
    }
    private func isStaged(_ job: StoredDownloadJob) -> Bool {
        UUID(uuidString: job.id) != nil && staging.map { FileManager.default.fileExists(atPath: $0.appendingPathComponent(job.id + ".m4a").path) } == true
    }
    private func startWatchdog() {
        watchdog?.cancel()
        let interval = recoveryInterval
        watchdog = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: interval)
                guard !Task.isCancelled, let manager = self else { return }
                manager.checkQueueHealth()
            }
        }
    }
    /// Event-driven scheduling is primary. This bounded check only acts when an eligible
    /// job is waiting: it schedules a missed opportunity, and when every slot is held by
    /// reservations that made no progress since the previous check it refreshes the
    /// URLSession inventory (repairing vanished or stalled reservations).
    func checkQueueHealth() {
        guard foreground, !halted, !reconciling else { return }
        let waiting = jobs.filter { $0.state.pending && workers[$0.id] == nil }
        let reserved = jobs.filter { $0.transferGeneration != nil && workers[$0.id] == nil }
        defer { progressAtLastCheck = Dictionary(uniqueKeysWithValues: reserved.map { ($0.id, $0.received ?? 0) }) }
        guard !waiting.isEmpty else { return }
        let stale = reserved.filter { job in
            progressAtLastCheck[job.id].map { $0 == (job.received ?? 0) } ?? false
        }
        for job in waiting {
            let wait = queueWait(for: job)
            logStall(job, wait: wait, stale: stale.count)
        }
        if waiting.contains(where: { queueWait(for: $0) == .eligible }) {
            schedule() // A missed scheduling event: capacity exists now.
        } else if !reserved.isEmpty, stale.count == reserved.count, waiting.contains(where: { if case .waitingForSlot = queueWait(for: $0) { return true } else { return false } }) {
            reconcileSystem(repairStalled: true)
        }
    }
    private func logStall(_ job: StoredDownloadJob, wait: QueueWait?, stale: Int) {
        let reason = wait.map { String(describing: $0) } ?? "worker active"
        guard lastStallLog[job.id] != reason else { return }
        lastStallLog[job.id] = reason
        let limit = resourcePolicy.downloadLimit(preferences.simultaneous)
        schedulerLog.notice("queuedWithoutProgress job=\(job.id, privacy: .public) position=\(job.position ?? -1) foreground=\(self.foreground) connected=\(self.connected) wifiOnly=\(self.preferences.wifiOnly) wifi=\(self.wifi) effectiveLimit=\(limit) workers=\(self.workers.count) backgroundTasks=\(self.backgroundTransfers) staleReservations=\(stale) lowPower=\(self.resourcePolicy.lowPower) resourceLimited=\(self.resourcePolicy.conservesResources) reason=\(reason, privacy: .public)")
    }
    private func policyChanged(strict: Bool) {
        guard strict else { return }
        for job in jobs where job.state == .downloading || job.state == .resolving {
            if job.transferSession == BackgroundTransfers.wifi { continue }
            stop(job.id, as: .queued)
        }
    }
    func stateLabel(for job: StoredDownloadJob) -> String {
        if job.state == .downloading, job.transferSession == BackgroundTransfers.wifi, !wifi {
            return "Waiting for Wi-Fi"
        }
        if job.state.pending && resourcePolicy.defersNewWork { return "Waiting for device to cool" }
        return job.state.label
    }
    func job(for videoID: String) -> StoredDownloadJob? { jobs.first { $0.sourceIdentifier == videoID } }
    private func failStorage() { storageFailed = true; issue = "Download storage is unavailable. Reopen the app to retry." }
    @discardableResult private func update(_ id: String, _ change: (inout StoredDownloadJob) -> Void) -> Bool {
        guard !halted, let index = jobs.firstIndex(where: { $0.id == id }), let storage else { return false }
        var job = jobs[index]
        change(&job)
        job.dateModified = Date()
        do { try storage.downloads.save(job); jobs[index] = job; return true }
        catch { failStorage(); return false }
    }
    /// Playlist acquisition entry point (Phase 10.5). Unlike `enqueue`, an existing job is
    /// returned unchanged: a completed download is never restarted here. The caller
    /// validates the completed job's track and requests a repair only when the managed
    /// audio is genuinely missing or invalid. Main-actor isolation plus the unique
    /// per-video index make concurrent calls for one recording yield one job.
    func acquisitionJob(for video: YouTubeVideo, quality: AudioQuality) -> (job: StoredDownloadJob, created: Bool)? {
        guard !halted, storage != nil, YouTubeURLValidator.isValidID(video.id) else { return nil }
        if let existing = job(for: video.id) { return (existing, false) }
        enqueue(video, quality: quality)
        return job(for: video.id).map { ($0, true) }
    }
    func enqueue(_ video: YouTubeVideo, quality: AudioQuality) {
        guard !halted, let storage, YouTubeURLValidator.isValidID(video.id) else { return }
        if let existing = job(for: video.id) {
            if existing.state == .completed { retry(existing.id, repair: true) }
            return
        }
        let job = StoredDownloadJob(id: UUID().uuidString, sourceType: "youtube", sourceIdentifier: video.id,
                                    state: .queued, progress: 0, title: video.title, channel: video.channel,
                                    thumbnail: YouTubeImageURL.valid(video.thumbnailURL)?.absoluteString,
                                    position: (jobs.last?.position ?? -1) + 1, received: 0, attempts: 0,
                                    quality: quality.rawValue, dateAdded: Date(), dateModified: Date())
        do { try storage.downloads.save(job); jobs.append(job); schedule() } catch { failStorage() }
    }
    /// Transfer slots in use: app workers preparing or transferring (not verifying staged
    /// audio) plus system transfers that no app worker is tracking. Each job counts once.
    var transferSlotsInUse: Int {
        workers.keys.filter { !verifying.contains($0) }.count + backgroundTransfers
    }
    private var backgroundTransfers: Int { jobs.filter { $0.transferGeneration != nil && workers[$0.id] == nil }.count }
    private func schedule() {
        let limit = resourcePolicy.downloadLimit(preferences.simultaneous)
        guard !halted, foreground || opportunity != nil, !reconciling, !resourcePolicy.defersNewWork else {
            let reason = halted ? "halted" : !(foreground || opportunity != nil) ? "suspended, waiting for iOS execution"
                : reconciling ? "reconciling background transfers" : "resource policy defers new work"
            logDecision(limit: limit, blocked: reason)
            return
        }
        let waiting = preferences.wifiOnly && !wifi
        var blocked: [String] = []
        // Position order is the user's queue order: interrupted and recovered jobs keep
        // their earlier positions and are considered before newer jobs.
        for job in jobs where job.state.pending {
            let staged = UUID(uuidString: job.id) != nil && staging.map { FileManager.default.fileExists(atPath: $0.appendingPathComponent(job.id + ".m4a").path) } == true
            let desired: StoredDownloadState = waiting && !staged ? .waitingForWiFi : .queued
            if job.state != desired { update(job.id) { $0.state = desired } }
            guard workers[job.id] == nil else { continue }
            if staged {
                guard verifying.count < Self.verificationLimit else { blocked.append("verification capacity"); continue }
                guard update(job.id, { $0.state = .verifying }) else { return }
                verifying.insert(job.id)
                workers[job.id] = Task { await run(job) }
                continue
            }
            guard !waiting else { blocked.append("waiting for Wi-Fi"); continue }
            guard connected else { blocked.append("no network"); continue }
            guard transferSlotsInUse < limit else { blocked.append("no free transfer slot"); continue }
            guard update(job.id, { $0.state = .resolving }) else { return }
            workers[job.id] = Task { await run(job) }
        }
        logDecision(limit: limit, blocked: blocked.first.map { "\(blocked.count) not started: \($0)" } ?? "none")
    }
    /// One line per distinct scheduler decision (no per-progress spam).
    private func logDecision(limit: Int, blocked: String) {
        let eligible = jobs.filter { $0.state.pending }.count
        let line = "configured=\(preferences.simultaneous) effectiveLimit=\(limit) lowPower=\(resourcePolicy.lowPower) resourceLimited=\(resourcePolicy.conservesResources) appTransferWorkers=\(workers.count - verifying.count) verifying=\(verifying.count) backgroundTransfers=\(backgroundTransfers) eligiblePending=\(eligible) blocked=\(blocked)"
        guard line != lastDecision else { return }
        lastDecision = line
        schedulerLog.info("\(line, privacy: .public)")
    }
    private func run(_ job: StoredDownloadJob) async {
        defer { workers[job.id] = nil; verifying.remove(job.id); rates[job.id] = nil; attempts[job.id] = nil; samples[job.id] = nil; checkpoints[job.id] = nil; schedule(); endOpportunityIfIdle() }
        guard let storage, let staging, let videoID = job.sourceIdentifier, UUID(uuidString: job.id) != nil else { return }
        let file = staging.appendingPathComponent(job.id + ".m4a")
        do {
            try Task.checkCancellation()
            let lookup = YouTubeLibraryLookup(database: storage.database.dbQueue, paths: storage.paths)
            if case .downloaded(let id) = try await lookup.status(videoID: videoID) {
                try Task.checkCancellation()
                complete(job.id, trackID: id, file: file)
                return
            }
            var video = YouTubeVideo(id: videoID, title: job.title ?? videoID, channel: job.channel, thumbnailURL: job.thumbnail.flatMap(URL.init(string:)))
            let quality = AudioQuality(rawValue: job.quality) ?? .standard
            if !FileManager.default.fileExists(atPath: file.path) {
                for attempt in 0...1 {
                    let request = try await preparer.prepare(video: video, quality: quality)
                    try Task.checkCancellation()
                    video = request.metadata
                    guard !resourcePolicy.defersNewWork else {
                        update(job.id) { $0.state = .queued }
                        return
                    }
                    if let system {
                        let generation = UUID().uuidString
                        let task = try system.create(url: request.stream.url, job: job.id, generation: generation, strict: preferences.wifiOnly)
                        guard update(job.id, {
                            $0.state = .downloading; $0.received = 0; $0.expected = nil; $0.progress = 0
                            $0.startedAt = Date(); $0.transferNumber = task.number; $0.transferSession = task.session
                            $0.transferGeneration = generation; $0.title = video.title; $0.channel = video.channel
                            $0.thumbnail = YouTubeImageURL.valid(video.thumbnailURL)?.absoluteString
                        }) else { task.cancel(); return }
                        if foreground { createdInBackground.remove(job.id) } else { createdInBackground.insert(job.id) }
                        task.resumeIfSuspended()
                        return
                    }
                    guard update(job.id, { $0.state = .downloading; $0.startedAt = Date(); $0.received = 0; $0.expected = nil; $0.progress = 0 }) else { return }
                    let sampleID = job.id
                    let generation = UUID()
                    attempts[job.id] = generation
                    do {
                        try await transfer.download(request.stream.url, to: file, wifiOnly: preferences.wifiOnly) { bytes, total in
                            let sampledAt = ProcessInfo.processInfo.systemUptime
                            Task { @MainActor in self.progress(sampleID, attempt: generation, bytes: bytes, total: total, now: sampledAt) }
                        }
                        break
                    } catch DownloadFailure.rejected where attempt == 0 {
                        try Task.checkCancellation()
                        samples[job.id] = nil
                        update(job.id) { $0.state = .resolving; $0.attempts = ($0.attempts ?? 0) + 1 }
                    }
                }
            }
            try Task.checkCancellation()
            let finalBytes = try file.resourceValues(forKeys: [.fileSizeKey]).fileSize
            guard update(job.id, {
                $0.state = .verifying
                $0.received = finalBytes.map(Int64.init)
                if $0.expected != nil { $0.progress = 1 }
            }) else { return }
            do { try await DownloadMedia.validate(file) } catch {
                try? FileManager.default.removeItem(at: file)
                throw DownloadFailure.invalid
            }
            let image = await artwork.downloadData(for: video.thumbnailURL)
            guard update(job.id, { $0.state = .importing; if video.thumbnailURL != nil && image == nil { $0.errorMessage = "Artwork unavailable offline." } }) else { return }
            let result = try await storage.importAudio(from: file, sourceType: "youtube", sourceIdentifier: videoID, video: video, artwork: image)
            guard case .downloaded(let id) = try await lookup.status(videoID: videoID), id == result.track.id else { throw DownloadFailure.disk }
            complete(job.id, trackID: id, file: file)
        } catch {
            if Task.isCancelled {
                if jobs.first(where: { $0.id == job.id })?.state == .cancelled { try? FileManager.default.removeItem(at: file) }
                return
            }
            update(job.id) {
                $0.state = (error as? DownloadFailure) == .connection ? .interrupted : .failed
                $0.errorMessage = (error as? DownloadFailure)?.rawValue ?? (error as? YouTubeError)?.localizedDescription ?? "Audio could not be imported."
            }
        }
    }
    private func complete(_ id: String, trackID: String, file: URL) {
        if update(id, { $0.trackID = trackID; $0.finishedAt = Date(); $0.state = .completed; $0.progress = 1 }) { try? FileManager.default.removeItem(at: file) }
    }
    private func progress(_ id: String, attempt: UUID, bytes: Int64, total: Int64, now: TimeInterval) {
        guard !halted, attempts[id] == attempt, jobs.first(where: { $0.id == id })?.state == .downloading else { return }
        guard let index = jobs.firstIndex(where: { $0.id == id }) else { return }
        guard samples[id, default: TransferRate()].record(bytes: bytes, at: now) else { return }
        rates[id] = samples[id]?.bytesPerSecond
        var job = jobs[index]
        job.received = bytes
        job.expected = total > 0 ? total : nil
        job.progress = total > 0 ? min(1, Double(bytes) / Double(total)) : 0
        job.dateModified = Date()
        if checkpoints[id, default: ProgressCadence(seconds: 8)].due(at: now) {
            let start = ProcessInfo.processInfo.systemUptime
            do { try storage?.downloads.save(job) } catch { failStorage(); return }
            let ms = (ProcessInfo.processInfo.systemUptime - start) * 1000
            Logger(subsystem: "com.th07.muzikbelesh", category: "Transfer").debug("progressCheckpointMs=\(ms)")
        }
        jobs[index] = job
    }
    private func stop(_ id: String, as state: StoredDownloadState) {
        guard let job = jobs.first(where: { $0.id == id }) else { return }
        let persisted = update(id, { $0.state = state; $0.clearSystemTask() })
        // A storage failure must not leave an unrestricted transfer running after opt-out.
        if let name = job.transferSession, let number = job.transferNumber { system?.cancel(session: name, number: number) }
        workers[id]?.cancel()
        guard persisted else { return }
        discardIncoming(job)
        if state == .cancelled, workers[id] == nil, UUID(uuidString: id) != nil, let staging {
            try? FileManager.default.removeItem(at: staging.appendingPathComponent(id + ".m4a"))
        }
    }
    func pause(_ job: StoredDownloadJob) {
        guard jobs.first(where: { $0.id == job.id })?.state.stoppable == true else { return }
        stop(job.id, as: .paused)
        schedule()
    }
    func cancel(_ job: StoredDownloadJob) {
        guard let job = jobs.first(where: { $0.id == job.id }), job.state.stoppable || job.state == .paused || job.state == .interrupted else { return }
        stop(job.id, as: .cancelled)
        schedule()
    }
    func retry(_ id: String, repair: Bool = false) {
        guard let job = jobs.first(where: { $0.id == id }), [.paused, .cancelled, .failed, .interrupted].contains(job.state) || (repair && job.state == .completed) else { return }
        update(id) { $0.state = .queued; $0.errorMessage = nil; $0.refreshedGeneration = nil; $0.attempts = ($0.attempts ?? 0) + 1 }
        schedule()
    }
    func move(_ job: StoredDownloadJob, by offset: Int) {
        let pending = jobs.filter { $0.state.pending }
        guard let index = pending.firstIndex(where: { $0.id == job.id }), pending.indices.contains(index + offset), let storage else { return }
        do {
            try storage.downloads.swapPositions(job, pending[index + offset])
            jobs = try storage.downloads.all().filter { $0.position != nil }.sorted { ($0.position ?? 0) < ($1.position ?? 0) }
        } catch { failStorage() }
    }
}

extension StoredDownloadJob {
    mutating func clearSystemTask() {
        transferNumber = nil
        transferSession = nil
        transferGeneration = nil
    }
}

extension DownloadManager {
    private func incoming(_ job: StoredDownloadJob) -> URL? {
        guard let generation = job.transferGeneration, UUID(uuidString: generation) != nil else { return nil }
        return staging?.appendingPathComponent(generation + ".incoming")
    }
    private func discardIncoming(_ job: StoredDownloadJob) {
        if let file = incoming(job) { try? FileManager.default.removeItem(at: file) }
    }
    /// `repairStalled` (foreground only): a surviving task that has delivered no bytes and
    /// was either created while the app was not in the foreground (discretionary, may be
    /// deferred by iOS indefinitely) or has been waiting longer than `stallThreshold` is
    /// cancelled and requeued at its position, so it is recreated as a foreground task.
    /// At most once per job per activation.
    private func reconcileSystem(repairStalled: Bool = false) {
        guard let system, !reconciling, !halted else { return }
        reconciling = true
        let before = jobs.filter { $0.transferGeneration != nil }
        Task {
            let inventory = await system.inventory()
            var surviving = Set<String>()
            for task in inventory {
                guard let job = jobs.first(where: task.belongs),
                      !preferences.wifiOnly || task.session == BackgroundTransfers.wifi else {
                    task.cancel()
                    continue
                }
                let age = job.startedAt.map { Date().timeIntervalSince($0) } ?? .infinity
                if repairStalled, foreground, task.received == 0, (job.received ?? 0) == 0, !repairedThisActivation.contains(job.id),
                   createdInBackground.contains(job.id) || age >= stallThreshold {
                    repairedThisActivation.insert(job.id)
                    createdInBackground.remove(job.id)
                    task.cancel()
                    update(job.id) { $0.clearSystemTask(); $0.state = .queued }
                    schedulerLog.notice("recreatedStalledTransfer job=\(job.id, privacy: .public) position=\(job.position ?? -1) ageSeconds=\(Int(min(age, 1e9)))")
                    continue
                }
                surviving.insert(job.id)
                task.resumeIfSuspended()
                backgroundProgress(task)
            }
            for job in before where !surviving.contains(job.id) {
                guard jobs.first(where: { $0.id == job.id })?.transferGeneration == job.transferGeneration else { continue }
                // A callback may already have preserved the complete file before process death.
                if let file = incoming(job), FileManager.default.fileExists(atPath: file.path) {
                    finishStaging(job)
                } else {
                    // The task vanished without a callback: release its reservation.
                    update(job.id) { $0.clearSystemTask(); $0.state = .queued }
                }
            }
            reconciling = false
            schedulingRevision += 1
            schedule()
        }
    }
    func backgroundProgress(_ task: SystemDownload) {
        guard let job = jobs.first(where: task.belongs), let generation = job.transferGeneration.flatMap(UUID.init(uuidString:)),
              task.received >= (job.received ?? 0) else { return }
        attempts[job.id] = generation
        let expected = task.expected > 0 ? task.expected : job.expected ?? -1
        progress(job.id, attempt: generation, bytes: task.received, total: expected, now: ProcessInfo.processInfo.systemUptime)
    }
    func backgroundFile(_ task: SystemDownload, response: HTTPURLResponse?, location: URL) {
        guard let job = jobs.first(where: task.belongs), let destination = incoming(job) else { return }
        do {
            let length = try location.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            try DownloadMedia.validate(response: response, bytes: length)
            if !FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.moveItem(at: location, to: destination)
            }
        } catch { backgroundEnded(task, failure: error as? DownloadFailure ?? .disk) }
    }
    func backgroundEnded(_ task: SystemDownload, failure: DownloadFailure?) {
        guard let job = jobs.first(where: task.belongs) else { return }
        if let failure {
            discardIncoming(job)
            update(job.id) {
                $0.clearSystemTask()
                if failure == .terminated {
                    // Requeued at its original position, ahead of newer jobs.
                    $0.state = .queued; $0.errorMessage = nil
                } else if failure == .rejected && $0.refreshedGeneration != true {
                    $0.refreshedGeneration = true; $0.attempts = ($0.attempts ?? 0) + 1; $0.state = .queued
                } else {
                    $0.state = failure == .connection ? .interrupted : .failed
                    $0.errorMessage = failure.rawValue
                }
            }
        } else { finishStaging(job) }
        rates[job.id] = nil; samples[job.id] = nil; checkpoints[job.id] = nil; attempts[job.id] = nil
        // iOS woke the app for this event: verify staged audio and fill freed slots now
        // instead of waiting for the next foreground launch.
        if !foreground { beginOpportunity() } else { schedule() }
    }
    /// Lets the caller fill free slots while iOS is already executing the suspended app
    /// (for example after a playlist decision was committed in the background).
    func continueInBackgroundIfPossible() {
        if foreground { schedule() } else { beginOpportunity() }
    }
    private func beginOpportunity() {
        if opportunity == nil, let execution {
            opportunity = execution.begin("Muzik Belesh downloads") { [weak self] in
                // Expiry stops new work only. Running app workers resume with the app.
                self?.opportunity = nil
            }
        }
        schedule()
        endOpportunityIfIdle()
    }
    private func endOpportunityIfIdle() {
        guard !foreground, workers.isEmpty else { return }
        endOpportunity()
    }
    private func endOpportunity() {
        guard let token = opportunity else { return }
        opportunity = nil
        execution?.end(token)
    }
    private func finishStaging(_ job: StoredDownloadJob) {
        guard let incoming = incoming(job), let staging, UUID(uuidString: job.id) != nil else { return }
        let final = staging.appendingPathComponent(job.id + ".m4a")
        do {
            if !FileManager.default.fileExists(atPath: final.path) { try FileManager.default.moveItem(at: incoming, to: final) }
            let bytes = try final.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            guard bytes > 0 else { throw DownloadFailure.invalid }
            update(job.id) {
                $0.clearSystemTask(); $0.state = .queued; $0.received = Int64(bytes); $0.expected = Int64(bytes); $0.progress = 1
            }
        } catch {
            update(job.id) { $0.clearSystemTask(); $0.state = .failed; $0.errorMessage = DownloadFailure.disk.rawValue }
        }
    }
}
