import AVFoundation
import Foundation
import GRDB
import XCTest
@testable import OFFLINE

/// Deterministic Phase 10.5 doubles. No live YouTube, network or notification service.

/// Audio transfer with an optional gate, concurrency accounting, scripted failures,
/// corrupt payloads and per-recording content seeds (distinct seeds → distinct SHA-256).
actor GatedAcquisitionTransfer: AudioTransferring {
    private var holding: Bool
    private var waiters: [UUID: CheckedContinuation<Void, Error>] = [:]
    private(set) var started: [String] = []
    private(set) var active = 0
    private(set) var maxActive = 0
    /// Number of transfers in flight (including this one) each time one starts.
    private(set) var activeAtStart: [Int] = []
    private var failures: [String: [DownloadFailure]] = [:]
    private var corrupt = Set<String>()
    private var seeds: [String: Int] = [:]

    init(holding: Bool = false) { self.holding = holding }

    func download(_ url: URL, to destination: URL, wifiOnly: Bool, progress: @escaping @Sendable (Int64, Int64) -> Void) async throws {
        let id = url.lastPathComponent
        started.append(id); active += 1; maxActive = max(maxActive, active); activeAtStart.append(active)
        defer { active -= 1 }
        if holding { try await hold() }
        try Task.checkCancellation()
        if var list = failures[id], !list.isEmpty {
            let failure = list.removeFirst(); failures[id] = list
            throw failure
        }
        progress(512, 1024)
        if corrupt.contains(id) {
            var bytes = Data([0, 0, 0, 24]); bytes.append(contentsOf: "ftypM4A ".utf8); bytes.append(Data(repeating: 7, count: 4096))
            try bytes.write(to: destination)
        } else {
            try AcquisitionToneAudio.write(to: destination, seed: seeds[id] ?? AcquisitionToneAudio.seed(id))
        }
    }

    private func hold() async throws {
        let token = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                waiters[token] = continuation
            }
        } onCancel: {
            Task { await self.cancel(token) }
        }
    }
    private func cancel(_ token: UUID) { waiters.removeValue(forKey: token)?.resume(throwing: CancellationError()) }

    /// Releases transfers already waiting; later transfers still wait.
    func releaseWaiting() { let pending = waiters.values; waiters.removeAll(); pending.forEach { $0.resume() } }
    func releaseAll() { holding = false; releaseWaiting() }
    func hold(_ value: Bool) { holding = value }
    var waiting: Int { waiters.count }
    func fail(_ id: String, _ list: [DownloadFailure]) { failures[id] = list }
    func corrupt(_ id: String) { corrupt.insert(id) }
    func heal(_ id: String) { corrupt.remove(id) }
    func seed(_ id: String, _ value: Int) { seeds[id] = value }
}

enum AcquisitionToneAudio {
    static func seed(_ id: String) -> Int { id.unicodeScalars.reduce(0) { ($0 * 31 + Int($1.value)) % 997 } }
    static func write(to destination: URL, seed: Int) throws {
        let settings: [String: Any] = [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 44100, AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: 64000]
        do {
            let file = try AVAudioFile(forWriting: destination, settings: settings)
            guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 44100),
                  let samples = buffer.floatChannelData?[0] else { throw DownloadFailure.invalid }
            buffer.frameLength = 44100
            let step = 0.02 + Double(seed % 200) * 0.0005
            for n in 0..<44100 { samples[n] = Float(sin(Double(n) * step) * 0.1) }
            for _ in 0..<2 { try file.write(from: buffer) }
        }
    }
}

