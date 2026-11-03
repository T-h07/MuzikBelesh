import MediaPlayer

final class RemoteCommandCoordinator {
    private let center = MPRemoteCommandCenter.shared()
    private var tokens: [Any] = []
    private var registered = false

    func register(service: AudioPlayerService) {
        guard !registered else { return }
        registered = true
        center.playCommand.isEnabled = true; center.pauseCommand.isEnabled = true; center.togglePlayPauseCommand.isEnabled = true
        center.nextTrackCommand.isEnabled = true; center.previousTrackCommand.isEnabled = true; center.changePlaybackPositionCommand.isEnabled = true
        center.playCommand.addTarget { [weak service] _ in guard let service else { return .commandFailed }; service.enqueueRemote(command: "play") { await service.playFromRemote() }; return .success }
        center.pauseCommand.addTarget { [weak service] _ in guard let service else { return .commandFailed }; service.enqueueRemote(command: "pause") { service.pause() }; return .success }
        center.togglePlayPauseCommand.addTarget { [weak service] _ in guard let service else { return .commandFailed }; service.enqueueRemote(command: "toggle") { await service.togglePlayback() }; return .success }
        center.nextTrackCommand.addTarget { [weak service] _ in guard let service else { return .commandFailed }; service.enqueueRemote(command: "next") { await service.next() }; return .success }
        center.previousTrackCommand.addTarget { [weak service] _ in guard let service else { return .commandFailed }; service.enqueueRemote(command: "previous") { await service.previous() }; return .success }
        center.changePlaybackPositionCommand.addTarget { [weak service] event in guard let event = event as? MPChangePlaybackPositionCommandEvent, let service else { return .commandFailed }; service.enqueueRemote(command: "seek") { await service.seek(to: event.positionTime) }; return .success }
    }

    func updateCapabilities(state: AudioPlaybackState) {
        center.nextTrackCommand.isEnabled = state.canSkipNext
        center.previousTrackCommand.isEnabled = state.canSkipPrevious || state.elapsedTime > 3
        center.changePlaybackPositionCommand.isEnabled = state.canSeek
    }

    func unregister() {
        [center.playCommand, center.pauseCommand, center.togglePlayPauseCommand, center.nextTrackCommand, center.previousTrackCommand, center.changePlaybackPositionCommand].forEach { $0.removeTarget(nil) }
        tokens.removeAll(); registered = false
    }
}
