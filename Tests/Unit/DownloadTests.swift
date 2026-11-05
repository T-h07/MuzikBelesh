import GRDB
import XCTest
@testable import OFFLINE

@MainActor final class DownloadTests: XCTestCase {
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
    }
}
