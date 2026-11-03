import AVFoundation
import Foundation

@MainActor
final class AudioPlayerService: ObservableObject {
    @Published private(set) var state = AudioPlaybackState()

    private let player: PlaybackPlayer
    private let nativePlayer: AVPlayer?
    private let commandGate = PlaybackCommandGate()
    private var intentRevision = 0
    private var timerExpired = false
    private var completedGeneration: Int?
    private var transportObserver: NSKeyValueObservation?
    private var wantsPlayback = false
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
    private var itemGeneration = 0
    private let endpointTolerance: TimeInterval = 0.25

    init(storage: StorageCoordinator?, player: PlaybackPlayer? = nil, registerRemoteCommands: Bool = true, makeShuffle: @escaping ([String]) -> [String] = { $0.shuffled() }) {
        self.player = player ?? NativePlaybackPlayer()
        self.nativePlayer = self.player.nativePlayer
        self.storage = storage
        resolver = LocalAudioAssetResolver(storage: storage)
        persistence = PlaybackPersistenceCoordinator(storage: storage)
        queue = PlaybackQueueManager(storage: storage, makeShuffle: makeShuffle)
        history = PlaybackHistoryService(storage: storage)
        let restoration = persistence.restore()
        let savedDeadline: Date?
        let savedDuration: TimeInterval?
        if let storage, let saved = (try? storage.playback.state()) ?? nil, let milliseconds = saved.sleepTimerDeadlineMs {
            savedDeadline = Date(timeIntervalSince1970: TimeInterval(milliseconds) / 1000)
            savedDuration = saved.sleepTimerDurationMs.map { TimeInterval($0) / 1000 }
        } else { savedDeadline = nil; savedDuration = nil }
        sleepTimer = SleepTimerService(deadline: savedDeadline, duration: savedDuration)
        queue.onStateChanged = { [weak self] in self?.updateSkipAvailability(); self?.persist() }
        sleepTimer.onExpire = { [weak self] in self?.expireSleepTimer() }
        sleepTimer.onChange = { [weak self] in
            if self?.sleepTimer.isActive == true { self?.timerExpired = false }
            self?.persist()
        }
        sleepTimer.reconcile { [weak self] in self?.expireSleepTimer() }
        routeMonitor.onRouteChanged = { [weak self] route, reason in
            Task { @MainActor in self?.handleRouteChange(route: route, reason: reason) }
        }
        interruptionObserver = NotificationCenter.default.addObserver(forName: AVAudioSession.interruptionNotification, object: AVAudioSession.sharedInstance(), queue: .main) { [weak self] notification in
            Task { @MainActor in self?.handleInterruption(notification) }
        }
        if let saved = restoration { state.currentTrackID = saved.currentTrackID }
        refreshContext()
        if let saved = restoration, let id = saved.currentTrackID { state.currentTrackID = id; state.elapsedTime = TimeInterval(saved.positionMs) / 1000; context = context.settingCurrent(id); updateSkipAvailability(); let position = state.elapsedTime; Task { @MainActor [weak self] in await self?.restorePausedItem(trackID: id, position: position) } }
        if registerRemoteCommands { remoteCommands.register(service: self) }
        if let native = self.player.nativePlayer {
            transportObserver = native.observe(\.timeControlStatus, options: [.new]) { [weak self] _, _ in
                Task { @MainActor [weak self] in self?.synchronizeTransport() }
            }
        }
    }

    deinit {
        if let timeObserver { nativePlayer?.removeTimeObserver(timeObserver) }
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        if let interruptionObserver { NotificationCenter.default.removeObserver(interruptionObserver) }
        statusObserver?.invalidate(); transportObserver?.invalidate(); remoteCommands.unregister()
    }

    func play(trackID: String, direction: NavigationDirection = .forward) async throws {
        await commandGate.acquire()
        defer { commandGate.release() }
        timerExpired = false
        queue.cancelCandidate()
        try await selectTrack(trackID, direction: direction)
    }

