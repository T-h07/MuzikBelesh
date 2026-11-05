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
    private var foreground = true
    private var storageFailed = false
    private var staging: URL? { storage?.paths.applicationSupport.appendingPathComponent("DownloadStaging", isDirectory: true) }

    init(storage: StorageCoordinator?, preferences: YouTubePreferences, preparer: any YouTubeDownloadPreparing,
         transfer: any AudioTransferring, artwork: YouTubeArtworkLoader, observeNetwork: Bool = true,
         system: (any SystemDownloading)? = nil) {
        self.system = system
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
            reconcileSystem()
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
    }
    deinit { monitor.cancel() }
    func setPath(connected: Bool, wifi: Bool) {
        let regainedConnection = connected && (!self.connected || (wifi && !self.wifi))
        self.connected = connected
        self.wifi = wifi
        if system == nil && (!connected || (preferences.wifiOnly && !wifi)) { policyChanged(strict: true) }
        if regainedConnection {
            for job in jobs where job.state == .interrupted { update(job.id) { $0.state = .queued; $0.errorMessage = nil } }
        }
        schedule()
    }
    func setForeground(_ active: Bool) {
        foreground = active
        if active {
            rates.removeAll(); samples.removeAll()
            reconcileSystem()
            for job in jobs where job.state == .interrupted { update(job.id) { $0.state = .queued; $0.errorMessage = nil } }
            schedule()
        }
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
        return job.state.label
    }
    func job(for videoID: String) -> StoredDownloadJob? { jobs.first { $0.sourceIdentifier == videoID } }
    private func failStorage() { storageFailed = true; issue = "Download storage is unavailable. Reopen the app to retry." }
    @discardableResult private func update(_ id: String, _ change: (inout StoredDownloadJob) -> Void) -> Bool {
        guard !storageFailed, let index = jobs.firstIndex(where: { $0.id == id }), let storage else { return false }
        var job = jobs[index]
        change(&job)
        job.dateModified = Date()
        do { try storage.downloads.save(job); jobs[index] = job; return true }
        catch { failStorage(); return false }
    }
    func enqueue(_ video: YouTubeVideo, quality: AudioQuality) {
        guard !storageFailed, let storage, YouTubeURLValidator.isValidID(video.id) else { return }
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
    private func schedule() {
        guard !storageFailed, foreground, !reconciling else { return }
        let waiting = preferences.wifiOnly && !wifi
        for job in jobs where job.state.pending {
            let staged = UUID(uuidString: job.id) != nil && staging.map { FileManager.default.fileExists(atPath: $0.appendingPathComponent(job.id + ".m4a").path) } == true
            let desired: StoredDownloadState = waiting && !staged ? .waitingForWiFi : .queued
            if job.state != desired { update(job.id) { $0.state = desired } }
            let slots = workers.count + jobs.filter { $0.transferGeneration != nil && workers[$0.id] == nil }.count
            guard staged || (!waiting && connected), slots < preferences.simultaneous, workers[job.id] == nil else { continue }
            guard update(job.id, { $0.state = staged ? .verifying : .resolving }) else { return }
            workers[job.id] = Task { await run(job) }
        }
    }
    private func run(_ job: StoredDownloadJob) async {
        defer { workers[job.id] = nil; rates[job.id] = nil; attempts[job.id] = nil; samples[job.id] = nil; checkpoints[job.id] = nil; schedule() }
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
                    if let system {
                        let generation = UUID().uuidString
                        let task = try system.create(url: request.stream.url, job: job.id, generation: generation, strict: preferences.wifiOnly)
                        guard update(job.id, {
                            $0.state = .downloading; $0.received = 0; $0.expected = nil; $0.progress = 0
                            $0.startedAt = Date(); $0.transferNumber = task.number; $0.transferSession = task.session
                            $0.transferGeneration = generation; $0.title = video.title; $0.channel = video.channel
                            $0.thumbnail = YouTubeImageURL.valid(video.thumbnailURL)?.absoluteString
                        }) else { task.cancel(); return }
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
        guard attempts[id] == attempt, jobs.first(where: { $0.id == id })?.state == .downloading else { return }
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
        guard let job = jobs.first(where: { $0.id == id }), update(id, { $0.state = state; $0.clearSystemTask() }) else { return }
        if let name = job.transferSession, let number = job.transferNumber { system?.cancel(session: name, number: number) }
        discardIncoming(job)
        workers[id]?.cancel()
        if state == .cancelled, workers[id] == nil, UUID(uuidString: id) != nil, let staging {
            try? FileManager.default.removeItem(at: staging.appendingPathComponent(id + ".m4a"))
        }
    }
    func pause(_ job: StoredDownloadJob) { if jobs.first(where: { $0.id == job.id })?.state.stoppable == true { stop(job.id, as: .paused) } }
    func cancel(_ job: StoredDownloadJob) {
        guard let job = jobs.first(where: { $0.id == job.id }), job.state.stoppable || job.state == .paused || job.state == .interrupted else { return }
        stop(job.id, as: .cancelled)
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
    private func reconcileSystem() {
        guard let system, !reconciling, !storageFailed else { return }
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
                    update(job.id) { $0.clearSystemTask(); $0.state = .queued }
                }
            }
            reconciling = false
            schedule()
        }
    }
    func backgroundProgress(_ task: SystemDownload) {
        guard let job = jobs.first(where: task.belongs), let generation = job.transferGeneration.flatMap(UUID.init(uuidString:)),
              task.received >= (job.received ?? 0) else { return }
        attempts[job.id] = generation
        progress(job.id, attempt: generation, bytes: task.received, total: task.expected, now: ProcessInfo.processInfo.systemUptime)
    }
    func backgroundFile(_ task: SystemDownload, response: HTTPURLResponse?, location: URL) {
        guard let job = jobs.first(where: task.belongs), let destination = incoming(job) else { return }
        do {
            guard let response, DownloadMedia.permits(response.url) else { throw DownloadFailure.invalid }
            if [401,403,410].contains(response.statusCode) { throw DownloadFailure.rejected }
            let length = try location.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            guard length <= DownloadMedia.limit else { throw DownloadFailure.size }
            guard length > 0, response.statusCode == 200,
                  ["audio/mp4", "audio/m4a", "audio/x-m4a", "application/octet-stream"].contains(response.mimeType ?? ""),
                  response.expectedContentLength < 0 || response.expectedContentLength == Int64(length) else { throw DownloadFailure.invalid }
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
                if failure == .rejected && $0.refreshedGeneration != true {
                    $0.refreshedGeneration = true; $0.attempts = ($0.attempts ?? 0) + 1; $0.state = .queued
                } else {
                    $0.state = failure == .connection ? .interrupted : .failed
                    $0.errorMessage = failure.rawValue
                }
            }
        } else { finishStaging(job) }
        rates[job.id] = nil; samples[job.id] = nil; checkpoints[job.id] = nil; attempts[job.id] = nil
        schedule()
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
