import Foundation
import GRDB
import XCTest
@testable import OFFLINE

@MainActor final class BackgroundDownloadTests: XCTestCase {
    private func makeManager(_ storage: StorageCoordinator, _ prefs: YouTubePreferences, _ system: TestSystem) -> DownloadManager {
        DownloadManager(storage: storage, preferences: prefs, preparer: YouTubeDownloadPreparer(resolver: YouTubeUITestFixtures()), transfer: FixtureAudioTransfer(), artwork: YouTubeArtworkLoader(), observeNetwork: false, system: system)
    }
    private func until(_ condition: () -> Bool) async throws {
        for _ in 0..<200 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(30))
        }
        XCTFail("Requested transfer state did not arrive")
    }
    func testRestoreSameTaskThenFinishWhileBackgroundedAndImportOffline() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = try StorageCoordinator(paths: AppStoragePaths(root: root))
        let prefs = YouTubePreferences(defaults: UserDefaults(suiteName: UUID().uuidString)!)
        let system = TestSystem()
        var manager: DownloadManager? = makeManager(storage, prefs, system)
        manager?.setForeground(true)
        manager?.setPath(connected: true, wifi: true)
        manager?.enqueue(YouTubeUITestFixtures.video, quality: .high)
        try await until { system.tasks.count == 1 }
        let original = system.tasks[0]
        manager?.backgroundProgress(original)
        manager?.setForeground(false)
        manager?.setPath(connected: true, wifi: false)
        XCTAssertTrue(system.cancelled.isEmpty)
        manager = nil
        let restored = makeManager(storage, prefs, system)
        restored.setForeground(false)
        try await until { system.enumerations >= 2 }
        let job = try XCTUnwrap(restored.jobs.first)
        XCTAssertTrue(original.belongs(to: job))
        XCTAssertEqual(job.received, 1024)
        let file = root.appendingPathComponent("download.m4a")
        try await FixtureAudioTransfer().download(file, to: file, wifiOnly: true) { _, _ in }
        let bytes = try file.resourceValues(forKeys: [.fileSizeKey]).fileSize!
        let response = HTTPURLResponse(url: URL(string: "https://r.googlevideo.com/audio")!, statusCode: 200, httpVersion: nil,
                                       headerFields: ["Content-Type": "audio/mp4", "Content-Length": String(bytes)])
        restored.backgroundFile(original, response: response, location: file)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
        restored.backgroundEnded(original, failure: nil)
        system.tasks.removeAll()
        XCTAssertEqual(try storage.downloads.all().first?.received, Int64(bytes))
        restored.setForeground(true)
        try await until { restored.jobs.first?.state == .completed }
        restored.backgroundEnded(original, failure: .connection)
        XCTAssertEqual(restored.jobs.first?.state, .completed)
        XCTAssertEqual(system.created, 1)
        XCTAssertEqual(try storage.tracks.all().count, 1)
    }
    func testPolicyChangePauseAndLateCallbacks() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = try StorageCoordinator(paths: AppStoragePaths(root: root))
        let prefs = YouTubePreferences(defaults: UserDefaults(suiteName: UUID().uuidString)!)
        prefs.wifiOnly = false
        let system = TestSystem()
        let queue = makeManager(storage, prefs, system)
        queue.setForeground(true)
        queue.setPath(connected: true, wifi: false)
        queue.enqueue(YouTubeUITestFixtures.video, quality: .high)
        try await until { system.tasks.count == 1 }
        let old = system.tasks[0]
        XCTAssertEqual(old.session, BackgroundTransfers.mobile)
        prefs.wifiOnly = true
        try await until { queue.jobs.first?.state == .waitingForWiFi }
        XCTAssertTrue(system.cancelled.contains(old.number))
        queue.backgroundEnded(old, failure: .invalid)
        queue.setPath(connected: true, wifi: true)
        try await until { system.created == 2 }
        let restrictive = try XCTUnwrap(system.tasks.last)
        XCTAssertEqual(restrictive.session, BackgroundTransfers.wifi)
        queue.pause(queue.jobs[0])
        queue.backgroundEnded(restrictive, failure: nil)
        XCTAssertEqual(queue.jobs[0].state, .paused)
        XCTAssertNil(queue.jobs[0].transferGeneration)
    }
    func testConfigurationAndPhase7Upgrade() throws {
        let strict = BackgroundTransfers.config(BackgroundTransfers.wifi)
        XCTAssertFalse(strict.allowsCellularAccess)
        XCTAssertTrue(strict.sessionSendsLaunchEvents)
        XCTAssertFalse(strict.isDiscretionary)
        XCTAssertFalse(strict.httpShouldSetCookies)
        XCTAssertTrue(BackgroundTransfers.config(BackgroundTransfers.mobile).allowsCellularAccess)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = try AppStoragePaths(root: root)
        let old = try DatabaseManager(url: paths.database, migrationTarget: "v011_audio_downloads")
        try old.dbQueue.write { db in
            try db.execute(sql: "INSERT INTO download_jobs (id, sourceType, sourceIdentifier, state, progress, quality, position, dateAdded, dateModified) VALUES (?, 'youtube', '9bZkp7q19f0', 'completed', 1, 'Balanced', 1, ?, ?)", arguments: [UUID().uuidString, Date(), Date()])
        }
        let storage = try StorageCoordinator(paths: paths)
        let job = try XCTUnwrap(storage.downloads.all().first)
        XCTAssertEqual(job.state, .completed)
        XCTAssertNil(job.transferGeneration)
    }
}
@MainActor private final class TestSystem: SystemDownloading {
    weak var owner: DownloadManager?
    var tasks: [SystemDownload] = []
    var created = 0, enumerations = 0
    var cancelled = Set<Int>()
    func inventory() async -> [SystemDownload] { enumerations += 1; return tasks }
    func create(url: URL, job: String, generation: String, strict: Bool) throws -> SystemDownload {
        created += 1
        let number = created
        let item = SystemDownload(session: strict ? BackgroundTransfers.wifi : BackgroundTransfers.mobile, number: number,
                                  description: job + "/" + generation, received: 1024, expected: -1, resumeIfSuspended: {},
                                  cancel: { [weak self] in self?.cancelled.insert(number) })
        tasks.append(item)
        return item
    }
    func cancel(session: String, number: Int) { cancelled.insert(number); tasks.removeAll { $0.number == number } }
}
