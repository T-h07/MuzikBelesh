import MediaPlayer

final class RemoteCommandCoordinator {
    private let center = MPRemoteCommandCenter.shared()
    private var tokens: [(MPRemoteCommand, Any)] = []
    private var registered = false
    var registrationCount: Int { tokens.count }

    func register(service: AudioPlayerService) {
        guard !registered else { return }
        registered = true
        center.playCommand.isEnabled = true; center.pauseCommand.isEnabled = true; center.togglePlayPauseCommand.isEnabled = true
        center.nextTrackCommand.isEnabled = true; center.previousTrackCommand.isEnabled = true; center.changePlaybackPositionCommand.isEnabled = true
        add(center.playCommand) { [weak service] _ in guard service != nil else { return .commandFailed }; Task { @MainActor [weak service] in guard let service else { return }; service.enqueueRemote(command: "play") { await service.playFromRemote() } }; return .success }
        add(center.pauseCommand) { [weak service] _ in guard service != nil else { return .commandFailed }; Task { @MainActor [weak service] in guard let service else { return }; service.enqueueRemote(command: "pause") { service.pause() } }; return .success }
        add(center.togglePlayPauseCommand) { [weak service] _ in guard service != nil else { return .commandFailed }; Task { @MainActor [weak service] in guard let service else { return }; service.enqueueRemote(command: "toggle") { await service.togglePlayback() } }; return .success }
        add(center.nextTrackCommand) { [weak service] _ in guard service != nil else { return .commandFailed }; Task { @MainActor [weak service] in guard let service else { return }; service.enqueueRemote(command: "next") { await service.next() } }; return .success }
        add(center.previousTrackCommand) { [weak service] _ in guard service != nil else { return .commandFailed }; Task { @MainActor [weak service] in guard let service else { return }; service.enqueueRemote(command: "previous") { await service.previous() } }; return .success }
        add(center.changePlaybackPositionCommand) { [weak service] event in guard let event = event as? MPChangePlaybackPositionCommandEvent, service != nil else { return .commandFailed }; Task { @MainActor [weak service] in guard let service else { return }; service.enqueueRemote(command: "seek") { await service.seek(to: event.positionTime) } }; return .success }
    }

    private func add(_ command: MPRemoteCommand, handler: @escaping (MPRemoteCommandEvent) -> MPRemoteCommandHandlerStatus) {
        tokens.append((command, command.addTarget(handler: handler)))
    }

    func updateCapabilities(state: AudioPlaybackState) {
        center.nextTrackCommand.isEnabled = state.canSkipNext
        center.previousTrackCommand.isEnabled = state.canSkipPrevious || state.elapsedTime > 3
        center.changePlaybackPositionCommand.isEnabled = state.canSeek
    }

    func unregister() {
        tokens.forEach { command, token in command.removeTarget(token) }
        tokens.removeAll(); registered = false
    }
}