/// Resolves every recording to a permitted audio-only stream unless scripted to fail.
final class AcquisitionTestPreparer: YouTubeDownloadPreparing, @unchecked Sendable {
    private let lock = NSLock()
    private var errors: [String: YouTubeError] = [:]
    private var calls: [String] = []
    func fail(_ id: String, with error: YouTubeError) { lock.withLock { errors[id] = error } }
    var prepared: [String] { lock.withLock { calls } }
    func prepare(video: YouTubeVideo, quality: AudioQuality) async throws -> PreparedYouTubeDownload {
        let error: YouTubeError? = lock.withLock { calls.append(video.id); return errors[video.id] }
        if let error { throw error }
        let option = AudioStreamOption(id: 140, container: "m4a", codec: "mp4a.40.2", bitrate: 128_000, isAudioOnly: true, isNativelyPlayable: true)
        let url = URL(string: "https://rr1---sn-test.googlevideo.com/videoplayback/" + video.id)!
        // No thumbnail: tests never fetch remote artwork.
        let metadata = YouTubeVideo(id: video.id, title: video.title, channel: video.channel, duration: video.duration, availability: .available)
        let stream = ResolvedAudioStream(video: metadata, options: [option], selected: option, url: url, resolvedAt: Date(), expiresAt: Date().addingTimeInterval(600))
        return PreparedYouTubeDownload(videoID: video.id, metadata: metadata, quality: quality, stream: stream)
    }
}

@MainActor final class RecordingAcquisitionNotifier: PlaylistAcquisitionNotifying {
    var onOpenPlaylist: ((String) -> Void)?
    var permitted = true
    private(set) var authorizationRequests = 0
    private(set) var attempts: [(identifier: String, title: String, body: String)] = []
    var ready: [String] { attempts.filter { $0.title == "Playlist Ready Offline" }.map(\.body) }
    var partial: [String] { attempts.filter { $0.title == "Playlist Downloads Finished" }.map(\.body) }
    func requestAuthorizationIfUndetermined() async { authorizationRequests += 1 }
    func deliver(identifier: String, title: String, body: String, playlistID: String) async -> Bool {
        attempts.append((identifier, title, body)); return permitted
    }
}

@MainActor final class RecordingBackgroundExecution: BackgroundExecutionGranting {
    private(set) var began = 0
    private(set) var ended = 0
    private var next = 1
    private var open = Set<Int>()
    var active: Int { open.count }
    func begin(_ name: String, expired: @escaping @MainActor () -> Void) -> Int? {
        began += 1; next += 1; open.insert(next); return next
    }
    func end(_ token: Int) { if open.remove(token) != nil { ended += 1 } }
}

@MainActor final class AcquisitionTestSystem: SystemDownloading {
    weak var owner: DownloadManager?
    var tasks: [SystemDownload] = []
    var created = 0
    func inventory() async -> [SystemDownload] { tasks }
    func create(url: URL, job: String, generation: String, strict: Bool) throws -> SystemDownload {
        created += 1
        let number = created
        let item = SystemDownload(session: strict ? BackgroundTransfers.wifi : BackgroundTransfers.mobile, number: number,
                                  description: job + "/" + generation, received: 0, expected: -1, resumeIfSuspended: {}, cancel: {})
        tasks.append(item)
        return item
    }
    func cancel(session: String, number: Int) { tasks.removeAll { $0.number == number } }
}

/// One isolated library plus the production DownloadManager and coordinator wired the
/// way AppContainer wires them. `launch()` reconstructs both, like an app relaunch.
@MainActor final class AcquisitionHarness {
    let fixture: LibraryFixture
    let prefs: YouTubePreferences
    let preparer = AcquisitionTestPreparer()
    let notifier = RecordingAcquisitionNotifier()
    private(set) var transfer: GatedAcquisitionTransfer
    private(set) var downloads: DownloadManager!
    private(set) var coordinator: PlaylistAcquisitionCoordinator!
    var storage: StorageCoordinator { fixture.storage }
    var repo: GRDBPlaylistMigrationRepository { fixture.storage.playlistMigrations }

