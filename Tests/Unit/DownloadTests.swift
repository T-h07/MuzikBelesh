import AVFoundation
import GRDB
import XCTest
@testable import OFFLINE

@MainActor final class DownloadTests: XCTestCase {
    func testDurationCorrectionRequiresAgreementWithDecodedTimeline() {
        let doubles = YouTubeAudioTimeline(asset: 339, track: 169.7, fileFrames: 169.71, decoded: 169.70, presentationEnd: 169.71)
        XCTAssertEqual(doubles.correction(for: 339), 169.71)
        XCTAssertNil(doubles.correction(for: 169.7))
        XCTAssertNil(doubles.correction(for: 240))
        let gap = YouTubeAudioTimeline(asset: 339, track: 339, fileFrames: 169.71, decoded: 169.70, presentationEnd: 339)
        XCTAssertNil(gap.correction(for: 339))
    }

    func testAACWithInflatedMovieHeaderKeepsItsAudioTimeline() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("fixture.m4a")
        try await FixtureAudioTransfer().download(file, to: file, wifiOnly: true) { _, _ in }
        var bytes = try Data(contentsOf: file)
        let header = try XCTUnwrap(bytes.range(of: Data("mvhd".utf8)))
        let version = bytes[header.upperBound]
        let index = header.upperBound + (version == 1 ? 24 : 16)
        let width = version == 1 ? 8 : 4
        let field = index..<(index + width)
        var duration = bytes[field].reduce(UInt64(0)) { ($0 << 8) | UInt64($1) } * 2
        for i in field.reversed() { bytes[i] = UInt8(truncatingIfNeeded: duration); duration >>= 8 }
        try bytes.write(to: file)
        let sample = try await YouTubeAudioTimeline.inspect(file, source: 15)
        XCTAssertEqual(sample.decoded, 15, accuracy: 0.2)
        let reported = try await AVURLAsset(url: file).load(.duration).seconds
        XCTAssertEqual(sample.correction(for: reported) ?? reported, 15, accuracy: 0.2)
        print("Altered movie header: asset=\(reported), track=\(sample.track), fileFramesSeconds=\(sample.fileFrames), decoded=\(sample.decoded), end=\(sample.presentationEnd)")
    }
    func testHighFrequencyCallbacksHaveIndependentDisplayAndCheckpointCadences() {
        var ui = ProgressCadence(seconds: 0.5)
        var disk = ProgressCadence(seconds: 8)
        var published = 0, saved = 0
        for i in 0..<60_000 {
            let time = Double(i) / 1000
            if ui.due(at: time) {
                published += 1
                if disk.due(at: time) { saved += 1 }
            }
        }
        XCTAssertEqual(published, 120)
        XCTAssertEqual(saved, 8)
        var speed = TransferRate()
        XCTAssertTrue(speed.record(bytes: 0, at: 0))
        XCTAssertTrue(speed.record(bytes: 32_000, at: 1))
        XCTAssertEqual(speed.bytesPerSecond, 32_000)
        XCTAssertFalse(speed.record(bytes: 1, at: 2))
        XCTAssertTrue(speed.record(bytes: 96_000, at: 3))
        XCTAssertEqual(speed.bytesPerSecond, 32_000)
    }
    func testQueuePolicyOrderAndRecovery() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = try StorageCoordinator(paths: AppStoragePaths(root: root))
        let prefs = YouTubePreferences(defaults: UserDefaults(suiteName: UUID().uuidString)!)
        func manager() -> DownloadManager {
            DownloadManager(storage: storage, preferences: prefs, preparer: YouTubeDownloadPreparer(resolver: YouTubeUITestFixtures()), transfer: FixtureAudioTransfer(), artwork: YouTubeArtworkLoader(), observeNetwork: false)
        }
        let queue = manager()
        queue.setPath(connected: true, wifi: false)
        let first = YouTubeUITestFixtures.video
        queue.enqueue(first, quality: .high)
        queue.enqueue(first, quality: .standard)
        queue.enqueue(YouTubeVideo(id: "dQw4w9WgXcQ", title: "Second"), quality: .dataSaver)
        XCTAssertEqual(queue.jobs.count, 2)
        XCTAssertEqual(queue.jobs.first?.quality, AudioQuality.high.rawValue)
        XCTAssertEqual(queue.jobs.map(\.state), [.waitingForWiFi, .waitingForWiFi])
        queue.move(queue.jobs[1], by: -1)
        let reopened = manager()
        XCTAssertEqual(reopened.jobs.map(\.sourceIdentifier), ["dQw4w9WgXcQ", first.id])
        let job = reopened.jobs[0]
        reopened.pause(job)
        XCTAssertEqual(reopened.jobs[0].state, .paused)
        reopened.cancel(reopened.jobs[0])
        XCTAssertEqual(reopened.jobs[0].state, .cancelled)
        reopened.retry(job.id)
        XCTAssertEqual(reopened.jobs[0].state, .waitingForWiFi)
        XCTAssertEqual(try storage.downloads.all().count, 2)
    }
    func testConcurrencyPauseRetryAndPolicyUseOriginalJobQuality() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = try StorageCoordinator(paths: AppStoragePaths(root: root))
        let prefs = YouTubePreferences(defaults: UserDefaults(suiteName: UUID().uuidString)!)
        let transfer = BlockingTransfer()
        let queue = DownloadManager(storage: storage, preferences: prefs, preparer: YouTubeDownloadPreparer(resolver: YouTubeUITestFixtures()), transfer: transfer, artwork: YouTubeArtworkLoader(), observeNetwork: false)
        queue.setPath(connected: true, wifi: true)
        for index in 1...3 { queue.enqueue(YouTubeVideo(id: String(format: "fixture%04d", index), title: "Test"), quality: .dataSaver) }
        try await until { queue.jobs.filter { $0.state == .downloading && $0.received == 128 }.count == 2 }
        XCTAssertNil(queue.jobs[0].expected)
        prefs.simultaneous = 1
        queue.pause(queue.jobs[0])
        try await until { queue.jobs[0].state == .paused }
        XCTAssertEqual(queue.jobs[2].state, .queued)
        queue.setPath(connected: true, wifi: false)
        try await until { queue.jobs[1].state == .waitingForWiFi }
        prefs.wifiOnly = false
        try await until { queue.jobs[1].state == .downloading }
        queue.cancel(queue.jobs[1])
        try await until { queue.jobs[2].state == .downloading }
        queue.cancel(queue.jobs[2])
        queue.retry(queue.jobs[0].id)
        try await until { queue.jobs[0].state == .downloading }
        XCTAssertEqual(queue.jobs[0].quality, AudioQuality.dataSaver.rawValue)
        queue.cancel(queue.jobs[0])
        try await Task.sleep(for: .milliseconds(100))
    }
    func testRejectedURLRefreshIsBoundedAndCorruptBytesNeverImport() async throws {
        for rejected in [true, false] {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: root) }
            let storage = try StorageCoordinator(paths: AppStoragePaths(root: root))
            let queue = DownloadManager(storage: storage, preferences: YouTubePreferences(defaults: UserDefaults(suiteName: UUID().uuidString)!), preparer: YouTubeDownloadPreparer(resolver: YouTubeUITestFixtures()), transfer: InvalidTransfer(reject: rejected), artwork: YouTubeArtworkLoader(), observeNetwork: false)
            queue.setPath(connected: true, wifi: true)
            queue.enqueue(YouTubeUITestFixtures.video, quality: .high)
            try await until { queue.jobs.first?.state == .failed }
            XCTAssertEqual(queue.jobs.first?.attempts, rejected ? 1 : 0)
            XCTAssertEqual(queue.jobs.first?.errorMessage, rejected ? DownloadFailure.rejected.rawValue : DownloadFailure.invalid.rawValue)
            XCTAssertTrue(try storage.tracks.all().isEmpty)
        }
    }
    private func until(_ predicate: () -> Bool) async throws {
        for _ in 0..<200 {
            if predicate() { return }
            try await Task.sleep(for: .milliseconds(25))
        }
        XCTFail("Expected download state did not arrive")
    }
    func testPreferencesMigrateAndNetworkConfigurationPersists() {
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        for (old, new) in [("High", AudioQuality.high), ("Standard", .standard), ("Data Saver", .dataSaver)] {
            defaults.set(old, forKey: "youtube.audioQuality")
            let prefs = YouTubePreferences(defaults: defaults)
            XCTAssertEqual(prefs.quality, new)
            XCTAssertEqual(defaults.string(forKey: "youtube.audioQuality"), new.rawValue)
        }
        let prefs = YouTubePreferences(defaults: defaults)
        XCTAssertTrue(prefs.wifiOnly)
        XCTAssertEqual(prefs.simultaneous, 2)
        prefs.wifiOnly = false
        prefs.simultaneous = 3
        XCTAssertFalse(YouTubePreferences(defaults: defaults).wifiOnly)
        XCTAssertEqual(YouTubePreferences(defaults: defaults).simultaneous, 3)
    }
    func testTransferHostBoundary() {
        XCTAssertTrue(DownloadMedia.permits(URL(string: "https://r1.googlevideo.com/videoplayback")))
        for url in ["http://r1.googlevideo.com/", "https://r1.googlevideo.com.invalid/", "https://name@r1.googlevideo.com/", "https://r1.googlevideo.com:4433/", "https://www.youtube.com/"] {
            XCTAssertFalse(DownloadMedia.permits(URL(string: url)))
        }
    }
    func testDownloadedFixtureIsValidatedAndImportedOnceAcrossRestart() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = try StorageCoordinator(paths: AppStoragePaths(root: root))
        let prefs = YouTubePreferences(defaults: UserDefaults(suiteName: UUID().uuidString)!)
        let queue = DownloadManager(storage: storage, preferences: prefs, preparer: YouTubeDownloadPreparer(resolver: YouTubeUITestFixtures()), transfer: FixtureAudioTransfer(), artwork: YouTubeArtworkLoader(), observeNetwork: false)
        queue.setPath(connected: true, wifi: true)
        queue.enqueue(YouTubeUITestFixtures.video, quality: .high)
        for _ in 0..<100 where queue.jobs.first?.state != .completed {
            try await Task.sleep(for: .milliseconds(100))
        }
        let job = try XCTUnwrap(queue.jobs.first)
        XCTAssertEqual(job.state, .completed, job.errorMessage ?? "")
        let reopened = try StorageCoordinator(paths: AppStoragePaths(root: root))
        let track = try XCTUnwrap(reopened.tracks.all().first)
        XCTAssertEqual(track.id, job.trackID)
        XCTAssertEqual(track.title, "YouTube Fixture Song")
        try await DownloadMedia.validate(reopened.paths.musicURL(relativePath: track.fileRelativePath))
        XCTAssertEqual(try reopened.downloads.all().first?.state, .completed)
        let actual = try XCTUnwrap(track.durationMs)
        XCTAssertEqual(Double(actual) / 1000, 15, accuracy: 0.2)
        let url = try reopened.paths.musicURL(relativePath: track.fileRelativePath)
        XCTAssertEqual(job.received, track.fileSizeBytes)
        let lookup = YouTubeLibraryLookup(database: reopened.database.dbQueue, paths: reopened.paths)
        let metadata = YTMetadataStub(), resolver = YTResolverStub(error: .networkUnavailable)
        let model = VideoDetailsViewModel(video: YouTubeUITestFixtures.video, metadata: metadata, resolver: resolver, preparer: YouTubeDownloadPreparer(resolver: resolver), library: lookup)
        model.load(quality: .standard)
        await model.waitForRequest()
        XCTAssertEqual(model.state, .local)
        let resolverCalls = await resolver.calls, metadataCalls = await metadata.calls
        XCTAssertEqual(resolverCalls, 0)
        XCTAssertEqual(metadataCalls, 0)
        var doubled = track
        doubled.durationMs = actual * 2
        doubled.title = "An edited title"
        doubled.metadataSource = "local_edit"
        try reopened.tracks.save(doubled)
        try await reopened.repairYouTubeDurations()
        try await reopened.repairYouTubeDurations()
        let repaired = try XCTUnwrap(reopened.tracks.find(id: track.id))
        XCTAssertEqual(Double(try XCTUnwrap(repaired.durationMs)) / 1000, 15, accuracy: 0.2)
        doubled.durationMs = repaired.durationMs
        XCTAssertEqual(repaired, doubled)
        XCTAssertEqual(try reopened.audio.sha256(url: url), track.contentSHA256)
        let player = AudioPlayerService(storage: reopened)
        try await player.play(trackID: track.id)
        XCTAssertEqual(player.state.duration, Double(repaired.durationMs!) / 1000, accuracy: 0.001)
        print("Fixture playback UI seconds=\(player.state.duration) asset seconds=\(try await AVURLAsset(url: url).load(.duration).seconds) stored ms=\(repaired.durationMs!)")
        player.stop()
        var unfinished = job
        unfinished.state = .importing
        unfinished.trackID = nil
        try reopened.downloads.save(unfinished)
        let recovered = DownloadManager(storage: reopened, preferences: prefs, preparer: YouTubeDownloadPreparer(resolver: YouTubeUITestFixtures()), transfer: InvalidTransfer(reject: true), artwork: YouTubeArtworkLoader(), observeNetwork: false)
        recovered.setPath(connected: true, wifi: true)
        try await until { recovered.jobs.first?.state == .completed }
        XCTAssertEqual(recovered.jobs.first?.trackID, track.id)
        XCTAssertEqual(try reopened.tracks.all().count, 1)
    }
}

private struct BlockingTransfer: AudioTransferring {
    func download(_ url: URL, to destination: URL, wifiOnly: Bool, progress: @escaping @Sendable (Int64, Int64) -> Void) async throws {
        progress(128, -1)
        try await Task.sleep(for: .seconds(60))
    }
}
private struct InvalidTransfer: AudioTransferring {
    let reject: Bool
    func download(_ url: URL, to destination: URL, wifiOnly: Bool, progress: @escaping @Sendable (Int64, Int64) -> Void) async throws {
        if reject { throw DownloadFailure.rejected }
        try Data("corrupt".utf8).write(to: destination)
    }
}
