import Foundation

final class PlaybackPersistenceCoordinator {
    private let storage: StorageCoordinator?
    init(storage: StorageCoordinator?) { self.storage = storage }

    func save(state: AudioPlaybackState) {
        guard let storage else { return }
        let existing = (try? storage.playback.state()) ?? nil
        let snapshot = StoredPlaybackState(scope: "default", currentTrackID: state.currentTrackID, positionMs: Int64(max(0, state.elapsedTime) * 1000), shuffleEnabled: existing?.shuffleEnabled ?? false, repeatMode: existing?.repeatMode ?? RepeatMode.all.rawValue, contextTrackIDsJSON: existing?.contextTrackIDsJSON, shuffleOrderJSON: existing?.shuffleOrderJSON, shufflePosition: existing?.shufflePosition, sleepTimerDeadlineMs: existing?.sleepTimerDeadlineMs, sleepTimerDurationMs: existing?.sleepTimerDurationMs, navigationHistoryJSON: existing?.navigationHistoryJSON, navigationHistoryPosition: existing?.navigationHistoryPosition, dateModified: Date())
        try? storage.playback.save(snapshot)
    }

    func restore() -> StoredPlaybackState? { try? storage?.playback.state() }
}