    init(limit: Int = 3, wifiOnly: Bool = false, holding: Bool = false, start: Bool = true) throws {
        fixture = try LibraryFixture(count: 0)
        prefs = YouTubePreferences(defaults: UserDefaults(suiteName: "acquisition-" + UUID().uuidString)!)
        prefs.simultaneous = limit
        prefs.wifiOnly = wifiOnly
        transfer = GatedAcquisitionTransfer(holding: holding)
        launch(start: start)
    }

    func launch(start: Bool = true, transfer replacement: GatedAcquisitionTransfer? = nil, connected: Bool = true, wifi: Bool = true) {
        if let replacement { transfer = replacement }
        downloads = DownloadManager(storage: storage, preferences: prefs, preparer: preparer, transfer: transfer,
                                    artwork: YouTubeArtworkLoader(), observeNetwork: false)
        downloads.setPath(connected: connected, wifi: wifi)
        coordinator = PlaylistAcquisitionCoordinator(storage: storage, downloads: downloads, preferences: prefs, notifier: notifier,
                                                     retryDelay: { _ in 0.05 }, debounce: .milliseconds(10))
        if start { coordinator.start() }
    }

    static func video(_ index: Int) -> String { String(format: "acq%08d", index) }

    /// Imports a playlist and, for each non-nil recording, saves one pending YouTube
    /// candidate; `confirm` selects it exactly as the review queue does.
    @discardableResult
    func playlist(_ name: String, _ videos: [String?], confirm: Bool = true) async throws -> (session: PlaylistMigrationSession, entries: [PlaylistMigrationEntry]) {
        let source = PlaylistMigrationSourcePlaylist(source: .exportify, name: name, entries: videos.indices.map {
            PlaylistMigrationSourceTrack(position: $0, title: "\(name) song \($0)", primaryArtist: "Artist", album: "Album", durationMs: 2000)
        })
        let session = try await repo.createPlaylist(from: source, operationID: name + "-" + UUID().uuidString)
        let entries = try await repo.entries(migrationID: session.id)
        for (index, video) in videos.enumerated() {
            guard let video else { continue }
            let candidate = PlaylistMigrationCandidate(id: UUID(), entryID: entries[index].id, provider: "youtube", providerTrackID: video,
                title: "Artist - \(name) song \(index)", artist: "Artist", durationMs: 2000, confidence: 0.9,
                evidence: ["currentAttempt": "true", "rank": "1", "outcome": "review", "channel": "Channel"], decision: .pending)
            try await storage.database.dbQueue.write { try GRDBPlaylistMigrationRepository.insertFixtureCandidate(candidate, db: $0) }
            if confirm { try await repo.selectCandidate(for: entries[index], candidateID: candidate.id) }
        }
        return (session, try await repo.entries(migrationID: session.id))
    }

    func entries(_ session: PlaylistMigrationSession) async throws -> [PlaylistMigrationEntry] {
        try await repo.entries(migrationID: session.id)
    }
    func jobs() throws -> [StoredDownloadJob] { try storage.downloads.all().filter { $0.position != nil } }
    func trackCount() async throws -> Int { try await storage.database.dbQueue.read { try StoredTrack.fetchCount($0) } }
    func links() async throws -> [AcquisitionLinkRecord] { try await storage.database.dbQueue.read { try AcquisitionLinkRecord.fetchAll($0) } }

    func allReady(_ session: PlaylistMigrationSession) async throws -> Bool {
        try await entries(session).allSatisfy { $0.status == .ready && $0.localTrackID != nil }
    }

    func until(_ message: String = "Condition", timeout: Double = 30, file: StaticString = #filePath, line: UInt = #line,
               _ condition: () async throws -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if try await condition() { return }
            try await Task.sleep(for: .milliseconds(25))
        }
        XCTFail("\(message) did not happen within \(timeout)s", file: file, line: line)
        throw CancellationError()
    }

    /// Lets queued debounced passes finish and asserts nothing else changes.
    func settle() async {
        try? await Task.sleep(for: .milliseconds(300))
        await coordinator.reconcileNow()
    }
}
