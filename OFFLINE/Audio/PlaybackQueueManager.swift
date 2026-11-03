import Foundation
import SwiftUI

@MainActor final class PlaybackQueueManager: ObservableObject {
    @Published private(set) var entries: [PlaybackQueueEntry] = []
    @Published private(set) var contextTrackIDs: [String] = []
    @Published private(set) var shuffleEnabled = false
    @Published private(set) var repeatMode: RepeatMode = .all
    var onStateChanged: (() -> Void)?
    private let storage: StorageCoordinator?
    private var navigator: PlaybackNavigationEngine
    private var pendingNavigator: PlaybackNavigationEngine?
    private var pendingQueueEntryID: String?
    @Published private(set) var lastError: String?
    private var shuffleOrder: [String] = []
    private var shufflePosition = 0
    private var currentID: String?
    private var navigationHistory: [String] = []
    private var navigationHistoryPosition = -1

    init(storage: StorageCoordinator?, makeShuffle: @escaping ([String]) -> [String] = { $0.shuffled() }) { self.storage = storage; navigator = PlaybackNavigationEngine(makeShuffle: makeShuffle); restore() }

    func restore() {
        guard let storage else { return }
        entries = ((try? storage.playback.queue()) ?? []).enumerated().compactMap { index, entry in
            guard isAvailable(entry.trackID) else { return nil }
            return PlaybackQueueEntry(id: entry.id, trackID: entry.trackID, position: index, insertedAt: entry.dateAdded, origin: QueueEntryOrigin(rawValue: entry.origin) ?? .addToQueue)
        }
        let savedResult = try? storage.playback.state()
        if let saved = savedResult ?? nil {
            currentID = saved.currentTrackID
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
        if let pendingNavigator { navigator = pendingNavigator }
        pendingNavigator = nil
        if let pendingQueueEntryID { entries.removeAll { $0.id == pendingQueueEntryID } }
        pendingQueueEntryID = nil
        navigator.didStart(id, direction: direction); syncFromNavigator()
        normalizeAndPersist()
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
        let candidate = navigator.copy()
        candidate.setExplicitQueue(entries.map(\.trackID))
        pendingNavigator = candidate
        pendingQueueEntryID = entries.first?.id
        return candidate.next()
    }
    func rejectCandidate(_ id: String) {
        pendingNavigator = nil; pendingQueueEntryID = nil
        entries.removeAll { $0.trackID == id }
        setContext(contextTrackIDs.filter { $0 != id }, current: currentID)
        normalizeAndPersist()
    }
    func cancelCandidate() { pendingNavigator = nil; pendingQueueEntryID = nil }
    func previousID() -> String? { navigator.previous() }
    func hasNext() -> Bool { navigator.hasNext(explicitQueue: entries.map(\.trackID)) }
    func hasPrevious() -> Bool { navigator.hasPrevious() }
    func persistState(currentTrackID: String?, positionMs: Int64, sleepDeadline: Date?, sleepTimerDuration: TimeInterval?) {
        navigator.setCurrent(currentTrackID)
        currentID = currentTrackID
        syncFromNavigator()
        let state = StoredPlaybackState(scope: "default", currentTrackID: currentTrackID, positionMs: positionMs, shuffleEnabled: shuffleEnabled, repeatMode: repeatMode.rawValue, contextTrackIDsJSON: encode(contextTrackIDs), shuffleOrderJSON: encode(shuffleOrder), shufflePosition: shufflePosition, sleepTimerDeadlineMs: sleepDeadline.map { Int64($0.timeIntervalSince1970 * 1000) }, sleepTimerDurationMs: sleepTimerDuration.map { Int64($0 * 1000) }, navigationHistoryJSON: encode(navigationHistory), navigationHistoryPosition: navigationHistoryPosition, dateModified: Date())
        do { try storage?.playback.saveSnapshot(state, queue: storedEntries) }
        catch { lastError = "Playback state could not be saved." }
    }
    private func insert(trackID: String, at: Int, origin: QueueEntryOrigin) { guard isAvailable(trackID) else { return }; entries.insert(PlaybackQueueEntry(id: UUID().uuidString, trackID: trackID, position: at, insertedAt: Date(), origin: origin), at: min(at, entries.count)); normalizeAndPersist() }
    private var storedEntries: [StoredQueueEntry] { entries.map { StoredQueueEntry(id: $0.id, trackID: $0.trackID, position: $0.position, dateAdded: $0.insertedAt, origin: $0.origin.rawValue) } }
    private func normalizeAndPersist() {
        entries = entries.enumerated().map { PlaybackQueueEntry(id: $0.element.id, trackID: $0.element.trackID, position: $0.offset, insertedAt: $0.element.insertedAt, origin: $0.element.origin) }
        if let onStateChanged { onStateChanged() }
        else { do { try storage?.playback.replaceQueue(storedEntries) } catch { lastError = "Queue could not be saved." } }
    }
    private func syncFromNavigator() { contextTrackIDs = navigator.context; currentID = navigator.currentID; shuffleEnabled = navigator.shuffleEnabled; repeatMode = navigator.repeatMode; shuffleOrder = navigator.shuffleOrder; shufflePosition = navigator.shufflePosition; navigationHistory = navigator.history; navigationHistoryPosition = navigator.historyPosition }
    private func persist() { onStateChanged?() }
    private func encode(_ value: [String]) -> String? { try? String(data: JSONEncoder().encode(value), encoding: .utf8) }
    private func decode(_ value: String?) -> [String]? { guard let value, let data = value.data(using: .utf8) else { return nil }; return try? JSONDecoder().decode([String].self, from: data) }
    private func reconcile() { entries = entries.filter { isAvailable($0.trackID) }; normalizeAndPersist() }
    private func isAvailable(_ id: String) -> Bool { guard let storage, let track = (try? storage.tracks.find(id: id)) ?? nil else { return false }; return track.availability == .available }
}