    private func selectTrack(_ trackID: String, direction: NavigationDirection = .forward) async throws {
        guard reconcileSleepTimer() else { throw AudioPlaybackError.playerFailed("Sleep Timer has expired") }
        do {
            let resolved = try resolver.resolve(trackID: trackID)
            let revision = intentRevision
            let asset = AVURLAsset(url: resolved.url)
            let audioTracks = try await asset.loadTracks(withMediaType: .audio)
            guard !audioTracks.isEmpty else { throw AudioPlaybackError.unsupportedAudio }
            let duration = try await asset.load(.duration)
            guard duration.seconds.isFinite, duration.seconds > 0 else { throw AudioPlaybackError.unsupportedAudio }
            guard revision == intentRevision, reconcileSleepTimer() else { throw AudioPlaybackError.playerFailed("Playback transition was cancelled.") }
            try session.configure()
            updateContext(with: trackID)
            queue.setCurrent(trackID)
            replaceItem(with: AVPlayerItem(asset: asset), trackID: trackID, track: resolved.track)
            state.duration = duration.seconds
            wantsPlayback = true; player.play()
            synchronizeTransport()
            history.started(trackID: trackID)
            queue.didStart(trackID, direction: direction)
            state.lastError = nil
            publish(track: resolved.track)
            persist()
        } catch {
            handleTransitionFailure(error)
            throw error
        }
    }

    func play() async throws {
        await commandGate.acquire()
        defer { commandGate.release() }
        timerExpired = false
        try await resumePlayback()
    }

    private func resumePlayback() async throws {
        guard reconcileSleepTimer() else { return }
        guard state.currentTrackID != nil else { throw AudioPlaybackError.trackNotFound }
        if state.status == .ended || (state.canSeek && state.elapsedTime >= state.duration - endpointTolerance) {
            if queue.repeatMode == .all {
                await advance()
                return
            }
            try await restartCurrentTrack()
            return
        }
        if case .failed = state.status, let id = state.currentTrackID { try await selectTrack(id); return }
        try session.configure(); wantsPlayback = true; player.play(); synchronizeTransport(); state.lastError = nil; publishCurrent(); persist()
    }

    func playFromRemote() async { do { try await play() } catch { handleTransitionFailure(error) } }
    func enqueueRemote(command: String, operation: @escaping () async -> Void) {
        Task { @MainActor [weak self] in
            #if DEBUG
            NSLog("Muzik Belesh remote command=%@ current=%@ shuffle=%@ repeat=%@ service=%ld", command, self?.state.currentTrackID ?? "none", self?.queue.shuffleEnabled.description ?? "false", self?.queue.repeatMode.rawValue ?? "off", self.map { ObjectIdentifier($0).hashValue } ?? 0)
            #endif
            await operation()
        }
    }
    func pause() { intentRevision += 1; wantsPlayback = false; player.pause(); state.status = state.currentTrackID == nil ? .idle : .paused; userPausedDuringInterruption = true; publishCurrent(); persist() }
    func togglePlayback() async { if wantsPlayback { pause() } else { await playFromRemote() } }
    func stop() { intentRevision += 1; wantsPlayback = false; itemGeneration += 1; removeItemObservers(); player.pause(); player.replaceCurrentItem(with: nil); item = nil; history.finish(duration: state.elapsedTime); state.elapsedTime = 0; state.status = .idle; state.currentTrackID = nil; nowPlaying.clear(); session.deactivate(); persist() }

    func next() async {
        await commandGate.acquire()
        defer { commandGate.release() }
        await advance()
    }

    private func advance() async {
        guard reconcileSleepTimer() else { return }
        refreshContext()
        var attempted = Set<String>()
        while let id = queue.nextID(), attempted.insert(id).inserted {
            do { try await selectTrack(id, direction: .forward); return }
            catch let error as AudioPlaybackError where error == .missingFile || error == .trackNotFound || error == .unsupportedAudio {
                try? storage?.tracks.updateAvailability(id: id, .missing)
                queue.rejectCandidate(id); refreshContext()
            } catch { handleTransitionFailure(error); return }
        }
        wantsPlayback = false; state.status = .ended; player.pause(); history.finish(duration: state.elapsedTime); publishCurrent(); persist()
    }

