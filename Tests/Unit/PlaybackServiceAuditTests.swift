import AVFoundation
import XCTest
@testable import OFFLINE

@MainActor private final class FakePlaybackPlayer: PlaybackPlayer {
    var nativePlayer: AVPlayer? { nil }
    var isPlaying = false
    var replacements = 0
    var seeks: [Double] = []
    var duringSeek: (() -> Void)?
    func play() { isPlaying = true }
    func pause() { isPlaying = false }
    func replaceCurrentItem(with item: AVPlayerItem?) { replacements += 1; isPlaying = false }
    func seek(to time: CMTime) async -> Bool { seeks.append(time.seconds); duringSeek?(); await Task.yield(); return true }
}

final class PlaybackServiceAuditTests: XCTestCase {
    @MainActor private func fixture() throws -> (StorageCoordinator, FakePlaybackPlayer, AudioPlayerService, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let storage = try StorageCoordinator(paths: AppStoragePaths(root: root))
        for index in 0..<6 {
            let id = "track-\(index)"
            let url = try storage.paths.musicURL(relativePath: "\(id).wav")
            let format = AVAudioFormat(standardFormatWithSampleRate: 8000, channels: 1)!
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 24000)!
            buffer.frameLength = 24000
            buffer.floatChannelData![0].initialize(repeating: 0, count: 24000)
            let file = try AVAudioFile(forWriting: url, settings: format.settings)
            try file.write(from: buffer)
            let now = Date()
            try storage.tracks.save(StoredTrack(id: id, title: id, artistID: nil, albumID: nil, durationMs: 3000, fileRelativePath: url.lastPathComponent, fileExtension: "wav", fileSizeBytes: 96000, contentSHA256: id, artworkRelativePath: nil, availability: .available, dateAdded: now.addingTimeInterval(Double(index)), dateModified: now, originalFilename: url.lastPathComponent, metadataSource: "synthetic-test"))
        }
        let player = FakePlaybackPlayer()
        let service = AudioPlayerService(storage: storage, player: player, registerRemoteCommands: false, makeShuffle: { $0 })
        return (storage, player, service, root)
    }

    @MainActor func testEndpointRecoveryForEveryRepeatModePlayingAndPaused() async throws {
        for mode in [RepeatMode.off, .all, .one] {
            for paused in [false, true] {
                let (_, player, service, root) = try fixture()
                defer { try? FileManager.default.removeItem(at: root) }
                try await service.play(trackID: "track-5") // first indexed track, with an eligible manual successor in Repeat Off
                while service.queue.repeatMode != mode { service.queue.cycleRepeat() }
                if paused { service.pause() }
                let generation = service.activeItemGeneration
                await service.seek(to: 3)
                if !paused && mode == .all { XCTAssertNotEqual(service.state.currentTrackID, "track-5") }
                else { XCTAssertEqual(service.state.elapsedTime, 0) }
                if paused || mode == .off { XCTAssertFalse(player.isPlaying) }
                await service.completedItem(generation: generation)
                try await service.play()
                XCTAssertTrue(player.isPlaying)
                XCTAssertNotEqual(service.state.status, .ended)
                await service.next(); XCTAssertTrue(player.isPlaying)
                await service.previous(); XCTAssertNotEqual(service.state.status, .ended)
            }
        }
    }

    @MainActor func testStaleCompletionCannotAdvanceTwiceOrAfterManualNext() async throws {
        let (_, player, service, root) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        try await service.play(trackID: "track-0")
        let generation = service.activeItemGeneration
        await service.next()
        let selected = service.state.currentTrackID
        let replacements = player.replacements
        await service.completedItem(generation: generation)
        await service.completedItem(generation: generation)
        XCTAssertEqual(service.state.currentTrackID, selected)
        XCTAssertEqual(player.replacements, replacements)
    }

    @MainActor func testTimerExpiryDuringSeekPreventsAutoResumeAndCompletion() async throws {
        let (_, player, service, root) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        try await service.play(trackID: "track-0")
        service.queue.cycleRepeat() // All -> One
        service.sleepTimer.start(minutes: 1)
        let deadline = try XCTUnwrap(service.sleepTimer.deadline)
        player.duringSeek = { [weak service] in service?.sleepTimer.checkDeadline(now: deadline.addingTimeInterval(1)) }
        await service.seek(to: 3)
        player.duringSeek = nil
        await service.completedItem(generation: service.activeItemGeneration)
        await service.next()
        XCTAssertFalse(player.isPlaying)
        XCTAssertEqual(service.state.status, .paused)
    }

    @MainActor func testQueueCandidateIsNotConsumedUntilPlaybackCommits() async throws {
        let (storage, _, service, root) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        try await service.play(trackID: "track-0")
        service.queue.playNext(trackID: "track-4")
        service.queue.addToQueue(trackID: "track-4")
        XCTAssertEqual(service.queue.nextID(), "track-4")
        XCTAssertEqual(service.queue.entries.count, 2)
        await service.next()
        XCTAssertEqual(service.state.currentTrackID, "track-4")
        XCTAssertEqual(service.queue.entries.count, 1)
        XCTAssertEqual(try storage.playback.queue().count, 1)
        XCTAssertEqual(try storage.playback.state()?.currentTrackID, "track-4")
    }

    @MainActor func testSixSongStressWithSeekQueueTimerAndRestoration() async throws {
        let (storage, player, service, root) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        try await service.play(trackID: "track-0")
        service.sleepTimer.start(minutes: 5)
        let deadline = service.sleepTimer.deadline
        // Fixed deterministic operation sequence: no copyrighted audio or network.
        for step in 0..<240 {
            switch step % 12 {
            case 0: await service.next()
            case 1: await service.previous()
            case 2: await service.seek(to: 1)
            case 3: service.pause()
            case 4: try await service.play()
            case 5: service.queue.toggleShuffle()
            case 6: service.queue.cycleRepeat()
            case 7: service.queue.playNext(trackID: "track-\(step % 6)")
            case 8: service.queue.clear()
            case 9: await service.completedItem(generation: service.activeItemGeneration)
            case 10: await service.seek(to: 3)
            default:
                let restored = PlaybackQueueManager(storage: storage)
                XCTAssertEqual(restored.shuffleEnabled, service.queue.shuffleEnabled)
                XCTAssertEqual(restored.repeatMode, service.queue.repeatMode)
            }
            XCTAssertTrue(service.state.elapsedTime.isFinite)
            XCTAssertFalse(service.state.isSeeking)
            XCTAssertEqual(service.sleepTimer.deadline, deadline)
            XCTAssertNotNil(try storage.tracks.find(id: service.state.currentTrackID ?? ""))
            if service.state.status == .playing { XCTAssertTrue(player.isPlaying) }
        }
    }

    @MainActor func testNativeAVPlayerSeeksAndRecoversPausedEndpoint() async throws {
        let (storage, _, _, root) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let transport = NativePlaybackPlayer()
        let service = AudioPlayerService(storage: storage, player: transport, registerRemoteCommands: false)
        try await service.play(trackID: "track-0")
        for _ in 0..<100 {
            if transport.player.currentItem?.status == .readyToPlay { break }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTAssertEqual(transport.player.currentItem?.status, .readyToPlay)
        service.pause()
        for fraction in [0.0, 0.01, 0.25, 0.5, 0.75, 0.99, 0.999, 1.0] { await service.seek(to: 3 * fraction) }
        XCTAssertEqual(service.state.elapsedTime, 0)
        try await service.play()
        XCTAssertNotEqual(service.state.status, .ended)
        service.stop()
    }

    @MainActor func testRemoteRegistrationAndDispatchUseSameService() async throws {
        let (_, player, service, root) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let remote = RemoteCommandCoordinator()
        remote.register(service: service); remote.register(service: service)
        XCTAssertEqual(remote.registrationCount, 6)
        try await service.play(trackID: "track-0")
        service.queue.toggleShuffle()
        let done = expectation(description: "Accepted remote next completes")
        service.enqueueRemote(command: "test-next") { await service.next(); done.fulfill() }
        await fulfillment(of: [done], timeout: 5)
        XCTAssertTrue(service.state.canSkipNext)
        XCTAssertTrue(player.isPlaying)
        XCTAssertNotEqual(service.state.currentTrackID, "track-0")
        let rapid = expectation(description: "Four ordered remote skips")
        rapid.expectedFulfillmentCount = 4
        var selected: [String] = []
        for _ in 0..<4 {
            service.enqueueRemote(command: "rapid-test-next") {
                await service.next()
                selected.append(service.state.currentTrackID ?? "")
                rapid.fulfill()
            }
        }
        await fulfillment(of: [rapid], timeout: 10)
        XCTAssertEqual(selected, ["track-4", "track-3", "track-2", "track-1"])
        remote.unregister(); XCTAssertEqual(remote.registrationCount, 0)
    }

    @MainActor func testPauseDuringSeekCannotBeOverwrittenAndNonfiniteSeekIsIgnored() async throws {
        let (_, player, service, root) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        try await service.play(trackID: "track-0")
        player.duringSeek = { [weak service] in service?.pause() }
        await service.seek(to: 1)
        player.duringSeek = nil
        XCTAssertFalse(player.isPlaying)
        XCTAssertEqual(service.state.status, .paused)
        let count = player.seeks.count
        await service.seek(to: .nan); await service.seek(to: .infinity)
        XCTAssertEqual(player.seeks.count, count)
    }

    @MainActor func testSeekBackwardAfterRepeatOffCompletionResumesSameItem() async throws {
        let (_, player, service, root) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        try await service.play(trackID: "track-0") // final indexed track in date-descending context
        service.queue.cycleRepeat(); service.queue.cycleRepeat() // All -> One -> Off
        await service.completedItem(generation: service.activeItemGeneration)
        XCTAssertEqual(service.state.status, .ended)
        await service.seek(to: 1)
        XCTAssertEqual(service.state.status, .paused)
        try await service.play()
        XCTAssertEqual(service.state.currentTrackID, "track-0")
        XCTAssertTrue(player.isPlaying)
    }

    @MainActor func testInterruptionCannotResumeAfterTimerExpiry() async throws {
        let (_, player, service, root) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        try await service.play(trackID: "track-0")
        service.sleepTimer.start(minutes: 1)
        service.handleInterruption(Notification(name: AVAudioSession.interruptionNotification, userInfo: [AVAudioSessionInterruptionTypeKey: AVAudioSession.InterruptionType.began.rawValue]))
        XCTAssertEqual(service.state.status, .interrupted)
        service.sleepTimer.checkDeadline(now: try XCTUnwrap(service.sleepTimer.deadline).addingTimeInterval(1))
        service.handleInterruption(Notification(name: AVAudioSession.interruptionNotification, userInfo: [AVAudioSessionInterruptionTypeKey: AVAudioSession.InterruptionType.ended.rawValue, AVAudioSessionInterruptionOptionKey: AVAudioSession.InterruptionOptions.shouldResume.rawValue]))
        XCTAssertFalse(player.isPlaying)
        XCTAssertEqual(service.state.status, .paused)
    }
}
