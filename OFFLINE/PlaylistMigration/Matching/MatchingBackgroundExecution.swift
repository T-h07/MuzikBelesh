import BackgroundTasks
import UIKit
import OSLog

@MainActor protocol MatchingBackgroundExecuting: AnyObject {
    func begin(start: @escaping @MainActor () -> Void, expiration: @escaping @MainActor () -> Void)
    func update(_ progress: SongMatchingProgress)
    func finish(success: Bool)
}

/// CPU/network continuation only; no GPU entitlement, silent audio or download
/// session reuse. AppContainer constructs this once during application startup.
@MainActor final class MatchingBackgroundExecution: MatchingBackgroundExecuting {
    static let identifier = "com.th07.muzikbelesh.matching"
    static let shared = MatchingBackgroundExecution()
    private var requestID: String?
    private var generation = UUID()
    private var limited: UIBackgroundTaskIdentifier = .invalid
    private var systemTask: BGTask?
    private var startWork: (@MainActor () -> Void)?
    private var expireWork: (@MainActor () -> Void)?
    private var registered = false
    private var awaitingLaunch = false
    private let log = Logger(subsystem: "com.th07.muzikbelesh", category: "PlaylistMatchingBackground")
    private init() {
        if #available(iOS 26.0, *) {
            registered = BGTaskScheduler.shared.register(forTaskWithIdentifier: Self.identifier + ".*", using: .main) { [weak self] task in
                Task { @MainActor in
                    guard let self, self.awaitingLaunch, task.identifier == self.requestID, let continued = task as? BGContinuedProcessingTask else {
                        task.setTaskCompleted(success: false); return
                    }
                    self.awaitingLaunch = false; self.systemTask = continued
                    let generation = self.generation
                    continued.expirationHandler = { [weak self] in
                        Task { @MainActor in self?.expired(generation: generation) }
                    }
                    self.startOnce()
                }
            }
        }
    }
    func begin(start: @escaping @MainActor () -> Void, expiration: @escaping @MainActor () -> Void) {
        finish(success: false)
        generation = UUID()
        let generation = generation
        startWork = start; expireWork = expiration
        if #available(iOS 26.0, *), registered {
            let id = Self.identifier + "." + UUID().uuidString
            requestID = id
            let request = BGContinuedProcessingTaskRequest(identifier: id, title: "Matching recordings", subtitle: "Preparing playlist")
            request.strategy = .fail // Never leave an orphan queued request after fallback starts.
            awaitingLaunch = true
            do { try BGTaskScheduler.shared.submit(request); return }
            catch {
                awaitingLaunch = false
                log.notice("Continued processing admission failed; using limited execution. Error code=\((error as NSError).code, privacy: .public)")
            }
        }
        limited = UIApplication.shared.beginBackgroundTask(withName: "Playlist matching") { [weak self] in
            Task { @MainActor in self?.expired(generation: generation) }
        }
        startOnce()
    }
    private func startOnce() { let action = startWork; startWork = nil; action?() }
    private func expired(generation: UUID) {
        guard generation == self.generation else { return }
        let action = expireWork
        finish(success: false)
        action?()
    }
    func update(_ progress: SongMatchingProgress) {
        if #available(iOS 26.0, *), let task = systemTask as? BGContinuedProcessingTask {
            task.progress.totalUnitCount = Int64(max(1, progress.total))
            task.progress.completedUnitCount = Int64(progress.processed)
            task.updateTitle("Matching recordings", subtitle: "\(progress.processed) of \(progress.total) entries processed")
        }
    }
    func finish(success: Bool) {
        generation = UUID()
        if awaitingLaunch, let requestID { BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: requestID) }
        requestID = nil
        awaitingLaunch = false; startWork = nil; expireWork = nil
        systemTask?.expirationHandler = nil
        systemTask?.setTaskCompleted(success: success); systemTask = nil
        if limited != .invalid { UIApplication.shared.endBackgroundTask(limited); limited = .invalid }
    }
}
