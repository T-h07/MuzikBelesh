import OSLog
import UIKit
import AVFoundation
import Foundation

@MainActor
final class AudioPlayerService: ObservableObject {
    @Published private(set) var state = AudioPlaybackState()

    private var resourcePolicy = ResourcePolicy()
    private var foreground = UIApplication.shared.applicationState != .background
    private var mediaResetObserver: NSObjectProtocol?
    private var libraryTimeline: Double?
    private let player: PlaybackPlayer
    private var nativePlayer: AVPlayer?
    private let commandGate = PlaybackCommandGate()
    let diagnostics = PlaybackDiagnostics()
    private var seekRevision = 0
    private var intentRevision = 0
    private var timerExpired = false
    private var completedGeneration: Int?
    private var artworkTask: Task<Void, Never>?
    private var artworkCachePath: String?
    private var artworkCacheData: Data?
    private var transportVerification: Task<Void, Never>?
    private var transportObserver: NSKeyValueObservation?
    private var wantsPlayback = false
    private var lastSavedPosition: TimeInterval = 0
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
    private var activeContextTrackIDs: [String]?
    private var activeContextKind: String?
    private var activeContextSourceID: String?
    private var deletingTrackIDs: Set<String> = []
    private var context = PlaybackContext(trackIDs: [], currentIndex: nil)
    private var wasPlayingBeforeInterruption = false
    private var userPausedDuringInterruption = false
    private var itemGeneration = 0
    private let endpointTolerance: TimeInterval = 0.25
    private var remoteOperations: [(String, () async -> Void)] = []
    private var processingRemote = false

