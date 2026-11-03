import AVFoundation
import XCTest
@testable import OFFLINE

@MainActor private final class FakePlaybackPlayer: PlaybackPlayer {
    var nativePlayer: AVPlayer? { nil }
    var isPlaying = false
    var startsImmediately = true
    var playCalls = 0
    var replacements = 0
    var seeks: [Double] = []
    var duringSeek: (() -> Void)?
    func play() { playCalls += 1; isPlaying = startsImmediately }
    func pause() { isPlaying = false }
    func replaceCurrentItem(with item: AVPlayerItem?) { replacements += 1; isPlaying = false }
    func seek(to time: CMTime) async -> Bool { seeks.append(time.seconds); duringSeek?(); await Task.yield(); return true }
}

final class PlaybackServiceAuditTests: XCTestCase {
    @MainActor func testReportedEndedPreviousUsesHistoryInsteadOfElapsedRestart() async throws {
        for shuffle in [false, true] {
            let (_, player, service, root) = try fixture(duration: 6)
            defer { try? FileManager.default.removeItem(at: root) }
            try await service.play(trackID: "track-1")
            if shuffle { service.queue.toggleShuffle() }
            try await service.play(trackID: "track-0")
            service.queue.cycleRepeat(); service.queue.cycleRepeat()
            if shuffle { service.queue.toggleShuffle() } // exhaust the indexed context deterministically
            await service.seek(to: 4)
            await service.completedItem(generation: service.activeItemGeneration)
            XCTAssertEqual(service.state.status, .ended)
            await service.previous()
            XCTAssertEqual(service.state.currentTrackID, "track-1")
            XCTAssertTrue(player.isPlaying)
        }
    }

    @MainActor func testReportedManualNextRecoversExhaustedShuffleOff() async throws {
        let (_, player, service, root) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        try await service.play(trackID: "track-0")
        service.queue.toggleShuffle()
        service.queue.cycleRepeat(); service.queue.cycleRepeat()
        for _ in 0..<6 { await service.completedItem(generation: service.activeItemGeneration) }
        XCTAssertEqual(service.state.status, .ended)
        XCTAssertNotEqual(service.state.currentTrackID, "track-0", "Cycle ends away from final indexed song")
        XCTAssertTrue(service.state.canSkipNext)
        let endedID = service.state.currentTrackID
        await service.next()
        XCTAssertNotEqual(service.state.currentTrackID, endedID)
        XCTAssertTrue(player.isPlaying)
    }

