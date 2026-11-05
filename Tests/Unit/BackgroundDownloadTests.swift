import Combine
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
    private func awaitImport(_ manager: DownloadManager) async {
        for await jobs in manager.$jobs.values {
            guard let job = jobs.first else { continue }
            if [.completed, .failed, .interrupted, .cancelled].contains(job.state) {
                XCTAssertEqual(job.state, .completed, job.errorMessage ?? "")
                return
            }
        }
        XCTFail("Job publisher ended before import")
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
        await awaitImport(restored)
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

    func testSystemResponseSecurityAndSessionHandoff() throws {
        func response(_ host: String = "r.googlevideo.com", code: Int = 200, type: String = "audio/mp4", length: String = "100") -> HTTPURLResponse {
            HTTPURLResponse(url: URL(string: "https://" + host + "/media")!, statusCode: code, httpVersion: nil,
                            headerFields: ["Content-Type": type, "Content-Length": length])!
        }
        try DownloadMedia.validate(response: response(), bytes: 100)
        for invalid in [response("example.org"), response(code: 206), response(type: "text/html"), response(length: "99")] {
            XCTAssertThrowsError(try DownloadMedia.validate(response: invalid, bytes: 100))
        }
        XCTAssertThrowsError(try DownloadMedia.validate(response: response(code: 410), bytes: 100)) { XCTAssertEqual($0 as? DownloadFailure, .rejected) }
        XCTAssertThrowsError(try DownloadMedia.validate(response: response(), bytes: Int(DownloadMedia.limit) + 1)) { XCTAssertEqual($0 as? DownloadFailure, .size) }
        var handoff = BackgroundEventHandoff(), called: [Int] = []
        handoff.retain({ called.append(1) }, for: BackgroundTransfers.wifi)
        handoff.retain({ called.append(2) }, for: BackgroundTransfers.mobile)
        XCTAssertTrue(called.isEmpty)
        handoff.takeHandlers(for: BackgroundTransfers.mobile).forEach { $0() }
        XCTAssertEqual(called, [2])
        handoff.takeHandlers(for: BackgroundTransfers.wifi).forEach { $0() }
        XCTAssertTrue(handoff.takeHandlers(for: BackgroundTransfers.wifi).isEmpty)
        XCTAssertEqual(called, [2, 1])
    }

    func testMissingTaskRecoversWithFreshIdentityAndRejectsDuplicateClaim() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = try StorageCoordinator(paths: AppStoragePaths(root: root))
        let prefs = YouTubePreferences(defaults: UserDefaults(suiteName: UUID().uuidString)!)
        let system = TestSystem()
        let manager = makeManager(storage, prefs, system)
        manager.setForeground(true)
        manager.setPath(connected: true, wifi: true)
        manager.enqueue(YouTubeUITestFixtures.video, quality: .dataSaver)
        try await until { system.created == 1 }
        let original = system.tasks[0]
        system.tasks.removeAll()
        manager.setForeground(false)
        manager.setForeground(true)
        try await until { system.created == 2 }
        XCTAssertFalse(original.belongs(to: manager.jobs[0]))
        let current = system.tasks[0]
        let duplicate = SystemDownload(session: current.session, number: 77, description: current.description,
                                       received: 0, expected: -1, resumeIfSuspended: {},
                                       cancel: { system.cancelled.insert(77) })
        system.tasks.append(duplicate)
        manager.setForeground(true)
        try await until { system.cancelled.contains(77) }
        XCTAssertTrue(current.belongs(to: manager.jobs[0]))
        XCTAssertEqual(system.created, 2)
        manager.cancel(manager.jobs[0])
        manager.backgroundEnded(current, failure: nil)
        XCTAssertEqual(manager.jobs[0].state, .cancelled)
        XCTAssertEqual(manager.jobs[0].quality, AudioQuality.dataSaver.rawValue)
    }

    func testExpiredBackgroundAttemptGetsOneRefreshOnly() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = try StorageCoordinator(paths: AppStoragePaths(root: root))
        let prefs = YouTubePreferences(defaults: UserDefaults(suiteName: UUID().uuidString)!)
        let system = TestSystem(), video = YouTubeUITestFixtures.video
        let manager = makeManager(storage, prefs, system)
        manager.setForeground(true)
        manager.setPath(connected: true, wifi: true)
        manager.enqueue(video, quality: .dataSaver)
        try await until { system.created == 1 }
        let jobID = manager.jobs[0].id
        manager.backgroundEnded(system.tasks[0], failure: .rejected)
        try await until { system.created == 2 }
        manager.backgroundEnded(system.tasks[1], failure: .rejected)
        XCTAssertEqual(manager.jobs[0].id, jobID)
        XCTAssertEqual(manager.jobs[0].quality, AudioQuality.dataSaver.rawValue)
        XCTAssertEqual(manager.jobs[0].state, .failed)
        XCTAssertEqual(try storage.downloads.all()[0].attempts, 1)
    }

    func testRelaunchBetweenTemporaryMoveAndTerminalCallbackImportsWithoutNetwork() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = try StorageCoordinator(paths: AppStoragePaths(root: root))
        let prefs = YouTubePreferences(defaults: UserDefaults(suiteName: UUID().uuidString)!)
        let system = TestSystem()
        var first: DownloadManager? = makeManager(storage, prefs, system)
        first?.setForeground(true)
        first?.setPath(connected: true, wifi: true)
        first?.enqueue(YouTubeUITestFixtures.video, quality: .high)
        try await until { system.created == 1 }
        let task = system.tasks[0]
        let file = root.appendingPathComponent("completed.m4a")
        try await FixtureAudioTransfer().download(file, to: file, wifiOnly: true) { _, _ in }
        let response = HTTPURLResponse(url: URL(string: "https://r.googlevideo.com/audio")!, statusCode: 200,
                                       httpVersion: nil, headerFields: ["Content-Type": "audio/mp4"])
        first?.backgroundFile(task, response: response, location: file)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
        first = nil
        system.tasks.removeAll()
        let recovered = makeManager(storage, prefs, system)
        recovered.setForeground(true)
        recovered.setPath(connected: false, wifi: false)
        await awaitImport(recovered)
        XCTAssertEqual(system.created, 1)
        XCTAssertNil(try storage.downloads.all()[0].transferNumber)
        XCTAssertEqual(try storage.tracks.all().count, 1)
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
