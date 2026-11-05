import Foundation
import UIKit
import OSLog

struct SystemDownload {
    let session: String
    let number: Int
    let description: String?
    let received: Int64
    let expected: Int64
    let resumeIfSuspended: () -> Void
    let cancel: () -> Void

    func belongs(to job: StoredDownloadJob) -> Bool {
        guard let generation = job.transferGeneration, UUID(uuidString: generation) != nil,
              UUID(uuidString: job.id) != nil else { return false }
        return job.state == .downloading && job.transferSession == session && job.transferNumber == number
            && description == job.id + "/" + generation
    }
}

@MainActor protocol SystemDownloading: AnyObject {
    var owner: DownloadManager? { get set }
    func inventory() async -> [SystemDownload]
    func create(url: URL, job: String, generation: String, strict: Bool) throws -> SystemDownload
    func cancel(session: String, number: Int)
}

@MainActor final class BackgroundTransfers: NSObject, SystemDownloading {
    static let shared = BackgroundTransfers()
    static let prefix = "com.th07.muzikbelesh.downloads.v1."
    static let wifi = prefix + "wifi"
    static let mobile = prefix + "mobile"
    weak var owner: DownloadManager?
    private var sessions: [String: URLSession] = [:]
    private var handoff = BackgroundEventHandoff()
    private var active: [String: [Int: URLSessionTask]] = [:]
    private lazy var delegate = BackgroundDelegate(owner: self)
    private let events: OperationQueue = {
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        queue.name = "OFFLINE.background.download-events"
        return queue
    }()

    static func config(_ name: String) -> URLSessionConfiguration {
        let config = URLSessionConfiguration.background(withIdentifier: name)
        config.sessionSendsLaunchEvents = true
        config.isDiscretionary = false
        config.allowsCellularAccess = name == mobile
        config.allowsExpensiveNetworkAccess = true
        config.allowsConstrainedNetworkAccess = true
        config.waitsForConnectivity = true
        config.timeoutIntervalForResource = 6 * 3600
        config.httpShouldSetCookies = false
        config.httpCookieStorage = nil
        config.urlCredentialStorage = nil
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        return config
    }
    private func session(_ name: String) -> URLSession {
        if let existing = sessions[name] { return existing }
        let session = URLSession(configuration: Self.config(name), delegate: delegate, delegateQueue: events)
        sessions[name] = session
        return session
    }
    func handleEvents(_ name: String, completion: @escaping () -> Void) {
        guard [Self.wifi, Self.mobile].contains(name) else { completion(); return }
        handoff.retain(completion, for: name)
        _ = session(name)
    }
    fileprivate func handle(_ task: URLSessionTask, in name: String) -> SystemDownload {
        SystemDownload(session: name, number: task.taskIdentifier, description: task.taskDescription,
                       received: task.countOfBytesReceived, expected: task.countOfBytesExpectedToReceive,
                       resumeIfSuspended: { if task.state == .suspended { task.resume() } }, cancel: { task.cancel() })
    }
    func inventory() async -> [SystemDownload] {
        var result: [SystemDownload] = []
        for name in [Self.wifi, Self.mobile] {
            let tasks = await session(name).allTasks
            for task in tasks where task.state != .completed && task.state != .canceling {
                active[name, default: [:]][task.taskIdentifier] = task
                result.append(handle(task, in: name))
            }
        }
        return result
    }
    func create(url: URL, job: String, generation: String, strict: Bool) throws -> SystemDownload {
        guard DownloadMedia.permits(url) else { throw DownloadFailure.invalid }
        let name = strict ? Self.wifi : Self.mobile
        var request = URLRequest(url: url)
        request.allowsCellularAccess = !strict
        let task = session(name).downloadTask(with: request)
        task.taskDescription = job + "/" + generation
        active[name, default: [:]][task.taskIdentifier] = task
        return handle(task, in: name)
    }
    func cancel(session: String, number: Int) {
        if let task = active[session]?[number] { task.cancel() }
        else if let existing = sessions[session] {
            Task { for task in await existing.allTasks where task.taskIdentifier == number { task.cancel() } }
        }
    }

    fileprivate func removeTask(_ number: Int, in name: String) { active[name]?[number] = nil }
    fileprivate func drained(_ name: String) {
        let handlers = handoff.takeHandlers(for: name)
        handlers.forEach { $0() }
    }
}

struct BackgroundEventHandoff {
    private var completions: [String: [() -> Void]] = [:]
    mutating func retain(_ completion: @escaping () -> Void, for session: String) {
        completions[session, default: []].append(completion)
    }
    mutating func takeHandlers(for session: String) -> [() -> Void] {
        completions.removeValue(forKey: session) ?? []
    }
}

// URLSession serializes these callbacks across both sessions. Only sampled
// progress crosses to the main actor. Temporary file ownership must move synchronously.
private final class BackgroundDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private weak var service: BackgroundTransfers?
    private var cadence: [ObjectIdentifier: ProgressCadence] = [:]
    init(owner: BackgroundTransfers) { service = owner }
    func urlSession(_ session: URLSession, downloadTask task: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        guard let name = session.configuration.identifier else { return }
        DispatchQueue.main.sync {
            guard let service else { return }
            service.owner?.backgroundFile(service.handle(task, in: name), response: task.response as? HTTPURLResponse, location: location)
        }
    }
    func urlSession(_ session: URLSession, downloadTask task: URLSessionDownloadTask, didWriteData bytes: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard let name = session.configuration.identifier else { return }
        let oversized = max(totalBytesWritten, totalBytesExpectedToWrite) > DownloadMedia.limit
        guard oversized || cadence[ObjectIdentifier(task), default: ProgressCadence(seconds: 0.5)].due(at: ProcessInfo.processInfo.systemUptime) else { return }
        DispatchQueue.main.async { [weak service] in
            guard let service else { return }
            let item = service.handle(task, in: name)
            if oversized { service.owner?.backgroundEnded(item, failure: .size); task.cancel() }
            else { service.owner?.backgroundProgress(item) }
        }
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didFinishCollecting metrics: URLSessionTaskMetrics) {
        guard let last = metrics.transactionMetrics.last, let start = last.responseStartDate, let end = last.responseEndDate else { return }
        let seconds = end.timeIntervalSince(start)
        Logger(subsystem: "com.th07.muzikbelesh", category: "Transfer").info("background bytes=\(last.countOfResponseBodyBytesReceived) bodySeconds=\(seconds) taskSeconds=\(metrics.taskInterval.duration)")
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let name = session.configuration.identifier else { return }
        cadence[ObjectIdentifier(task)] = nil
        DispatchQueue.main.async { [weak service] in
            guard let service else { return }
            service.removeTask(task.taskIdentifier, in: name)
            service.owner?.backgroundEnded(service.handle(task, in: name), failure: error == nil ? nil : .connection)
        }
    }
    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        guard let name = session.configuration.identifier else { return }
        DispatchQueue.main.async { [weak service] in service?.drained(name) }
    }
}

@MainActor final class BackgroundDownloadAppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, handleEventsForBackgroundURLSession identifier: String,
                     completionHandler: @escaping () -> Void) {
        BackgroundTransfers.shared.handleEvents(identifier, completion: completionHandler)
    }
}
