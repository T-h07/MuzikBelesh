import Foundation
import SwiftUI

@MainActor final class PlaybackQueueManager: ObservableObject {
    @Published private(set) var entries: [PlaybackQueueEntry] = []
    @Published private(set) var contextTrackIDs: [String] = []
    @Published private(set) var shuffleEnabled = false
    @Published private(set) var repeatMode: RepeatMode = .all
    var onStateChanged: (() -> Void)?
    private let storage: StorageCoordinator?
    private let navigator = PlaybackNavigationEngine()
    private var shuffleOrder: [String] = []
    private var shufflePosition = 0
    private var currentID: String?
    private var navigationHistory: [String] = []
    private var navigationHistoryPosition = -1

    init(storage: StorageCoordinator?) { self.storage = storage; restore() }

    func restore() {
        guard let storage else { return }
        entries = ((try? storage.playback.queue()) ?? []).enumerated().compactMap { index, entry in
            guard isAvailable(entry.trackID) else { return nil }
            return PlaybackQueueEntry(id: entry.id, trackID: entry.trackID, position: index, insertedAt: entry.dateAdded, origin: QueueEntryOrigin(rawValue: entry.origin) ?? .addToQueue)
        }
        let savedResult = try? storage.playback.state()
        if let saved = savedResult ?? nil {
            shuffleEnabled = saved.shuffleEnabled; repeatMode = RepeatMode(rawValue: saved.repeatMode) ?? .all
            contextTrackIDs = decode(saved.contextTrackIDsJSON) ?? []
            shuffleOrder = decode(saved.shuffleOrderJSON) ?? []; shufflePosition = saved.shufflePosition ?? 0
            navigationHistory = decode(saved.navigationHistoryJSON) ?? []
            navigationHistoryPosition = saved.navigationHistoryPosition ?? (navigationHistory.isEmpty ? -1 : navigationHistory.count - 1)
        }
        if (try? storage.playback.state()) == nil { repeatMode = .all }
        reconcile()
        navigator.restore(context: contextTrackIDs, currentID: currentID, shuffleEnabled: shuffleEnabled, repeatMode: repeatMode, shuffleOrder: shuffleOrder, shufflePosition: shufflePosition, history: navigationHistory, historyPosition: navigationHistoryPosition, explicitQueue: entries.map(\.trackID))
    }

    func setContext(_ ids: [String], current: String?) { contextTrackIDs = ids.filter { isAvailable($0) }; currentID = current; navigator.setContext(contextTrackIDs, currentID: current); syncFromNavigator() }
    func setCurrent(_ id: String?) { currentID = id; navigator.setCurrent(id) }
    func didStart(_ id: String, direction: NavigationDirection = .forward) {
        navigator.didStart(id, direction: direction); syncFromNavigator()
        persist()
    }
    func addToQueue(trackID: String) { insert(trackID: trackID, at: entries.count, origin: .addToQueue) }
    func playNext(trackID: String) { insert(trackID: trackID, at: 0, origin: .playNext) }
    func remove(at offsets: IndexSet) { entries.remove(atOffsets: offsets); normalizeAndPersist() }
    func remove(id: String) { entries.removeAll { $0.id == id }; normalizeAndPersist() }
    func clear() { entries.removeAll(); normalizeAndPersist() }
    func move(from offsets: IndexSet, to destination: Int) { entries.move(fromOffsets: offsets, toOffset: destination); normalizeAndPersist() }
    func toggleShuffle() { navigator.setShuffleEnabled(!shuffleEnabled); syncFromNavigator(); persist() }
    func cycleRepeat() { navigator.cycleRepeat(); syncFromNavigator(); persist() }
    func nextID() -> String? {
        navigator.setExplicitQueue(entries.map(\.trackID)); guard let id = navigator.next() else { return nil }
        if let index = entries.firstIndex(where: { $0.trackID == id }) { entries.remove(at: index); normalizeAndPersist() }
        syncFromNavigator(); persist(); return id
    }
    func previousID() -> String? { navigator.previous() }
    func hasNext() -> Bool { navigator.setExplicitQueue(entries.map(\.trackID)); return navigator.hasNext() }
    func hasPrevious() -> Bool { navigator.hasPrevious() }
    func persistState(currentTrackID: String?, positionMs: Int64, sleepDeadline: Date?, sleepTimerDuration: TimeInterval?) {
        currentID = currentTrackID
        syncFromNavigator()
        let state = StoredPlaybackState(scope: "default", currentTrackID: currentTrackID, positionMs: positionMs, shuffleEnabled: shuffleEnabled, repeatMode: repeatMode.rawValue, contextTrackIDsJSON: encode(contextTrackIDs), shuffleOrderJSON: encode(shuffleOrder), shufflePosition: shufflePosition, sleepTimerDeadlineMs: sleepDeadline.map { Int64($0.timeIntervalSince1970 * 1000) }, sleepTimerDurationMs: sleepTimerDuration.map { Int64($0 * 1000) }, navigationHistoryJSON: encode(navigationHistory), navigationHistoryPosition: navigationHistoryPosition, dateModified: Date())
        try? storage?.playback.save(state)
    }
    private func insert(trackID: String, at: Int, origin: QueueEntryOrigin) { guard isAvailable(trackID) else { return }; entries.insert(PlaybackQueueEntry(id: UUID().uuidString, trackID: trackID, position: at, insertedAt: Date(), origin: origin), at: min(at, entries.count)); normalizeAndPersist() }
    private func normalizeAndPersist() { entries = entries.enumerated().map { PlaybackQueueEntry(id: $0.element.id, trackID: $0.element.trackID, position: $0.offset, insertedAt: $0.element.insertedAt, origin: $0.element.origin) }; let stored = entries.map { StoredQueueEntry(id: $0.id, trackID: $0.trackID, position: $0.position, dateAdded: $0.insertedAt, origin: $0.origin.rawValue) }; try? storage?.playback.replaceQueue(stored); onStateChanged?() }
    private func syncFromNavigator() { contextTrackIDs = navigator.context; currentID = navigator.currentID; shuffleEnabled = navigator.shuffleEnabled; repeatMode = navigator.repeatMode; shuffleOrder = navigator.shuffleOrder; shufflePosition = navigator.shufflePosition; navigationHistory = navigator.history; navigationHistoryPosition = navigator.historyPosition }
    private func persist() { onStateChanged?() }
    private func encode(_ value: [String]) -> String? { try? String(data: JSONEncoder().encode(value), encoding: .utf8) }
    private func decode(_ value: String?) -> [String]? { guard let value, let data = value.data(using: .utf8) else { return nil }; return try? JSONDecoder().decode([String].self, from: data) }
    private func reconcile() { entries = entries.filter { isAvailable($0.trackID) }; normalizeAndPersist() }
    private func isAvailable(_ id: String) -> Bool { guard let storage, let track = (try? storage.tracks.find(id: id)) ?? nil else { return false }; return track.availability == .available }
}