    init(storage: StorageCoordinator?, player: PlaybackPlayer? = nil, registerRemoteCommands: Bool = true, makeShuffle: @escaping ([String]) -> [String] = { $0.shuffled() }) {
        self.player = player ?? NativePlaybackPlayer()
        self.nativePlayer = self.player.nativePlayer
        self.storage = storage
        resolver = LocalAudioAssetResolver(storage: storage)
        persistence = PlaybackPersistenceCoordinator(storage: storage)
        queue = PlaybackQueueManager(storage: storage, makeShuffle: makeShuffle)
        history = PlaybackHistoryService(storage: storage)
        let restoration = persistence.restore()
        activeContextKind = restoration?.contextKind
        activeContextSourceID = restoration?.contextSourceID
        if activeContextKind != nil, let data = restoration?.contextTrackIDsJSON?.data(using: .utf8) {
            activeContextTrackIDs = try? JSONDecoder().decode([String].self, from: data)
        }
        let savedDeadline: Date?
        let savedDuration: TimeInterval?
        if let storage, let saved = (try? storage.playback.state()) ?? nil, let milliseconds = saved.sleepTimerDeadlineMs {
            savedDeadline = Date(timeIntervalSince1970: TimeInterval(milliseconds) / 1000)
            savedDuration = saved.sleepTimerDurationMs.map { TimeInterval($0) / 1000 }
        } else { savedDeadline = nil; savedDuration = nil }
        sleepTimer = SleepTimerService(deadline: savedDeadline, duration: savedDuration)
        state.currentTrackID = restoration?.currentTrackID
        state.elapsedTime = TimeInterval(restoration?.positionMs ?? 0) / 1000
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
        mediaResetObserver = NotificationCenter.default.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in self?.handleMediaServicesReset() }
        }
        if let saved = restoration { state.currentTrackID = saved.currentTrackID }
        refreshContext()
        if let saved = restoration, let id = saved.currentTrackID { state.currentTrackID = id; state.elapsedTime = TimeInterval(saved.positionMs) / 1000; context = context.settingCurrent(id); updateSkipAvailability(); let position = state.elapsedTime; Task { @MainActor [weak self] in await self?.restorePausedItem(trackID: id, position: position) } }
        if registerRemoteCommands { remoteCommands.register(service: self) }
        observeTransport()
    }

    private func observeTransport() {
        if let native = self.player.nativePlayer {
            transportObserver = native.observe(\.timeControlStatus, options: [.new]) { [weak self] _, _ in
                Task { @MainActor [weak self] in self?.synchronizeTransport() }
            }
        }
    }

    deinit {
        transportVerification?.cancel(); artworkTask?.cancel()
        if let timeObserver { nativePlayer?.removeTimeObserver(timeObserver) }
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        if let interruptionObserver { NotificationCenter.default.removeObserver(interruptionObserver) }
        if let mediaResetObserver { NotificationCenter.default.removeObserver(mediaResetObserver) }
        statusObserver?.invalidate(); transportObserver?.invalidate(); remoteCommands.unregister()
    }

    func play(trackID: String, direction: NavigationDirection = .forward, contextTrackIDs: [String]? = nil, contextKind: String? = nil, contextSourceID: String? = nil) async throws {
        guard await beginCommand("select") else { throw AudioPlaybackError.playerFailed("Playback is busy. Try again.") }
        defer { endCommand() }
        timerExpired = false
        queue.cancelCandidate()
        let old = (activeContextTrackIDs, activeContextKind, activeContextSourceID)
        let rollback = queue.selectionRollback()
        queue.clearMigrationContext()
        activeContextTrackIDs = contextTrackIDs.map { ids in var seen = Set<String>(); return ids.filter { seen.insert($0).inserted } }
        activeContextKind = contextTrackIDs == nil ? nil : (contextKind ?? "library")
        activeContextSourceID = contextSourceID
        do { try await selectTrack(trackID, direction: direction) }
        catch {
            (activeContextTrackIDs, activeContextKind, activeContextSourceID) = old
            rollback()
            refreshContext(); persist(); throw error
        }
    }

    func playMigration(occurrences: [MigrationPlaybackOccurrence], selected: String, playlistID: String, shuffle: Bool) async throws {
        guard let occurrence = occurrences.first(where: { $0.id == selected }) else { return }
        guard await beginCommand("select") else { throw AudioPlaybackError.playerFailed("Playback is busy. Try again.") }
        defer { endCommand() }
        // Resolve before changing navigation, then selectTrack validates again before AVPlayer.
        _ = try resolver.resolve(trackID: occurrence.trackID)
        let old = (activeContextTrackIDs, activeContextKind, activeContextSourceID)
        let rollback = queue.selectionRollback()
        timerExpired = false; queue.cancelCandidate()
        activeContextTrackIDs = occurrences.map(\.trackID); activeContextKind = "migrationPlaylist"; activeContextSourceID = playlistID
        queue.setMigrationContext(occurrences, selected: selected)
        if queue.shuffleEnabled != shuffle { queue.toggleShuffle() }
        do { try await selectTrack(occurrence.trackID) }
        catch {
            (activeContextTrackIDs, activeContextKind, activeContextSourceID) = old
            rollback(); refreshContext(); persist(); throw error
        }
    }

    private func selectTrack(_ trackID: String, direction: NavigationDirection = .forward, autoplay: Bool = true, recordNavigation: Bool = true) async throws {
        let signposter = OSSignposter(subsystem: "com.th07.muzikbelesh", category: "Performance")
        let interval = signposter.beginInterval("BeginPlayback")
        defer { signposter.endInterval("BeginPlayback", interval) }
        guard !deletingTrackIDs.contains(trackID) else { throw LibraryError.deletionInProgress }
        guard reconcileSleepTimer() else { throw AudioPlaybackError.playerFailed("Sleep Timer has expired") }
        do {
            let resolved = try resolver.resolve(trackID: trackID)
            if activeContextKind == "migrationPlaylist", let storage,
               !MigrationLocalAudio.isAvailable(resolved.track, paths: storage.paths) { throw AudioPlaybackError.missingFile }
            let revision = intentRevision
            let asset = AVURLAsset(url: resolved.url)
            let duration = try await PlaybackAssetInspection.duration(of: asset)
            guard duration.seconds.isFinite, duration.seconds > 0 else { throw AudioPlaybackError.unsupportedAudio }
            let localDuration = await storage?.downloadPlaybackDuration(track: resolved.track, url: resolved.url)
            guard revision == intentRevision, reconcileSleepTimer() else { throw CancellationError() }
            try session.configure()
            updateContext(with: trackID)
            queue.setCurrent(trackID)
            replaceItem(with: AVPlayerItem(asset: asset), trackID: trackID, track: resolved.track, localDuration: localDuration)
            state.duration = libraryTimeline ?? duration.seconds
            wantsPlayback = autoplay
            if autoplay { player.play(); synchronizeTransport() }
            else { player.pause(); state.status = .paused }
            if recordNavigation { history.started(trackID: trackID); queue.didStart(trackID, direction: direction) }
            state.lastError = nil
            publish(track: resolved.track)
            persist()
        } catch {
            handleTransitionFailure(error)
            throw error
        }
    }

    func play() async throws {
        guard await beginCommand("play") else { throw AudioPlaybackError.playerFailed("Playback is busy. Try again.") }
        defer { endCommand() }
        timerExpired = false
        try await resumePlayback()
    }

    private func resumePlayback() async throws {
        guard reconcileSleepTimer() else { return }
        guard state.currentTrackID != nil else { throw AudioPlaybackError.trackNotFound }
        if state.status == .ended || (state.canSeek && state.elapsedTime >= state.duration - endpointTolerance) {
            if queue.repeatMode == .all {
                await advance(reason: .automatic)
                return
            }
            try await restartCurrentTrack()
            return
        }
        if case .failed = state.status, let id = state.currentTrackID { try await selectTrack(id, recordNavigation: false); return }
        if item == nil, let id = state.currentTrackID { try await selectTrack(id, recordNavigation: false); return }
        try requireAvailableMigrationAudio()
        try session.configure(); wantsPlayback = true; player.play(); synchronizeTransport(); state.lastError = nil; publishCurrent(); persist()
    }

    private func requireAvailableMigrationAudio() throws {
        guard activeContextKind == "migrationPlaylist" else { return }
        guard let id = state.currentTrackID, let storage else { throw AudioPlaybackError.trackNotFound }
        let resolved = try resolver.resolve(trackID: id)
        guard MigrationLocalAudio.isAvailable(resolved.track, paths: storage.paths) else { throw AudioPlaybackError.missingFile }
    }

    func playFromRemote() async { do { try await play() } catch { handleTransitionFailure(error) } }
    func enqueueRemote(command: String, operation: @escaping () async -> Void) {
        remoteOperations.append((command, operation))
        guard !processingRemote else { return }
        processingRemote = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.processingRemote = false }
            while !self.remoteOperations.isEmpty {
                let (command, operation) = self.remoteOperations.removeFirst()
                self.record("remote-dispatch", reason: ["play", "pause", "toggle", "next", "previous", "seek"].contains(command) ? command : "test")
                await PlaybackCommandSource.$value.withValue("remote") { await operation() }
            }
        }
    }
    func pause() { synchronizeClock(); record("pause-request"); intentRevision += 1; wantsPlayback = false; player.pause(); state.status = state.currentTrackID == nil ? .idle : .paused; userPausedDuringInterruption = true; publishCurrent(); persist() }
    func togglePlayback() async { if wantsPlayback { pause() } else { await playFromRemote() } }
    func stop() { record("stop-request"); intentRevision += 1; wantsPlayback = false; itemGeneration += 1; removeItemObservers(); player.pause(); player.replaceCurrentItem(with: nil); item = nil; artworkTask?.cancel(); artworkCachePath = nil; artworkCacheData = nil; history.finish(duration: state.elapsedTime); state.elapsedTime = 0; state.status = .idle; state.currentTrackID = nil; nowPlaying.clear(); session.deactivate(); persist() }

    func next() async {
        guard await beginCommand("next") else { return }
        defer { endCommand() }
        await advance(reason: .manual)
    }

    private func advance(reason: PlaybackAdvanceReason) async {
        guard reconcileSleepTimer() else { return }
        refreshContext()
        var attempted = Set<String>()
        while let id = queue.nextID(reason: reason), attempted.insert(id).inserted {
            do { try await selectTrack(id, direction: .forward); return }
            catch let error as AudioPlaybackError where error == .missingFile || error == .trackNotFound || error == .unsupportedAudio {
                try? storage?.tracks.updateAvailability(id: id, .missing)
                queue.rejectCandidate(id); refreshContext()
            } catch { handleTransitionFailure(error); return }
        }
        queue.cancelCandidate()
        record("navigation-boundary", reason: reason == .automatic ? "automatic-exhausted" : "manual-exhausted")
        wantsPlayback = false; state.status = .ended; player.pause(); history.finish(duration: state.elapsedTime); updateSkipAvailability(); publishCurrent(); persist()
    }

    func previous() async {
        guard await beginCommand("previous") else { return }
        defer { endCommand() }
        synchronizeClock()
        guard reconcileSleepTimer() else { return }
        refreshContext()
        let failed: Bool
        if case .failed = state.status { failed = true } else { failed = false }
        let ended = failed || state.status == .ended || completedGeneration == itemGeneration
        if !ended && state.elapsedTime > 3 { await performSeek(to: 0); return }
        queue.cancelCandidate()
        var attempted = Set<String>()
        while let id = queue.previousID(), attempted.insert(id).inserted {
            do { try await selectTrack(id, direction: .previous); return }
            catch let error as AudioPlaybackError where error == .missingFile || error == .trackNotFound || error == .unsupportedAudio {
                try? storage?.tracks.updateAvailability(id: id, .missing)
                queue.rejectCandidate(id); refreshContext()
            } catch { handleTransitionFailure(error); return }
        }
        if ended { do { try await restartCurrentTrack() } catch { handleTransitionFailure(error) } }
        else { await performSeek(to: 0) }
    }

    func refreshContext() {
        let currentID = state.currentTrackID
        if activeContextKind == "migrationPlaylist", let id = activeContextSourceID, let storage {
            do {
                let occurrences = try storage.playlistMigrations.hybridPlaybackOccurrences(playlistID: id)
                queue.refreshMigrationOccurrences(occurrences)
                activeContextTrackIDs = occurrences.map(\.trackID)
            } catch { state.lastError = "Playlist occurrences could not be refreshed."; return }
        }
        let tracks: [StoredTrack]
        do { tracks = try storage?.tracks.all() ?? [] }
        catch { state.lastError = "The playback library could not be read."; return }
        var ids = tracks.filter { $0.availability == .available && !deletingTrackIDs.contains($0.id) }.map(\.id)
        if let snapshot = activeContextTrackIDs {
            let available = Set(ids)
            ids = snapshot.filter { available.contains($0) }
            activeContextTrackIDs = ids
        }
        context = PlaybackContext(trackIDs: ids, currentIndex: nil)
        if let currentID { context = context.settingCurrent(currentID) }
        queue.setContext(ids, current: currentID)
        updateSkipAvailability()
    }
    func seek(to seconds: TimeInterval) async {
        guard await beginCommand("seek") else { return }
        defer { endCommand() }
        await performSeek(to: seconds)
    }

    private func performSeek(to seconds: TimeInterval) async {
        guard seconds.isFinite else { record("seek-rejected", reason: "nonfinite"); return }
        guard state.canSeek else { record("seek-rejected", reason: "no-duration"); return }
        guard reconcileSleepTimer() else { record("seek-rejected", reason: "timer-expired"); return }
        if case .failed = state.status {
            do { try await restartCurrentTrack(keepPlaying: false) }
            catch { handleTransitionFailure(error); return }
        }
        seekRevision += 1
        let generation = itemGeneration
        let revision = intentRevision
        let wasPlaying = wantsPlayback
        let endpoint = seconds >= state.duration - endpointTolerance
        state.isSeeking = true
        // Suppress completion before AVFoundation can post an endpoint notification.
        if endpoint { completedGeneration = generation }
        defer { state.isSeeking = false }
        record("seek-target", reason: endpoint ? "endpoint" : "interior")
        if endpoint {
            if wasPlaying && queue.repeatMode == .all {
                await advance(reason: .automatic)
                return
            }
            let finished = await player.seek(to: .zero)
            guard generation == itemGeneration, revision == intentRevision, reconcileSleepTimer() else { record("seek-rejected", reason: "superseded-or-timer"); return }
            guard finished else { handleTransitionFailure(AudioPlaybackError.playerFailed("Seek was cancelled.")); return }
            do { try await restartCurrentTrack(keepPlaying: wasPlaying && queue.repeatMode == .one) }
            catch { handleTransitionFailure(error) }
        } else {
            let bounded = min(max(seconds, 0), state.duration)
            let finished = await player.seek(to: CMTime(seconds: bounded, preferredTimescale: 600))
            guard generation == itemGeneration, revision == intentRevision, reconcileSleepTimer() else { record("seek-rejected", reason: "superseded-or-timer"); return }
            guard finished else { handleTransitionFailure(AudioPlaybackError.playerFailed("Seek was cancelled.")); return }
            state.elapsedTime = bounded
            completedGeneration = nil
            if !wantsPlayback { state.status = .paused } else { synchronizeTransport() }
        }
        updateSkipAvailability(); publishCurrent(); persist()
    }

    private func restorePausedItem(trackID: String, position: TimeInterval) async {
        guard await beginCommand("restore") else { return }
        defer { endCommand() }
        guard state.currentTrackID == trackID, item == nil else { return }
        guard let resolved = try? resolver.resolve(trackID: trackID) else { fail("The saved track is no longer available"); return }
        do { try requireAvailableMigrationAudio() }
        catch { fail("The saved track is no longer available"); return }
        let revision = intentRevision
        let localDuration = await storage?.downloadPlaybackDuration(track: resolved.track, url: resolved.url)
        guard revision == intentRevision, state.currentTrackID == trackID, item == nil else { return }
        replaceItem(with: AVPlayerItem(url: resolved.url), trackID: trackID, track: resolved.track, localDuration: localDuration)
        state.status = .paused
        if position > 0 { _ = await player.seek(to: CMTime(seconds: min(position, max(0, state.duration - endpointTolerance)), preferredTimescale: 600)); state.elapsedTime = min(position, max(0, state.duration - endpointTolerance)) }
        publish(track: resolved.track)
    }

    private func replaceItem(with newItem: AVPlayerItem, trackID: String, track: StoredTrack, localDuration: Double?) {
        libraryTimeline = localDuration
        if let libraryTimeline {
            newItem.forwardPlaybackEndTime = CMTime(seconds: libraryTimeline, preferredTimescale: 44100)
        }
        transportVerification?.cancel(); transportVerification = nil
        removeItemObservers(); itemGeneration += 1; completedGeneration = nil; let generation = itemGeneration; item = newItem; state.currentTrackID = trackID; state.status = .loading; state.elapsedTime = 0; state.duration = TimeInterval(track.durationMs ?? 0) / 1000
        statusObserver = newItem.observe(\.status, options: [.initial, .new]) { [weak self] item, _ in Task { @MainActor in guard let self, self.item === item else { return }; if item.status == .failed { self.fail("Audio could not be loaded. Try Play again.") } else if item.status == .readyToPlay { let duration = item.duration.seconds; if duration.isFinite && duration > 0 { self.state.duration = self.libraryTimeline ?? duration }; self.synchronizeTransport(); self.publish(track: track) } } }
        endObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: newItem, queue: .main) { [weak self, weak newItem] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let operationID = UUID()
                self.record("completion-arrived", reason: self.item === newItem ? "current-item" : "stale-item", operationID: operationID)
                guard self.item === newItem else { return }
                let receivedSeekRevision = self.seekRevision
                Task { @MainActor [weak self] in
                    await PlaybackCommandSource.$value.withValue("notification") {
                        await self?.completedItem(generation: generation, receivedSeekRevision: receivedSeekRevision, operationID: operationID)
                    }
                }
            }
        }
        player.replaceCurrentItem(with: newItem); installTimeObserver(); updateSkipAvailability()
    }

    private func installTimeObserver() {
        guard let native = player.nativePlayer else { return }
        if let timeObserver { native.removeTimeObserver(timeObserver) }
        let generation = itemGeneration
        timeObserver = native.addPeriodicTimeObserver(forInterval: CMTime(seconds: resourcePolicy.playbackInterval(foreground: foreground), preferredTimescale: 600), queue: .main) { [weak self] time in
            Task { @MainActor [weak self] in
                guard let self, generation == self.itemGeneration, !self.state.isSeeking, time.seconds.isFinite else { return }
                self.samplePlaybackTime(time.seconds)
            }
        }
    }

    func samplePlaybackTime(_ seconds: Double) {
        guard seconds.isFinite, !state.isSeeking else { return }
        let position = max(0, seconds)
        guard position != state.elapsedTime else { return }
        let crossedPreviousBoundary = (state.elapsedTime > 3) != (position > 3)
        state.elapsedTime = position
        if crossedPreviousBoundary { updateSkipAvailability() }
        if abs(position - lastSavedPosition) >= 5 {
            do {
                try storage?.playback.savePosition(trackID: state.currentTrackID, positionMs: Int64(position * 1000))
                lastSavedPosition = position
            } catch { state.lastError = "Playback position could not be saved." }
        }
    }

    func setResourcePolicy(_ policy: ResourcePolicy) {
        guard policy != resourcePolicy else { return }
        resourcePolicy = policy
        if item != nil { installTimeObserver() }
    }

    func setForeground(_ active: Bool) {
        guard active != foreground else { return }
        foreground = active
        synchronizeClock()
        if item != nil { installTimeObserver() }
        publishCurrent()
        persist()
    }

    private func synchronizeClock() {
        if let seconds = nativePlayer?.currentTime().seconds { samplePlaybackTime(seconds) }
    }

    func handleMediaServicesReset() {
        wasPlayingBeforeInterruption = false
        userPausedDuringInterruption = true
        // Rebuild native objects paused; only an explicit user Play may resume.
        intentRevision += 1
        wantsPlayback = false
        player.pause()
        removeItemObservers()
        player.replaceCurrentItem(with: nil)
        item = nil
        if let timeObserver { nativePlayer?.removeTimeObserver(timeObserver); self.timeObserver = nil }
        transportVerification?.cancel()
        transportVerification = nil
        transportObserver?.invalidate()
        player.resetAfterMediaServicesFailure()
        nativePlayer = player.nativePlayer
        observeTransport()
        session.deactivate()
        state.status = state.currentTrackID == nil ? .idle : .paused
        state.lastError = "Audio services restarted. Tap Play to continue."
        publishCurrent()
        persist()
        if let id = state.currentTrackID {
            let position = state.elapsedTime
            Task { @MainActor [weak self] in await self?.restorePausedItem(trackID: id, position: position) }
        }
    }

    func completedItem(generation: Int, receivedSeekRevision: Int? = nil, operationID: UUID = UUID()) async {
        let receivedSeekRevision = receivedSeekRevision ?? seekRevision
        record("completion-received", reason: "notification-or-injected", operationID: operationID)
        guard await beginCommand("completion", operationID: operationID) else {
            // A busy gate must not consume the one authoritative end event.
            record("completion-deferred", reason: "gate-timeout")
            Task { @MainActor [weak self] in
                guard let self, generation == self.itemGeneration, receivedSeekRevision == self.seekRevision else { return }
                await self.completedItem(generation: generation, receivedSeekRevision: receivedSeekRevision, operationID: operationID)
            }
            return
        }
        defer { endCommand() }
        guard generation == itemGeneration else { record("completion-ignored", reason: "stale-generation"); return }
        guard receivedSeekRevision == seekRevision else { record("completion-ignored", reason: "seek-superseded-event"); return }
        guard completedGeneration != generation else { record("completion-ignored", reason: "duplicate"); return }
        guard reconcileSleepTimer() else { record("completion-ignored", reason: "timer-expired"); return }
        guard wantsPlayback else { record("completion-ignored", reason: "playback-not-requested"); return }
        // Item identity + generation are authoritative. The decoder clock, periodic
        // UI time, stored metadata and item duration need not agree at EOF.
        completedGeneration = generation
        state.elapsedTime = state.duration
        record("completion-accepted")
        await advance(reason: .automatic)
    }

    var activeItemGeneration: Int { itemGeneration }

    private func synchronizeTransport() {
        guard state.currentTrackID != nil, wantsPlayback else { return }
        if let native = player.nativePlayer, native.currentItem?.status == .failed { fail("The audio item could not be played."); return }
        state.status = player.isPlaying ? .playing : .loading
        if let native = nativePlayer, native.timeControlStatus != .paused {
            transportVerification?.cancel(); transportVerification = nil
        }
        if let native = nativePlayer, native.timeControlStatus == .paused, transportVerification == nil {
            let generation = itemGeneration; let revision = intentRevision
            transportVerification = Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                guard !Task.isCancelled, let self else { return }
                self.transportVerification = nil
                guard generation == self.itemGeneration, revision == self.intentRevision,
                      self.wantsPlayback, !self.state.isSeeking, self.reconcileSleepTimer(), native.timeControlStatus == .paused else { return }
                self.record("recovery-failed", reason: "transport-did-not-start")
                self.fail("Audio did not start. Tap Play to reload this song.")
            }
        }
        updateSkipAvailability(); publishCurrent(); record("transport-synchronized")
    }

    private func removeItemObservers() { statusObserver?.invalidate(); statusObserver = nil; if let endObserver { NotificationCenter.default.removeObserver(endObserver); self.endObserver = nil } }
    private func updateContext(with id: String) {
        if var snapshot = activeContextTrackIDs, !snapshot.contains(id) {
            let position = state.currentTrackID.flatMap { snapshot.firstIndex(of: $0) }.map { $0 + 1 } ?? snapshot.count
            snapshot.insert(id, at: position); activeContextTrackIDs = snapshot
        }
        refreshContext()
        if !context.trackIDs.contains(id) { context.trackIDs.append(id) }
        context = context.settingCurrent(id); updateSkipAvailability()
    }
    func libraryDidChange() { refreshContext(); publishCurrent(); objectWillChange.send() }
    func beginLibraryDeletion(_ id: String) async throws {
        guard await beginCommand("library-delete") else { throw LibraryError.operationFailed }
        defer { endCommand() }
        deletingTrackIDs.insert(id)
        if state.currentTrackID == id { stop() }
        refreshContext()
    }
    func finishLibraryDeletion(_ id: String) {
        deletingTrackIDs.remove(id)
        queue.removeUnavailableEntries()
        refreshContext(); publishCurrent(); persist()
    }
    private func updateSkipAvailability() {
        let canRecover: Bool
        switch state.status { case .ended, .failed: canRecover = state.currentTrackID != nil; default: canRecover = false }
        state.canSkipNext = queue.hasNext(reason: .manual)
        state.canSkipPrevious = queue.hasPrevious() || state.elapsedTime > 3 || canRecover
        remoteCommands.updateCapabilities(state: state)
    }
    private func restartCurrentTrack(keepPlaying: Bool = true) async throws {
        guard let id = state.currentTrackID else { throw AudioPlaybackError.trackNotFound }
        record("recovery-reload", reason: keepPlaying ? "restart-playing" : "restart-paused")
        // A fresh item also isolates late endpoint notifications from the replay.
        try await selectTrack(id, autoplay: keepPlaying, recordNavigation: false)
        updateSkipAvailability()
    }
    private func publish(track selected: StoredTrack) {
        guard state.currentTrackID == selected.id else { return }
        // A ready callback may carry metadata captured before an editor saved.
        let track = (try? storage?.tracks.find(id: selected.id)) ?? selected
        if artworkCachePath != track.artworkRelativePath {
            artworkTask?.cancel(); artworkCachePath = track.artworkRelativePath; artworkCacheData = nil
            if let path = track.artworkRelativePath, let storage, let url = try? storage.paths.artworkURL(relativePath: path) {
                artworkTask = Task { @MainActor [weak self] in
                    let data = await Task.detached(priority: .userInitiated) { () -> Data? in
                        guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= 20 * 1024 * 1024,
                              let input = try? Data(contentsOf: url, options: .mappedIfSafe) else { return nil }
                        return try? ManagedLibraryFiles.imageData(input, pixels: 1024)
                    }.value
                    guard !Task.isCancelled, let self, self.artworkCachePath == path else { return }
                    self.artworkCacheData = data; self.publishCurrent()
                }
            }
        }
        nowPlaying.update(state: state, track: track, artist: storage?.artistName(for: track.artistID), album: storage?.albumTitle(for: track.albumID), artworkData: artworkCacheData)
        state.currentOutputRoute = session.outputRouteName
    }
    private func publishCurrent() { guard let storage, let id = state.currentTrackID, let track = try? storage.tracks.find(id: id) else { return }; publish(track: track) }
    private func persist() { queue.persistState(currentTrackID: state.currentTrackID, positionMs: Int64(max(0, state.elapsedTime) * 1000), sleepDeadline: sleepTimer.deadline, sleepTimerDuration: sleepTimer.durationSeconds, contextKind: activeContextKind, contextSourceID: activeContextSourceID) }
    func reconcileLifecycle() { sleepTimer.checkDeadline(); updateSkipAvailability(); persist() }
    private func expireSleepTimer() { record("timer-expired"); timerExpired = true; intentRevision += 1; wantsPlayback = false; player.pause(); state.status = state.currentTrackID == nil ? .idle : .paused; state.lastError = nil; publishCurrent(); persist() }
    private func reconcileSleepTimer() -> Bool { guard !timerExpired else { record("command-rejected", reason: "timer-expired"); return false }; guard let deadline = sleepTimer.deadline, deadline <= Date() else { return true }; sleepTimer.cancel(); expireSleepTimer(); return false }
    private func fail(_ message: String) { record("transport-failed", reason: "recoverable-error"); wantsPlayback = false; player.pause(); state.status = .failed(message: message); state.lastError = message; publishCurrent(); persist() }
    private func handleTransitionFailure(_ error: Error) {
        let code: String
        switch error {
        case AudioPlaybackError.missingFile: code = "missing-file"
        case AudioPlaybackError.trackNotFound: code = "track-not-found"
        case AudioPlaybackError.unsupportedAudio: code = "unsupported-audio"
        case AudioPlaybackError.storageUnavailable: code = "storage-unavailable"
        case AudioPlaybackError.playerFailed: code = "transport-or-timeout"
        case is CancellationError: code = "cancelled"
        default: code = "system-error"
        }
        record("transition-error", reason: code)
        queue.cancelCandidate()
        if error is CancellationError || timerExpired { return }
        fail("Playback could not complete. Try Play again or choose another track.")
    }
    var diagnosticSnapshot: [String: String] {
        var fields = queue.navigationDiagnostics
        fields.merge([
            "track": diagnostics.trackAlias(state.currentTrackID), "generation": String(itemGeneration),
            "actualTime": String(player.nativePlayer?.currentTime().seconds ?? .nan),
            "actualDuration": String(item?.duration.seconds ?? .nan),
            "storedTime": String(state.elapsedTime), "storedDuration": String(state.duration),
            "itemStatus": String(describing: item?.status), "transportStatus": String(describing: nativePlayer?.timeControlStatus),
            "status": diagnosticStatus, "wantsPlayback": String(wantsPlayback),
            "completedGeneration": completedGeneration.map(String.init) ?? "none",
            "intentRevision": String(intentRevision), "seekRevision": String(seekRevision),
            "seeking": String(state.isSeeking), "timerExpired": String(timerExpired),
            "gateOperation": commandGate.activeOperation?.uuidString ?? "none",
            "next": String(state.canSkipNext), "previous": String(state.canSkipPrevious)
        ], uniquingKeysWith: { _, new in new })
        return fields
    }
    private var diagnosticStatus: String {
        if case .failed = state.status { return "failed" }
        return String(describing: state.status)
    }
    private func record(_ action: String, reason: String = "none", operationID: UUID? = nil) {
        var fields = diagnosticSnapshot
        fields["source"] = PlaybackCommandSource.value; fields["reason"] = reason
        diagnostics.record(action, operationID: operationID ?? commandGate.activeOperation ?? UUID(), fields: fields)
    }
    private func beginCommand(_ type: String, operationID: UUID = UUID()) async -> Bool {
        let id = operationID
        record("command-request", reason: type, operationID: id)
        guard await commandGate.acquire(operationID: id) else {
            record("command-rejected", reason: "gate-timeout-or-cancelled", operationID: id)
            state.lastError = "Playback is busy. Try again."
            return false
        }
        guard !Task.isCancelled else {
            record("command-rejected", reason: "cancelled")
            commandGate.release()
            return false
        }
        record("command-begin", reason: type)
        return true
    }
    private func endCommand() { record("command-end"); commandGate.release() }
    func handleRouteChange(route: String, reason: AVAudioSession.RouteChangeReason) { state.currentOutputRoute = route; if reason == .oldDeviceUnavailable && (wantsPlayback || wasPlayingBeforeInterruption) { pause() }; publishCurrent() }
    func handleInterruption(_ notification: Notification) {
        guard let value = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: value) else { return }
        if type == .began {
            synchronizeClock()
            wasPlayingBeforeInterruption = wantsPlayback
            userPausedDuringInterruption = false
            intentRevision += 1; wantsPlayback = false; player.pause()
            state.status = .interrupted
        } else {
            let value = notification.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
            let shouldResume = AVAudioSession.InterruptionOptions(rawValue: value).contains(.shouldResume)
            if wasPlayingBeforeInterruption && shouldResume && !userPausedDuringInterruption && reconcileSleepTimer() {
                do { try requireAvailableMigrationAudio(); try session.configure(); wantsPlayback = true; player.play(); synchronizeTransport() }
                catch { handleTransitionFailure(error) }
            } else if state.currentTrackID != nil {
                wantsPlayback = false; state.status = .paused
            }
        }
        updateSkipAvailability(); publishCurrent(); persist()
    }
}
