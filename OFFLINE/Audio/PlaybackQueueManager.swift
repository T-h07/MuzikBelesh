import Foundation
import SwiftUI

@MainActor final class PlaybackQueueManager: ObservableObject {
    @Published private(set) var entries: [PlaybackQueueEntry] = []
    @Published private(set) var contextTrackIDs: [String] = []
    @Published private(set) var shuffleEnabled = false
    @Published private(set) var repeatMode: RepeatMode = .off
    var onStateChanged: (() -> Void)?
    private let storage: StorageCoordinator?
    private var shuffleOrder: [String] = []
    private var shufflePosition = 0
    private var currentID: String?

    init(storage: StorageCoordinator?) { self.storage = storage; restore() }

    func restore() {
        guard let storage else { return }
        entries = ((try? storage.playback.queue()) ?? []).enumerated().compactMap { index, entry in
            guard isAvailable(entry.trackID) else { return nil }
            return PlaybackQueueEntry(id: entry.id, trackID: entry.trackID, position: index, insertedAt: entry.dateAdded, origin: QueueEntryOrigin(rawValue: entry.origin) ?? .addToQueue)
        }
        let savedResult = try? storage.playback.state()
        if let saved = savedResult ?? nil {
            shuffleEnabled = saved.shuffleEnabled; repeatMode = RepeatMode(rawValue: saved.repeatMode) ?? .off
            contextTrackIDs = decode(saved.contextTrackIDsJSON) ?? []
            shuffleOrder = decode(saved.shuffleOrderJSON) ?? []; shufflePosition = saved.shufflePosition ?? 0
        }
        reconcile()
    }

    func setContext(_ ids: [String], current: String?) { contextTrackIDs = ids.filter { isAvailable($0) }; currentID = current; if shuffleEnabled && shuffleOrder.isEmpty { rebuildShuffle(excluding: current) } }
    func setCurrent(_ id: String?) { currentID = id }
    func addToQueue(trackID: String) { insert(trackID: trackID, at: entries.count, origin: .addToQueue) }
    func playNext(trackID: String) { insert(trackID: trackID, at: 0, origin: .playNext) }
    func remove(at offsets: IndexSet) { entries.remove(atOffsets: offsets); normalizeAndPersist() }
    func remove(id: String) { entries.removeAll { $0.id == id }; normalizeAndPersist() }
    func clear() { entries.removeAll(); normalizeAndPersist() }
    func move(from offsets: IndexSet, to destination: Int) { entries.move(fromOffsets: offsets, toOffset: destination); normalizeAndPersist() }
    func toggleShuffle() { shuffleEnabled.toggle(); if shuffleEnabled { rebuildShuffle(excluding: currentID) }; persist() }
    func cycleRepeat() { repeatMode = RepeatMode.allCases[(RepeatMode.allCases.firstIndex(of: repeatMode)! + 1) % RepeatMode.allCases.count]; persist() }
    func nextID() -> String? {
        if let first = entries.first { entries.removeFirst(); normalizeAndPersist(); return first.trackID }
        guard !contextTrackIDs.isEmpty else { return nil }
        if repeatMode == .one, let currentID { return currentID }
        if shuffleEnabled {
            if shuffleOrder.isEmpty || shufflePosition >= shuffleOrder.count {
                guard repeatMode == .all else { return nil }; rebuildShuffle(excluding: currentID)
            }
            guard shufflePosition < shuffleOrder.count else { return nil }
            let id = shuffleOrder[shufflePosition]; shufflePosition += 1; persist(); return id
        }
        guard let currentID, let index = contextTrackIDs.firstIndex(of: currentID) else { return contextTrackIDs.first }
        if index + 1 < contextTrackIDs.count { return contextTrackIDs[index + 1] }
        guard repeatMode == .all else { return nil }
        return contextTrackIDs.first
    }
    func previousID() -> String? { guard let currentID, let index = contextTrackIDs.firstIndex(of: currentID), index > 0 else { return nil }; return contextTrackIDs[index - 1] }
    func persistState(currentTrackID: String?, positionMs: Int64, sleepDeadline: Date?) {
        currentID = currentTrackID
        let state = StoredPlaybackState(scope: "default", currentTrackID: currentTrackID, positionMs: positionMs, shuffleEnabled: shuffleEnabled, repeatMode: repeatMode.rawValue, contextTrackIDsJSON: encode(contextTrackIDs), shuffleOrderJSON: encode(shuffleOrder), shufflePosition: shufflePosition, sleepTimerDeadlineMs: sleepDeadline.map { Int64($0.timeIntervalSince1970 * 1000) }, dateModified: Date())
        try? storage?.playback.save(state)
    }
    private func insert(trackID: String, at: Int, origin: QueueEntryOrigin) { guard isAvailable(trackID) else { return }; entries.insert(PlaybackQueueEntry(id: UUID().uuidString, trackID: trackID, position: at, insertedAt: Date(), origin: origin), at: min(at, entries.count)); normalizeAndPersist() }
    private func normalizeAndPersist() { entries = entries.enumerated().map { PlaybackQueueEntry(id: $0.element.id, trackID: $0.element.trackID, position: $0.offset, insertedAt: $0.element.insertedAt, origin: $0.element.origin) }; let stored = entries.map { StoredQueueEntry(id: $0.id, trackID: $0.trackID, position: $0.position, dateAdded: $0.insertedAt, origin: $0.origin.rawValue) }; try? storage?.playback.replaceQueue(stored) }
    private func rebuildShuffle(excluding: String?) { shuffleOrder = contextTrackIDs.filter { $0 != excluding }.shuffled(); if let last = shuffleOrder.last, let first = shuffleOrder.first, last == first, shuffleOrder.count > 1 { shuffleOrder.swapAt(0, 1) }; shufflePosition = 0 }
    private func persist() { persistState(currentTrackID: currentID, positionMs: 0, sleepDeadline: nil); onStateChanged?() }
    private func encode(_ value: [String]) -> String? { try? String(data: JSONEncoder().encode(value), encoding: .utf8) }
    private func decode(_ value: String?) -> [String]? { guard let value, let data = value.data(using: .utf8) else { return nil }; return try? JSONDecoder().decode([String].self, from: data) }
    private func reconcile() { entries = entries.filter { isAvailable($0.trackID) }; normalizeAndPersist() }
    private func isAvailable(_ id: String) -> Bool { guard let storage, let track = (try? storage.tracks.find(id: id)) ?? nil else { return false }; return track.availability == .available }
}
