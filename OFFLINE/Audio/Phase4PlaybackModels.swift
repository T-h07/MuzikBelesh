import Foundation

enum QueueEntryOrigin: String, Codable { case playNext, addToQueue, playbackContext }
extension RepeatMode {
    var symbol: String { self == .one ? "repeat.1" : "repeat" }
}

struct PlaybackQueueEntry: Identifiable, Equatable {
    let id: String
    let trackID: String
    let position: Int
    let insertedAt: Date
    let origin: QueueEntryOrigin
}

struct ShuffleCycle: Equatable {
    var order: [String]
    var position: Int
}

final class PlaybackHistoryService {
    private let storage: StorageCoordinator?
    private var activeID: String?
    private var startedAt: Date?
    init(storage: StorageCoordinator?) { self.storage = storage }
    func started(trackID: String, source: String = "playback") {
        guard activeID != trackID else { return }
        finish()
        let id = UUID().uuidString; activeID = id; startedAt = Date()
        try? storage?.playback.addHistory(StoredHistoryEntry(id: id, trackID: trackID, startedAt: startedAt!, completedAt: nil, durationListenedMs: nil, source: source))
    }
    func finish(duration: TimeInterval = 0) { guard let id = activeID else { return }; try? storage?.playback.completeHistory(id: id, completedAt: Date(), durationMs: Int64(max(0, duration) * 1000)); activeID = nil; startedAt = nil }
    func recent(limit: Int = 8) -> [StoredHistoryEntry] { (try? storage?.playback.history(limit: limit)) ?? [] }
}

@MainActor final class SleepTimerService: ObservableObject {
    @Published private(set) var deadline: Date?
    @Published private(set) var durationSeconds: TimeInterval?
    private var task: Task<Void, Never>?
    var onExpire: (() -> Void)?
    var onChange: (() -> Void)?
    var isActive: Bool { deadline != nil }
    var remaining: TimeInterval { max(0, deadline?.timeIntervalSinceNow ?? 0) }
    init(deadline: Date? = nil, duration: TimeInterval? = nil) { self.deadline = deadline; self.durationSeconds = duration; schedule() }
    deinit { task?.cancel() }
    func start(minutes: Int) { start(duration: TimeInterval(minutes) * 60) }
    func start(duration: TimeInterval) { guard duration.isFinite, duration >= 60, duration <= 7 * 24 * 60 * 60 else { return }; durationSeconds = duration; deadline = Date().addingTimeInterval(duration); schedule(); onChange?() }
    func cancel() { task?.cancel(); task = nil; deadline = nil; durationSeconds = nil; onChange?() }
    func reset() { guard let durationSeconds else { return }; start(duration: durationSeconds) }
    func checkDeadline(now: Date = Date()) {
        guard let deadline, deadline <= now else { return }
        task?.cancel(); task = nil; self.deadline = nil; onExpire?()
    }
    func reconcile(onExpire: @escaping () -> Void) { self.onExpire = onExpire; if let deadline, deadline <= Date() { self.deadline = nil; onExpire() } else { schedule() } }
    private func schedule() { task?.cancel(); guard let deadline else { return }; task = Task { [weak self] in let ns = UInt64(min(7 * 24 * 60 * 60, max(0, deadline.timeIntervalSinceNow)) * 1_000_000_000); try? await Task.sleep(nanoseconds: ns); guard !Task.isCancelled else { return }; await MainActor.run { guard let self, self.deadline == deadline else { return }; if deadline > Date() { self.schedule() } else { self.deadline = nil; self.onExpire?() } } } }
}
