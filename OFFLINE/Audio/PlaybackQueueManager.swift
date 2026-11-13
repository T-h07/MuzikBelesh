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
    private(set) var migrationContext: MigrationNavigationContext?
    private var pendingOccurrenceID: String?
    private var pendingResumeOccurrenceID: String?
    var currentOccurrenceID: String? { migrationContext == nil ? nil : navigator.currentID }

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
            if let json = saved.migrationContextJSON {
                migrationContext = try? JSONDecoder().decode(MigrationNavigationContext.self, from: Data(json.utf8))
            }
        }
        if (try? storage.playback.state()) == nil { repeatMode = .all }
        if var migration = migrationContext {
            if let saved = savedResult ?? nil, saved.contextKind == "migrationPlaylist", let id = saved.contextSourceID {
                do { migration.occurrences = try storage.playlistMigrations.hybridPlaybackOccurrences(playlistID: id) }
                catch { lastError = "Playlist occurrences could not be restored."; migration.occurrences = [] }
            }
            migration.occurrences.removeAll { !isAvailable($0.trackID) }
            migrationContext = migration
        }
        reconcile()
        navigator.restore(context: migrationContext?.occurrences.map(\.id) ?? contextTrackIDs, currentID: migrationContext?.currentID ?? currentID, shuffleEnabled: shuffleEnabled, repeatMode: repeatMode, shuffleOrder: shuffleOrder, shufflePosition: shufflePosition, history: navigationHistory, historyPosition: navigationHistoryPosition, explicitQueue: entries.map(\.trackID))
        if let migration = migrationContext { setContext(migration.occurrences.map(\.trackID), current: currentID) }
    }

    func setMigrationContext(_ occurrences: [MigrationPlaybackOccurrence], selected: String) {
        migrationContext = MigrationNavigationContext(occurrences: occurrences, currentID: selected)
        pendingOccurrenceID = selected
        navigator.setContext(occurrences.map(\.id), currentID: selected)
        syncFromNavigator()
    }
    func clearMigrationContext() {
        migrationContext = nil; pendingOccurrenceID = nil
    }
    func refreshMigrationOccurrences(_ occurrences: [MigrationPlaybackOccurrence]) {
        guard migrationContext != nil, migrationContext?.occurrences != occurrences else { return }
        migrationContext?.occurrences = occurrences
        navigator.setContext(occurrences.map(\.id), currentID: navigator.currentID)
        pendingNavigator?.setContext(occurrences.map(\.id), currentID: pendingNavigator?.currentID)
        syncFromNavigator()
    }
    func selectionRollback() -> () -> Void {
        let previousNavigator = navigator.copy(), previousMigration = migrationContext
        return { [weak self] in
            guard let self else { return }
            self.cancelCandidate(); self.navigator = previousNavigator; self.migrationContext = previousMigration; self.syncFromNavigator()
        }
    }
    func setContext(_ ids: [String], current: String?) {
        if var migration = migrationContext {
            let available = Set(ids)
            migration.occurrences.removeAll { !available.contains($0.trackID) || !isAvailable($0.trackID) }
            migrationContext = migration
            navigator.setContext(migration.occurrences.map(\.id), currentID: navigator.currentID)
            pendingNavigator?.setContext(migration.occurrences.map(\.id), currentID: pendingNavigator?.currentID)
        } else {
            let available = (try? storage?.tracks.availableIDs()) ?? []
            contextTrackIDs = ids.filter { available.contains($0) }; currentID = current
            navigator.setContext(contextTrackIDs, currentID: current); pendingNavigator?.setContext(contextTrackIDs, currentID: current)
        }
        syncFromNavigator()
    }
    func setCurrent(_ id: String?) {
        currentID = id
        if migrationContext == nil { navigator.setCurrent(id) }
    }
    func didStart(_ id: String, direction: NavigationDirection = .forward) {
        if let pendingNavigator { navigator = pendingNavigator }
        pendingNavigator = nil
        if let pendingQueueEntryID {
            if migrationContext != nil, let entry = entries.first(where: { $0.id == pendingQueueEntryID }) {
                migrationContext?.queuedOccurrences = [MigrationPlaybackOccurrence(id: "queue:" + entry.id, trackID: entry.trackID)]
                migrationContext?.resumeOccurrenceID = pendingResumeOccurrenceID
            }
            entries.removeAll { $0.id == pendingQueueEntryID }
        } else if pendingOccurrenceID != nil {
            migrationContext?.resumeOccurrenceID = nil; migrationContext?.queuedOccurrences = []
        }
        pendingQueueEntryID = nil
        navigator.didStart(pendingOccurrenceID ?? id, direction: direction)
        pendingOccurrenceID = nil; pendingResumeOccurrenceID = nil; syncFromNavigator()
        normalizeAndPersist()
    }
    func addToQueue(trackID: String) { insert(trackID: trackID, at: entries.count, origin: .addToQueue) }
    func playNext(trackID: String) { insert(trackID: trackID, at: 0, origin: .playNext) }
    func remove(at offsets: IndexSet) { entries.remove(atOffsets: offsets); normalizeAndPersist() }
    func remove(id: String) { entries.removeAll { $0.id == id }; normalizeAndPersist() }
    func clear() { entries.removeAll(); normalizeAndPersist() }
    func move(from offsets: IndexSet, to destination: Int) { entries.move(fromOffsets: offsets, toOffset: destination); normalizeAndPersist() }
    func toggleShuffle() { navigator.setShuffleEnabled(!shuffleEnabled); pendingNavigator?.setShuffleEnabled(navigator.shuffleEnabled); syncFromNavigator(); persist() }
    func cycleRepeat() { navigator.cycleRepeat(); pendingNavigator?.cycleRepeat(); syncFromNavigator(); persist() }
    func nextID(reason: PlaybackAdvanceReason = .automatic) -> String? {
        let candidate = navigator.copy()
        if let resume = migrationContext?.resumeOccurrenceID { candidate.setCurrent(resume) }
        candidate.setExplicitQueue(explicitNavigationIDs)
        pendingNavigator = candidate
        pendingQueueEntryID = entries.first?.id
        pendingResumeOccurrenceID = migrationContext == nil ? nil : candidate.currentID
        let identity = candidate.next(reason: reason)
        pendingOccurrenceID = migrationContext == nil ? nil : identity
        return identity.map(resolveIdentity)
    }
    func rejectCandidate(_ id: String) {
        cancelCandidate()
        entries.removeAll { $0.trackID == id }
        setContext(contextTrackIDs.filter { $0 != id }, current: currentID)
        normalizeAndPersist()
    }
    func removeUnavailableEntries() { cancelCandidate(); entries.removeAll { !isAvailable($0.trackID) }; normalizeAndPersist() }
    func cancelCandidate() { pendingNavigator = nil; pendingQueueEntryID = nil; pendingOccurrenceID = nil; pendingResumeOccurrenceID = nil }
    func previousID() -> String? {
        let identity = migrationContext?.resumeOccurrenceID ?? navigator.previous()
        pendingOccurrenceID = migrationContext == nil ? nil : identity
        return identity.map(resolveIdentity)
    }
    func hasNext(reason: PlaybackAdvanceReason = .automatic) -> Bool {
        guard migrationContext != nil else { return navigator.hasNext(reason: reason, explicitQueue: entries.map(\.trackID)) }
        let candidate = navigator.copy()
        if let resume = migrationContext?.resumeOccurrenceID { candidate.setCurrent(resume) }
        return candidate.hasNext(reason: reason, explicitQueue: explicitNavigationIDs)
    }
    var navigationDiagnostics: [String: String] {
        ["shuffle": String(shuffleEnabled), "repeat": repeatMode.rawValue,
         "navigationPolicy": shuffleEnabled ? "playback-history" : "library-order",
         "shufflePosition": String(navigator.shufflePosition), "cycleLength": String(navigator.shuffleOrder.count),
         "historyPosition": String(navigator.historyPosition), "historyLength": String(navigator.history.count),
         "automaticNext": String(hasNext()), "manualNext": String(hasNext(reason: .manual)),
         "historyPrevious": String(hasPrevious()), "queueLength": String(entries.count)]
    }
    func hasPrevious() -> Bool { migrationContext?.resumeOccurrenceID != nil || navigator.hasPrevious() }
    func persistState(currentTrackID: String?, positionMs: Int64, sleepDeadline: Date?, sleepTimerDuration: TimeInterval?, contextKind: String? = nil, contextSourceID: String? = nil) {
        if migrationContext == nil { navigator.setCurrent(currentTrackID) }
        currentID = currentTrackID
        syncFromNavigator()
        var state = StoredPlaybackState(scope: "default", currentTrackID: currentTrackID, positionMs: positionMs, shuffleEnabled: shuffleEnabled, repeatMode: repeatMode.rawValue, contextTrackIDsJSON: encode(contextTrackIDs), shuffleOrderJSON: encode(shuffleOrder), shufflePosition: shufflePosition, sleepTimerDeadlineMs: sleepDeadline.map { Int64($0.timeIntervalSince1970 * 1000) }, sleepTimerDurationMs: sleepTimerDuration.map { Int64($0 * 1000) }, navigationHistoryJSON: encode(navigationHistory), navigationHistoryPosition: navigationHistoryPosition, contextKind: contextKind, contextSourceID: contextSourceID, dateModified: Date())
        state.migrationContextJSON = migrationContext.flatMap { value in (try? JSONEncoder().encode(value)).map { String(decoding: $0, as: UTF8.self) } }
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
    private var explicitNavigationIDs: [String] { entries.map { migrationContext == nil ? $0.trackID : "queue:" + $0.id } }
    private func resolveIdentity(_ id: String) -> String {
        guard let migration = migrationContext else { return id }
        return migration.occurrences.first { $0.id == id }?.trackID
            ?? migration.queuedOccurrences.first { $0.id == id }?.trackID
            ?? entries.first { "queue:" + $0.id == id }?.trackID ?? id
    }
    private func syncFromNavigator() {
        contextTrackIDs = navigator.context.map(resolveIdentity); currentID = navigator.currentID.map(resolveIdentity)
        migrationContext?.currentID = navigator.currentID
        shuffleEnabled = navigator.shuffleEnabled; repeatMode = navigator.repeatMode; shuffleOrder = navigator.shuffleOrder; shufflePosition = navigator.shufflePosition; navigationHistory = navigator.history; navigationHistoryPosition = navigator.historyPosition
    }
    private func persist() { onStateChanged?() }
    private func encode(_ value: [String]) -> String? { try? String(data: JSONEncoder().encode(value), encoding: .utf8) }
    private func decode(_ value: String?) -> [String]? { guard let value, let data = value.data(using: .utf8) else { return nil }; return try? JSONDecoder().decode([String].self, from: data) }
    private func reconcile() { entries = entries.filter { isAvailable($0.trackID) }; normalizeAndPersist() }
    private func isAvailable(_ id: String) -> Bool { guard let storage, let track = (try? storage.tracks.find(id: id)) ?? nil else { return false }; return migrationContext == nil ? track.availability == .available : MigrationLocalAudio.isAvailable(track, paths: storage.paths) }
}

struct MigrationNavigationContext: Codable {
    var occurrences: [MigrationPlaybackOccurrence]
    var currentID: String?
    var queuedOccurrences: [MigrationPlaybackOccurrence] = []
    var resumeOccurrenceID: String? = nil
}
