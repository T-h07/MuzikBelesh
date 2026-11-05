import Combine
import Foundation
import Network

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
    private let artwork: YouTubeArtworkLoader
    private let monitor = NWPathMonitor()
    private var subscriptions = Set<AnyCancellable>()
    private var connected = false
    private var wifi = false
    private var workers: [String: Task<Void, Never>] = [:]
    private var samples: [String: (Date, Int64)] = [:]
    private var attempts: [String: UUID] = [:]
    private var foreground = true
    private var storageFailed = false
    private var staging: URL? { storage?.paths.applicationSupport.appendingPathComponent("DownloadStaging", isDirectory: true) }

    init(storage: StorageCoordinator?, preferences: YouTubePreferences, preparer: any YouTubeDownloadPreparing,
         transfer: any AudioTransferring, artwork: YouTubeArtworkLoader, observeNetwork: Bool = true) {
        self.storage = storage
        self.preferences = preferences
        self.preparer = preparer
        self.transfer = transfer
        self.artwork = artwork
        do {
            guard let storage, let staging else { throw DownloadFailure.disk }
            try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
            jobs = try storage.downloads.all().filter { $0.position != nil }.sorted { ($0.position ?? 0) < ($1.position ?? 0) }
            for job in jobs where [.downloading, .verifying, .importing, .resolving].contains(job.state) {
                update(job.id) { $0.state = .queued }
            }
        } catch { failStorage() }
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
        if !connected || (preferences.wifiOnly && !wifi) { policyChanged(strict: true) }
        if regainedConnection {
            for job in jobs where job.state == .interrupted { update(job.id) { $0.state = .queued; $0.errorMessage = nil } }
        }
        schedule()
    }
    func setForeground(_ active: Bool) {
        foreground = active
        if active {
            for job in jobs where job.state == .interrupted { update(job.id) { $0.state = .queued; $0.errorMessage = nil } }
            schedule()
        } else { policyChanged(strict: true) }
    }
    private func policyChanged(strict: Bool) {
        guard strict else { return }
        for job in jobs where job.state == .downloading || job.state == .resolving {
            stop(job.id, as: .queued)
        }
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
        guard !storageFailed, foreground else { return }
        let waiting = preferences.wifiOnly && !wifi
        for job in jobs where job.state.pending {
            let staged = UUID(uuidString: job.id) != nil && staging.map { FileManager.default.fileExists(atPath: $0.appendingPathComponent(job.id + ".m4a").path) } == true
            let desired: StoredDownloadState = waiting && !staged ? .waitingForWiFi : .queued
            if job.state != desired { update(job.id) { $0.state = desired } }
            guard staged || (!waiting && connected), workers.count < preferences.simultaneous, workers[job.id] == nil else { continue }
            guard update(job.id, { $0.state = .resolving; $0.startedAt = Date(); $0.received = 0; $0.expected = nil; $0.progress = 0 }) else { return }
            workers[job.id] = Task { await run(job) }
        }
    }
    private func run(_ job: StoredDownloadJob) async {
        defer { workers[job.id] = nil; rates[job.id] = nil; attempts[job.id] = nil; samples[job.id] = nil; schedule() }
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
                    guard update(job.id, { $0.state = .downloading; $0.received = 0; $0.expected = nil; $0.progress = 0 }) else { return }
                    let sampleID = job.id
                    let generation = UUID()
                    attempts[job.id] = generation
                    do {
                        try await transfer.download(request.stream.url, to: file, wifiOnly: preferences.wifiOnly) { bytes, total in
                            Task { @MainActor in self.progress(sampleID, attempt: generation, bytes: bytes, total: total) }
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
            guard update(job.id, { $0.state = .verifying }) else { return }
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
                try? FileManager.default.removeItem(at: file)
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
    private func progress(_ id: String, attempt: UUID, bytes: Int64, total: Int64) {
        guard attempts[id] == attempt, jobs.first(where: { $0.id == id })?.state == .downloading else { return }
        let now = Date()
        if let (time, previous) = samples[id] {
            let elapsed = now.timeIntervalSince(time)
            guard elapsed >= 1, bytes >= previous else { return }
            let rate = Double(bytes - previous) / elapsed
            rates[id] = (rates[id] ?? rate) * 0.6 + rate * 0.4
        }
        samples[id] = (now, bytes)
        update(id) { $0.received = bytes; $0.expected = total > 0 ? total : nil; $0.progress = total > 0 ? min(1, Double(bytes) / Double(total)) : 0 }
    }
    private func stop(_ id: String, as state: StoredDownloadState) {
        guard update(id, { $0.state = state }) else { return }
        workers[id]?.cancel()
    }
    func pause(_ job: StoredDownloadJob) { if jobs.first(where: { $0.id == job.id })?.state.stoppable == true { stop(job.id, as: .paused) } }
    func cancel(_ job: StoredDownloadJob) {
        guard let job = jobs.first(where: { $0.id == job.id }), job.state.stoppable || job.state == .paused || job.state == .interrupted else { return }
        stop(job.id, as: .cancelled)
    }
    func retry(_ id: String, repair: Bool = false) {
        guard let job = jobs.first(where: { $0.id == id }), [.paused, .cancelled, .failed, .interrupted].contains(job.state) || (repair && job.state == .completed) else { return }
        update(id) { $0.state = .queued; $0.errorMessage = nil; $0.attempts = ($0.attempts ?? 0) + 1 }
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
