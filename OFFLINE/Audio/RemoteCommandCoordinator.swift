import MediaPlayer

final class RemoteCommandCoordinator {
    private let center = MPRemoteCommandCenter.shared()
    private var tokens: [Any] = []

    func register(service: AudioPlayerService) {
        center.playCommand.isEnabled = true; center.pauseCommand.isEnabled = true; center.togglePlayPauseCommand.isEnabled = true
        center.nextTrackCommand.isEnabled = true; center.previousTrackCommand.isEnabled = true; center.changePlaybackPositionCommand.isEnabled = true
        center.playCommand.addTarget { [weak service] _ in guard let service else { return .commandFailed }; Task { await service.playFromRemote() }; return .success }
        center.pauseCommand.addTarget { [weak service] _ in guard service != nil else { return .commandFailed }; Task { @MainActor [weak service] in service?.pause() }; return .success }
        center.togglePlayPauseCommand.addTarget { [weak service] _ in guard let service else { return .commandFailed }; Task { await service.togglePlayback() }; return .success }
        center.nextTrackCommand.addTarget { [weak service] _ in guard let service else { return .commandFailed }; Task { await service.next() }; return .success }
        center.previousTrackCommand.addTarget { [weak service] _ in guard let service else { return .commandFailed }; Task { await service.previous() }; return .success }
        center.changePlaybackPositionCommand.addTarget { [weak service] event in guard let event = event as? MPChangePlaybackPositionCommandEvent, let service else { return .commandFailed }; Task { await service.seek(to: event.positionTime) }; return .success }
    }

    func unregister() {
        [center.playCommand, center.pauseCommand, center.togglePlayPauseCommand, center.nextTrackCommand, center.previousTrackCommand, center.changePlaybackPositionCommand].forEach { $0.removeTarget(nil) }
        tokens.removeAll()
    }
}
