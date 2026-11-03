import AVFoundation
import Foundation

@MainActor
final class AudioPlayerService: ObservableObject {
    @Published private(set) var state = AudioPlaybackState()

    private let player = AVPlayer()
    private let session = AudioSessionManager()
    private let nowPlaying = NowPlayingInfoCoordinator()
    private let remoteCommands = RemoteCommandCoordinator()
    private let routeMonitor = AudioRouteMonitor()
    private let persistence: PlaybackPersistenceCoordinator
    let queue: PlaybackQueueManager
    private let history: PlaybackHistoryService
    let sleepTimer: SleepTimerService
    private let resolver: LocalAudioAssetResolver
    private weak var storage: StorageCoordinator?
    private var item: AVPlayerItem?
    private var timeObserver: Any?
    private var endObserver: NSObjectProtocol?
    private var interruptionObserver: NSObjectProtocol?
    private var statusObserver: NSKeyValueObservation?
    private var context = PlaybackContext(trackIDs: [], currentIndex: nil)
    private var wasPlayingBeforeInterruption = false
    private var userPausedDuringInterruption = false
    private var transitionInFlight = false
    private var completionInFlight = false

    init(storage: StorageCoordinator?) {
        self.storage = storage
        resolver = LocalAudioAssetResolver(storage: storage)
        persistence = PlaybackPersistenceCoordinator(storage: storage)
        queue = PlaybackQueueManager(storage: storage)
        history = PlaybackHistoryService(storage: storage)
        let savedDeadline: Date?
        if let storage, let saved = (try? storage.playback.state()) ?? nil, let milliseconds = saved.sleepTimerDeadlineMs {
            savedDeadline = Date(timeIntervalSince1970: TimeInterval(milliseconds) / 1000)
        } else { savedDeadline = nil }
        sleepTimer = SleepTimerService(deadline: savedDeadline)
        queue.onStateChanged = { [weak self] in self?.persist() }
        sleepTimer.onExpire = { [weak self] in self?.expireSleepTimer() }
        sleepTimer.onChange = { [weak self] in self?.persist() }
        sleepTimer.reconcile { [weak self] in self?.expireSleepTimer() }
        routeMonitor.onRouteChanged = { [weak self] route, reason in
            Task { @MainActor in self?.handleRouteChange(route: route, reason: reason) }
        }
        interruptionObserver = NotificationCenter.default.addObserver(forName: AVAudioSession.interruptionNotification, object: AVAudioSession.sharedInstance(), queue: .main) { [weak self] notification in
            Task { @MainActor in self?.handleInterruption(notification) }
        }
        refreshContext()
        if let saved = persistence.restore(), let id = saved.currentTrackID { state.currentTrackID = id; state.elapsedTime = TimeInterval(saved.positionMs) / 1000; context = context.settingCurrent(id); updateSkipAvailability(); let position = state.elapsedTime; Task { @MainActor [weak self] in await self?.restorePausedItem(trackID: id, position: position) } }
        remoteCommands.register(service: self)
    }

    deinit {
        if let timeObserver { player.removeTimeObserver(timeObserver) }
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        if let interruptionObserver { NotificationCenter.default.removeObserver(interruptionObserver) }
        statusObserver?.invalidate(); remoteCommands.unregister()
    }

    func play(trackID: String) async throws {
        guard !transitionInFlight else { throw AudioPlaybackError.playerFailed("Another track transition is in progress") }
        transitionInFlight = true
        defer { transitionInFlight = false }
        do {
            let resolved = try resolver.resolve(trackID: trackID)
            try session.configure()
            updateContext(with: trackID)
            queue.setCurrent(trackID)
            replaceItem(with: AVPlayerItem(url: resolved.url), trackID: trackID, track: resolved.track)
            player.play()
            state.status = .playing
            history.started(trackID: trackID)
            state.lastError = nil
            publish(track: resolved.track)
            persist()
        } catch {
            fail(error.localizedDescription)
            throw error
        }
    }

    func play() async throws {
        guard state.currentTrackID != nil else { throw AudioPlaybackError.trackNotFound }
        try session.configure(); player.play(); state.status = .playing; state.lastError = nil; publishCurrent(); persist()
    }

    func playFromRemote() async { try? await play() }
    func pause() { player.pause(); state.status = state.currentTrackID == nil ? .idle : .paused; userPausedDuringInterruption = true; publishCurrent(); persist() }
    func togglePlayback() async { if state.isPlaying { pause() } else { try? await play() } }
    func stop() { player.pause(); player.replaceCurrentItem(with: nil); item = nil; history.finish(duration: state.elapsedTime); state.elapsedTime = 0; state.status = .idle; state.currentTrackID = nil; nowPlaying.clear(); session.deactivate(); persist() }

    func next() async {
        refreshContext()
        while let id = queue.nextID() {
            do { try await play(trackID: id); return }
            catch let error as AudioPlaybackError where error == .missingFile || error == .trackNotFound {
                try? storage?.tracks.updateAvailability(id: id, .missing)
                refreshContext()
            } catch { handleTransitionFailure(error); return }
        }
        state.status = .ended; player.pause(); history.finish(duration: state.elapsedTime); publishCurrent(); persist()
    }

    func previous() async {
        refreshContext()
        if state.elapsedTime > 3 { await seek(to: 0); return }
        while let id = queue.previousID() {
            do { try await play(trackID: id); return }
            catch let error as AudioPlaybackError where error == .missingFile || error == .trackNotFound {
                try? storage?.tracks.updateAvailability(id: id, .missing)
                refreshContext()
            } catch { handleTransitionFailure(error); return }
        }
        await seek(to: 0)
    }