    @MainActor func testReportedCurrentItemNotificationCannotBeRejectedByTimeComparison() async throws {
        let (storage, _, _, root) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let transport = NativePlaybackPlayer()
        let service = AudioPlayerService(storage: storage, player: transport, registerRemoteCommands: false)
        try await service.play(trackID: "track-1")
        service.pause()
        await service.seek(to: 2.5)
        try await service.play()
        let generation = service.activeItemGeneration
        // Inject the authoritative notification with a lagging transport clock, as can
        // occur across a seek/decoder boundary. This tests notification acceptance,
        // independently of the real natural-completion integration tests below.
        NotificationCenter.default.post(name: .AVPlayerItemDidPlayToEndTime, object: transport.player.currentItem)
        for _ in 0..<100 {
            if service.activeItemGeneration != generation { break }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        XCTAssertNotEqual(service.activeItemGeneration, generation)
        service.stop()
    }


    @MainActor func testCompletionAfterInteriorSeekAdvancesEveryFractionExactlyOnce() async throws {
        for fraction in [0.0, 0.25, 0.5, 0.9] {
            let (storage, player, service, root) = try fixture()
            defer { try? FileManager.default.removeItem(at: root) }
            try await service.play(trackID: "track-1")
            await service.seek(to: 3 * fraction)
            let generation = service.activeItemGeneration
            let replacements = player.replacements
            await service.completedItem(generation: generation)
            await service.completedItem(generation: generation)
            XCTAssertEqual(service.state.currentTrackID, "track-0")
            XCTAssertEqual(player.replacements, replacements + 1)
            XCTAssertTrue(player.isPlaying)
            XCTAssertEqual(try storage.playback.state()?.currentTrackID, "track-0")
        }
    }

    @MainActor func testCompletionWhileSeekOwnsGateIsNotLost() async throws {
        let (_, player, service, root) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        try await service.play(trackID: "track-1")
        let completed = expectation(description: "Completion queued behind seek")
        let generation = service.activeItemGeneration
        player.duringSeek = {
            Task { @MainActor in await service.completedItem(generation: generation); completed.fulfill() }
        }
        await service.seek(to: 1.5)
        player.duringSeek = nil
        await fulfillment(of: [completed], timeout: 5)
        XCTAssertEqual(service.state.currentTrackID, "track-0")
        XCTAssertTrue(player.isPlaying)
        XCTAssertTrue(service.diagnostics.events.contains { $0.action == "completion-accepted" })
    }

    @MainActor func testPlayAndPreviousRecoverEndedWithoutHistoryForAllModes() async throws {
        for mode in [RepeatMode.off, .all, .one] {
            for command in ["play", "previous"] {
                let (_, player, service, root) = try fixture()
                defer { try? FileManager.default.removeItem(at: root) }
                try await service.play(trackID: "track-0")
                service.queue.cycleRepeat(); service.queue.cycleRepeat()
                await service.completedItem(generation: service.activeItemGeneration)
                XCTAssertEqual(service.state.status, .ended)
                while service.queue.repeatMode != mode { service.queue.cycleRepeat() }
                let replacements = player.replacements
                if command == "play" { try await service.play() } else { await service.previous() }
                XCTAssertTrue(player.isPlaying)
                XCTAssertGreaterThan(player.replacements, replacements)
                XCTAssertEqual(service.state.elapsedTime, 0)
                XCTAssertEqual(service.state.status, .playing)
                if mode != .all || command == "previous" { XCTAssertEqual(service.state.currentTrackID, "track-0") }
            }
        }
    }

    @MainActor func testEndedShufflePreviousFollowsHistoryAndNextReusesForwardHistory() async throws {
        let (storage, player, service, root) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        try await service.play(trackID: "track-0")
        service.queue.toggleShuffle()
        service.queue.cycleRepeat(); service.queue.cycleRepeat()
        var played = ["track-0"]
        for _ in 0..<5 { await service.completedItem(generation: service.activeItemGeneration); played.append(service.state.currentTrackID!) }
        await service.completedItem(generation: service.activeItemGeneration)
        XCTAssertEqual(service.state.status, .ended)
        await service.previous()
        XCTAssertEqual(service.state.currentTrackID, played[4])
        XCTAssertTrue(player.isPlaying)
        for _ in 0..<12 {
            await service.next(); XCTAssertEqual(service.state.currentTrackID, played[5])
            await service.previous(); XCTAssertEqual(service.state.currentTrackID, played[4])
        }
        XCTAssertTrue(player.isPlaying)
        let saved = try XCTUnwrap(storage.playback.state())
        XCTAssertEqual(saved.navigationHistoryPosition, 4)
        XCTAssertEqual(saved.shufflePosition, 5)
        XCTAssertEqual(try storage.tracks.all().count, 6)
    }

    @MainActor func testRemoteRecoveryCommandsAfterEnded() async throws {
        for command in ["play", "next", "previous"] {
            let (_, player, service, root) = try fixture()
            defer { try? FileManager.default.removeItem(at: root) }
            try await service.play(trackID: "track-0")
            service.queue.toggleShuffle()
            service.queue.cycleRepeat(); service.queue.cycleRepeat()
            for _ in 0..<6 { await service.completedItem(generation: service.activeItemGeneration) }
            let done = expectation(description: "Remote \(command) recovers")
            service.enqueueRemote(command: command) {
                switch command {
                case "play": await service.playFromRemote()
                case "next": await service.next()
                default: await service.previous()
                }
                done.fulfill()
            }
            await fulfillment(of: [done], timeout: 5)
            XCTAssertTrue(player.isPlaying)
            XCTAssertEqual(service.state.status, .playing)
            XCTAssertTrue(service.diagnostics.events.contains { $0.fields["source"] == "remote" })
        }
    }

    @MainActor func testRestoringTerminalSnapshotRecoversWithoutQueueDataLoss() async throws {
        let (storage, _, service, root) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        try await service.play(trackID: "track-0")
        service.queue.cycleRepeat(); service.queue.cycleRepeat()
        await service.completedItem(generation: service.activeItemGeneration)
        service.queue.addToQueue(trackID: "track-3")
        let player = FakePlaybackPlayer()
        let restored = AudioPlayerService(storage: storage, player: player, registerRemoteCommands: false)
        for _ in 0..<100 {
            if player.replacements > 0 { break }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        try await restored.play()
        XCTAssertTrue(player.isPlaying)
        XCTAssertEqual(restored.state.currentTrackID, "track-0")
        XCTAssertEqual(restored.state.elapsedTime, 0)
        XCTAssertEqual(try storage.playback.queue().map(\.trackID), ["track-3"])
        XCTAssertEqual(try storage.tracks.all().count, 6)
    }

    @MainActor func testNativeNaturalCompletionAfterAllSeekFractions() async throws {
        for fraction in [0.0, 0.25, 0.5, 0.9] {
            let (storage, _, _, root) = try fixture()
            defer { try? FileManager.default.removeItem(at: root) }
            let player = NativePlaybackPlayer()
            let service = AudioPlayerService(storage: storage, player: player, registerRemoteCommands: false)
            try await service.play(trackID: "track-1")
            await service.seek(to: 3 * fraction)
            let generation = service.activeItemGeneration
            for _ in 0..<160 {
                if service.activeItemGeneration != generation { break }
                try await Task.sleep(nanoseconds: 50_000_000)
            }
            XCTAssertEqual(service.state.currentTrackID, "track-0", "Natural completion after \(fraction)")
            XCTAssertTrue(service.diagnostics.events.contains { $0.action == "completion-arrived" })
            XCTAssertTrue(service.diagnostics.events.contains { $0.action == "completion-accepted" })
            XCTAssertTrue(player.player.rate > 0 || player.player.timeControlStatus == .waitingToPlayAtSpecifiedRate)
            service.stop()
        }
    }

    @MainActor func testGateTimeoutRemovesWaiterAndLaterCommandsStillAcquire() async {
        let gate = PlaybackCommandGate()
        let first = await gate.acquire(operationID: UUID())
        XCTAssertTrue(first)
        let blocked = await gate.acquire(operationID: UUID(), timeoutNanoseconds: 20_000_000)
        XCTAssertFalse(blocked)
        gate.release()
        let recovered = await gate.acquire(operationID: UUID())
        XCTAssertTrue(recovered)
        gate.release()
        XCTAssertNil(gate.activeOperation)
    }

    @MainActor func testDiagnosticsAreBoundedAndDoNotExportPrivateIdentifiers() {
        let diagnostics = PlaybackDiagnostics(capacity: 3)
        let alias = diagnostics.trackAlias("/private/user/secret-track")
        for index in 0..<8 { diagnostics.record("event", operationID: UUID(), fields: ["track": alias, "index": String(index)]) }
        XCTAssertEqual(diagnostics.events.count, 3)
        let trace = diagnostics.export(currentState: ["track": alias])
        XCTAssertFalse(trace.contains("/private"))
        XCTAssertTrue(trace.contains("operationID"))
        diagnostics.clear()
        XCTAssertTrue(diagnostics.events.isEmpty)
    }


    @MainActor func testEveryRecoveryCommandAcrossTransportStates() async throws {
        for status in ["ended", "paused", "loading", "failed"] {
            for command in ["play", "next", "previous", "seek", "select", "remote-play", "remote-next", "remote-previous"] {
                let (_, player, service, root) = try fixture()
                defer { try? FileManager.default.removeItem(at: root) }
                try await service.play(trackID: "track-0")
                service.queue.toggleShuffle()
                await service.next()
                service.queue.cycleRepeat(); service.queue.cycleRepeat()
                switch status {
                case "ended": for _ in 0..<6 { await service.completedItem(generation: service.activeItemGeneration) }
                case "paused": service.pause()
                case "loading": player.startsImmediately = false; try await service.play(); XCTAssertEqual(service.state.status, .loading)
                default: do { try await service.play(trackID: "missing") } catch { }
                }
                player.startsImmediately = true
                let calls = player.playCalls
                switch command {
                case "play": try await service.play()
                case "next": await service.next()
                case "previous": await service.previous()
                case "seek": await service.seek(to: 1); try await service.play()
                case "select": try await service.play(trackID: "track-4")
                default:
                    let done = expectation(description: "Remote recovery completes")
                    service.enqueueRemote(command: command) {
                        if command == "remote-play" { await service.playFromRemote() }
                        else if command == "remote-next" { await service.next() }
                        else { await service.previous() }
                        done.fulfill()
                    }
                    await fulfillment(of: [done], timeout: 5)
                }
                XCTAssertTrue(player.isPlaying, "\(status) / \(command)")
                XCTAssertEqual(service.state.status, .playing, "\(status) / \(command)")
                XCTAssertGreaterThan(player.playCalls, calls)
                XCTAssertFalse(service.state.isSeeking)
                XCTAssertEqual(service.diagnosticSnapshot["gateOperation"], "none")
            }
        }
    }

    @MainActor func testEndpointNotificationDuringSeekNeverAdvancesTwice() async throws {
        for mode in [RepeatMode.off, .all, .one] {
            let (_, player, service, root) = try fixture()
            defer { try? FileManager.default.removeItem(at: root) }
            try await service.play(trackID: "track-1")
            while service.queue.repeatMode != mode { service.queue.cycleRepeat() }
            let generation = service.activeItemGeneration
            let done = expectation(description: "Late endpoint callback returns")
            player.duringSeek = { Task { @MainActor in await service.completedItem(generation: generation); done.fulfill() } }
            let replacements = player.replacements
            await service.seek(to: 3)
            player.duringSeek = nil
            if mode == .all { done.fulfill() }
            await fulfillment(of: [done], timeout: 5)
            await service.completedItem(generation: generation)
            XCTAssertEqual(player.replacements, replacements + 1)
            XCTAssertEqual(service.state.currentTrackID, mode == .all ? "track-0" : "track-1")
            XCTAssertEqual(player.isPlaying, mode != .off)
        }
    }


    @MainActor func testNewSeekInvalidatesAnOlderQueuedCompletion() async throws {
        let (_, player, service, root) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        try await service.play(trackID: "track-1")
        let oldSeek = Int(service.diagnosticSnapshot["seekRevision"]!)!
        let generation = service.activeItemGeneration
        await service.seek(to: 1)
        await service.completedItem(generation: generation, receivedSeekRevision: oldSeek)
        XCTAssertEqual(service.state.currentTrackID, "track-1")
        XCTAssertTrue(player.isPlaying)
        await service.completedItem(generation: generation)
        XCTAssertEqual(service.state.currentTrackID, "track-0")
    }

    @MainActor func testNativeEndedReplayReloadsAndActuallyStarts() async throws {
        let (storage, _, _, root) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let player = NativePlaybackPlayer()
        let service = AudioPlayerService(storage: storage, player: player, registerRemoteCommands: false)
        try await service.play(trackID: "track-0")
        service.queue.cycleRepeat(); service.queue.cycleRepeat()
        await service.seek(to: 2.7)
        for _ in 0..<160 {
            if service.state.status == .ended { break }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTAssertEqual(service.state.status, .ended)
        let oldItem = player.player.currentItem
        try await service.play()
        XCTAssertFalse(player.player.currentItem === oldItem)
        let generation = service.activeItemGeneration
        NotificationCenter.default.post(name: .AVPlayerItemDidPlayToEndTime, object: oldItem)
        for _ in 0..<100 {
            if player.isPlaying { break }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertTrue(player.isPlaying)
        XCTAssertEqual(service.activeItemGeneration, generation)
        XCTAssertLessThan(player.player.currentTime().seconds, 2.7)
        service.stop()
    }

    @MainActor private func fixture(duration: Double = 3) throws -> (StorageCoordinator, FakePlaybackPlayer, AudioPlayerService, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let storage = try StorageCoordinator(paths: AppStoragePaths(root: root))
        for index in 0..<6 {
            let id = "track-\(index)"
            let url = try storage.paths.musicURL(relativePath: "\(id).wav")
            let format = AVAudioFormat(standardFormatWithSampleRate: 8000, channels: 1)!
            let frames = AVAudioFrameCount(8000 * duration)
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
            buffer.frameLength = frames
            buffer.floatChannelData![0].initialize(repeating: 0, count: Int(frames))
            let file = try AVAudioFile(forWriting: url, settings: format.settings)
            try file.write(from: buffer)
            let now = Date()
            try storage.tracks.save(StoredTrack(id: id, title: id, artistID: nil, albumID: nil, durationMs: Int64(duration * 1000), fileRelativePath: url.lastPathComponent, fileExtension: "wav", fileSizeBytes: 96000, contentSHA256: id, artworkRelativePath: nil, availability: .available, dateAdded: now.addingTimeInterval(Double(index)), dateModified: now, originalFilename: url.lastPathComponent, metadataSource: "synthetic-test"))
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
                let restored = PlaybackQueueManager(storage: storage, makeShuffle: { $0 })
                XCTAssertEqual(restored.shuffleEnabled, service.queue.shuffleEnabled)
                XCTAssertEqual(restored.repeatMode, service.queue.repeatMode)
                restored.setContext(service.queue.contextTrackIDs, current: service.state.currentTrackID)
                XCTAssertEqual(restored.nextID(), service.queue.nextID(), "Restoration must preserve the future successor at operation \(step)")
                restored.cancelCandidate(); service.queue.cancelCandidate()
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