    func previous() async {
        await commandGate.acquire()
        defer { commandGate.release() }
        guard reconcileSleepTimer() else { return }
        refreshContext()
        if state.elapsedTime > 3 { await performSeek(to: 0); return }
        var attempted = Set<String>()
        while let id = queue.previousID(), attempted.insert(id).inserted {
            do { try await selectTrack(id, direction: .previous); return }
            catch let error as AudioPlaybackError where error == .missingFile || error == .trackNotFound || error == .unsupportedAudio {
                try? storage?.tracks.updateAvailability(id: id, .missing)
                queue.rejectCandidate(id); refreshContext()
            } catch { handleTransitionFailure(error); return }
        }
        await performSeek(to: 0)
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
    func seek(to seconds: TimeInterval) async {
        await commandGate.acquire()
        defer { commandGate.release() }
        await performSeek(to: seconds)
    }

    private func performSeek(to seconds: TimeInterval) async {
        guard seconds.isFinite, state.canSeek, reconcileSleepTimer() else { return }
        let generation = itemGeneration
        let revision = intentRevision
        let wasPlaying = wantsPlayback
        let endpoint = seconds >= state.duration - endpointTolerance
        state.isSeeking = true
        // Suppress completion before AVFoundation can post an endpoint notification.
        if endpoint { completedGeneration = generation }
        defer { state.isSeeking = false }
        debugTransition(action: "seek", detail: "endpoint=\(endpoint)")
        if endpoint {
            if wasPlaying && queue.repeatMode == .all {
                await advance()
                return
            }
            let finished = await player.seek(to: .zero)
            guard generation == itemGeneration, revision == intentRevision, reconcileSleepTimer() else { return }
            guard finished else { handleTransitionFailure(AudioPlaybackError.playerFailed("Seek was cancelled.")); return }
            state.elapsedTime = 0
            completedGeneration = nil
            if wasPlaying && queue.repeatMode == .one { wantsPlayback = true; player.play(); synchronizeTransport() }
            else { wantsPlayback = false; player.pause(); state.status = .paused }
        } else {
            let bounded = min(max(seconds, 0), state.duration)
            let finished = await player.seek(to: CMTime(seconds: bounded, preferredTimescale: 600))
            guard generation == itemGeneration, revision == intentRevision, reconcileSleepTimer() else { return }
            guard finished else { handleTransitionFailure(AudioPlaybackError.playerFailed("Seek was cancelled.")); return }
            state.elapsedTime = bounded
            completedGeneration = nil
        }
        updateSkipAvailability(); publishCurrent(); persist()
    }

    private func restorePausedItem(trackID: String, position: TimeInterval) async {
        await commandGate.acquire()
        defer { commandGate.release() }
        guard state.currentTrackID == trackID, item == nil else { return }
        guard let resolved = try? resolver.resolve(trackID: trackID) else { fail("The saved track is no longer available"); return }
        replaceItem(with: AVPlayerItem(url: resolved.url), trackID: trackID, track: resolved.track)
        state.status = .paused
        if position > 0 { _ = await player.seek(to: CMTime(seconds: min(position, max(0, state.duration - endpointTolerance)), preferredTimescale: 600)); state.elapsedTime = min(position, max(0, state.duration - endpointTolerance)) }
        publish(track: resolved.track)
    }

    private func replaceItem(with newItem: AVPlayerItem, trackID: String, track: StoredTrack) {
        removeItemObservers(); itemGeneration += 1; completedGeneration = nil; let generation = itemGeneration; item = newItem; state.currentTrackID = trackID; state.status = .loading; state.elapsedTime = 0; state.duration = TimeInterval(track.durationMs ?? 0) / 1000
        statusObserver = newItem.observe(\.status, options: [.initial, .new]) { [weak self] item, _ in Task { @MainActor in guard let self, self.item === item else { return }; if item.status == .failed { self.fail(item.error?.localizedDescription ?? "Audio could not be loaded") } else if item.status == .readyToPlay { let duration = item.duration.seconds; if duration.isFinite && duration > 0 { self.state.duration = duration }; self.synchronizeTransport(); self.publish(track: track) } } }
        endObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: newItem, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in await self?.completedItem(generation: generation) }
        }
        player.replaceCurrentItem(with: newItem); installTimeObserver(); updateSkipAvailability()
    }

    private func installTimeObserver() {
        guard let native = player.nativePlayer else { return }
        if let timeObserver { native.removeTimeObserver(timeObserver) }
        let generation = itemGeneration
        timeObserver = native.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.5, preferredTimescale: 600), queue: .main) { [weak self] time in
            Task { @MainActor [weak self] in
                guard let self, generation == self.itemGeneration, !self.state.isSeeking, time.seconds.isFinite else { return }
                self.state.elapsedTime = max(0, time.seconds)
                self.updateSkipAvailability(); self.publishCurrent()
            }
        }
    }

    func completedItem(generation: Int) async {
        await commandGate.acquire()
        defer { commandGate.release() }
        guard generation == itemGeneration, completedGeneration != generation, wantsPlayback, reconcileSleepTimer() else { return }
        if let native = player.nativePlayer, state.canSeek, native.currentTime().seconds < state.duration - endpointTolerance { return }
        completedGeneration = generation
        debugTransition(action: "completion", detail: "generation=\(generation)")
        await advance()
    }

    var activeItemGeneration: Int { itemGeneration }

    private func synchronizeTransport() {
        guard state.currentTrackID != nil, wantsPlayback else { return }
        if let native = player.nativePlayer, native.currentItem?.status == .failed { fail("The audio item could not be played."); return }
        state.status = player.isPlaying ? .playing : .loading
        updateSkipAvailability(); publishCurrent()
    }

    private func removeItemObservers() { statusObserver?.invalidate(); statusObserver = nil; if let endObserver { NotificationCenter.default.removeObserver(endObserver); self.endObserver = nil } }
    private func updateContext(with id: String) { refreshContext(); if !context.trackIDs.contains(id) { context.trackIDs.append(id) }; context = context.settingCurrent(id); updateSkipAvailability() }
    private func updateSkipAvailability() { state.canSkipNext = queue.hasNext(); state.canSkipPrevious = queue.hasPrevious() || state.elapsedTime > 3; remoteCommands.updateCapabilities(state: state) }
    private func restartCurrentTrack(keepPlaying: Bool = true) async throws {
        guard state.currentTrackID != nil else { throw AudioPlaybackError.trackNotFound }
        let generation = itemGeneration; let revision = intentRevision
        let finished = await player.seek(to: .zero)
        guard finished, generation == itemGeneration, revision == intentRevision, reconcileSleepTimer() else { return }
        completedGeneration = nil; wantsPlayback = keepPlaying
        state.elapsedTime = 0
        state.status = .paused
        if keepPlaying { try session.configure(); player.play(); synchronizeTransport() } else { player.pause() }
        publishCurrent(); persist()
    }
    private func publish(track: StoredTrack) { let artwork = track.artworkRelativePath.flatMap { try? storage?.paths.artworkURL(relativePath: $0) }.flatMap { try? Data(contentsOf: $0) }; nowPlaying.update(state: state, track: track, artist: storage?.artistName(for: track.artistID), album: storage?.albumTitle(for: track.albumID), artworkData: artwork); state.currentOutputRoute = session.outputRouteName }
    private func publishCurrent() { guard let storage, let id = state.currentTrackID, let track = try? storage.tracks.find(id: id) else { return }; publish(track: track) }
    private func persist() { queue.persistState(currentTrackID: state.currentTrackID, positionMs: Int64(max(0, state.elapsedTime) * 1000), sleepDeadline: sleepTimer.deadline, sleepTimerDuration: sleepTimer.durationSeconds) }
    func reconcileLifecycle() { sleepTimer.checkDeadline(); updateSkipAvailability(); persist() }
    private func expireSleepTimer() { timerExpired = true; intentRevision += 1; wantsPlayback = false; player.pause(); state.status = state.currentTrackID == nil ? .idle : .paused; state.lastError = nil; publishCurrent(); persist() }
    private func reconcileSleepTimer() -> Bool { guard !timerExpired else { return false }; guard let deadline = sleepTimer.deadline, deadline <= Date() else { return true }; sleepTimer.cancel(); expireSleepTimer(); return false }
    private func fail(_ message: String) { wantsPlayback = false; player.pause(); state.status = .failed(message: message); state.lastError = message; publishCurrent(); persist() }
    private func handleTransitionFailure(_ error: Error) { state.lastError = error.localizedDescription; NSLog("Muzik Belesh playback transition failed: %@", error.localizedDescription); publishCurrent(); persist() }
    private func debugTransition(action: String, detail: String) {
        #if DEBUG
        NSLog("Muzik Belesh transition action=%@ detail=%@ current=%@ status=%@ time=%.2f duration=%.2f shuffle=%@ repeat=%@ next=%@ previous=%@", action, detail, state.currentTrackID ?? "none", String(describing: state.status), state.elapsedTime, state.duration, queue.shuffleEnabled.description, queue.repeatMode.rawValue, state.canSkipNext.description, state.canSkipPrevious.description)
        #endif
    }
    private func handleRouteChange(route: String, reason: AVAudioSession.RouteChangeReason) { state.currentOutputRoute = route; if reason == .oldDeviceUnavailable && state.isPlaying { pause() }; publishCurrent() }
    private func handleInterruption(_ notification: Notification) { guard let typeValue = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt, let type = AVAudioSession.InterruptionType(rawValue: typeValue) else { return }; if type == .began { wasPlayingBeforeInterruption = state.isPlaying; userPausedDuringInterruption = false; if state.isPlaying { player.pause() }; state.status = .interrupted; publishCurrent() } else if type == .ended { let options = notification.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0; let shouldResume = AVAudioSession.InterruptionOptions(rawValue: options).contains(.shouldResume); if wasPlayingBeforeInterruption && shouldResume && !userPausedDuringInterruption && reconcileSleepTimer() { wantsPlayback = true; player.play(); synchronizeTransport() } else if state.currentTrackID != nil { state.status = .paused }; publishCurrent(); persist() } }
}