    func refreshContext() {
        let currentID = state.currentTrackID
        let tracks = (try? storage?.tracks.all()) ?? []
        var ids: [String] = []
        for track in tracks where track.availability == .available && !ids.contains(track.id) { ids.append(track.id) }
        context = PlaybackContext(trackIDs: ids, currentIndex: nil)
        if let currentID { context = context.settingCurrent(currentID) }
        queue.setContext(ids, current: currentID)
        updateSkipAvailability()
    }
    func seek(to seconds: TimeInterval) async { guard state.canSeek else { return }; let bounded = min(max(seconds, 0), state.duration); state.isSeeking = true; await player.seek(to: CMTime(seconds: bounded, preferredTimescale: 600)); state.elapsedTime = bounded; state.isSeeking = false; publishCurrent(); persist() }

    private func restorePausedItem(trackID: String, position: TimeInterval) async {
        guard let resolved = try? resolver.resolve(trackID: trackID) else { fail("The saved track is no longer available"); return }
        replaceItem(with: AVPlayerItem(url: resolved.url), trackID: trackID, track: resolved.track)
        state.status = .paused
        if position > 0 { await player.seek(to: CMTime(seconds: min(position, max(state.duration, position)), preferredTimescale: 600)); state.elapsedTime = position }
        publish(track: resolved.track)
    }

    private func replaceItem(with newItem: AVPlayerItem, trackID: String, track: StoredTrack) {
        removeItemObservers(); item = newItem; state.currentTrackID = trackID; state.status = .loading; state.elapsedTime = 0; state.duration = 0
        statusObserver = newItem.observe(\.status, options: [.initial, .new]) { [weak self] item, _ in Task { @MainActor in guard let self, self.item === item else { return }; if item.status == .failed { self.fail(item.error?.localizedDescription ?? "Audio could not be loaded") } else if item.status == .readyToPlay { self.state.duration = item.asset.duration.seconds.isFinite ? item.asset.duration.seconds : 0; if self.state.status == .loading { self.state.status = .ready }; self.publish(track: track) } } }
        endObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: newItem, queue: .main) { [weak self] notification in Task { @MainActor in guard let self, notification.object as? AVPlayerItem === self.item, !self.completionInFlight else { return }; self.completionInFlight = true; await self.next(); self.completionInFlight = false } }
        player.replaceCurrentItem(with: newItem); installTimeObserver(); state.duration = newItem.asset.duration.seconds.isFinite ? newItem.asset.duration.seconds : 0
    }

    private func installTimeObserver() { if let timeObserver { player.removeTimeObserver(timeObserver) }; timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.5, preferredTimescale: 600), queue: .main) { [weak self] time in Task { @MainActor in guard let self, !self.state.isSeeking else { return }; let seconds = time.seconds; if seconds.isFinite { self.state.elapsedTime = min(max(0, seconds), max(self.state.duration, seconds)); self.publishCurrent() } } } }
    private func removeItemObservers() { statusObserver?.invalidate(); statusObserver = nil; if let endObserver { NotificationCenter.default.removeObserver(endObserver); self.endObserver = nil } }
    private func updateContext(with id: String) { refreshContext(); if !context.trackIDs.contains(id) { context.trackIDs.append(id) }; context = context.settingCurrent(id); updateSkipAvailability() }
    private func updateSkipAvailability() { state.canSkipNext = context.nextID != nil; state.canSkipPrevious = context.previousID != nil; remoteCommands.updateCapabilities(state: state) }
    private func publish(track: StoredTrack) { let artwork = track.artworkRelativePath.flatMap { try? storage?.paths.artworkURL(relativePath: $0) }.flatMap { try? Data(contentsOf: $0) }; nowPlaying.update(state: state, track: track, artist: storage?.artistName(for: track.artistID), album: storage?.albumTitle(for: track.albumID), artworkData: artwork); state.currentOutputRoute = session.outputRouteName }
    private func publishCurrent() { guard let storage, let id = state.currentTrackID, let track = try? storage.tracks.find(id: id) else { return }; publish(track: track) }
    private func persist() { queue.persistState(currentTrackID: state.currentTrackID, positionMs: Int64(max(0, state.elapsedTime) * 1000), sleepDeadline: sleepTimer.deadline) }
    private func expireSleepTimer() { player.pause(); state.status = state.currentTrackID == nil ? .idle : .paused; state.lastError = nil; publishCurrent(); persist() }
    private func fail(_ message: String) { player.pause(); state.status = .failed(message: message); state.lastError = message; publishCurrent(); persist() }
    private func handleTransitionFailure(_ error: Error) { state.lastError = error.localizedDescription; NSLog("Muzik Belesh playback transition failed: %@", error.localizedDescription); publishCurrent(); persist() }
    private func handleRouteChange(route: String, reason: AVAudioSession.RouteChangeReason) { state.currentOutputRoute = route; if reason == .oldDeviceUnavailable && state.isPlaying { pause() }; publishCurrent() }
    private func handleInterruption(_ notification: Notification) { guard let typeValue = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt, let type = AVAudioSession.InterruptionType(rawValue: typeValue) else { return }; if type == .began { wasPlayingBeforeInterruption = state.isPlaying; userPausedDuringInterruption = false; if state.isPlaying { player.pause() }; state.status = .interrupted; publishCurrent() } else if type == .ended { let options = notification.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0; let shouldResume = AVAudioSession.InterruptionOptions(rawValue: options).contains(.shouldResume); if wasPlayingBeforeInterruption && shouldResume && !userPausedDuringInterruption { player.play(); state.status = .playing } else if state.currentTrackID != nil { state.status = .paused }; publishCurrent(); persist() } }
}
