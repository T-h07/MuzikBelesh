import AVFoundation

/// Injectable transport; navigation and recovery stay in AudioPlayerService.
@MainActor protocol PlaybackPlayer: AnyObject {
    var nativePlayer: AVPlayer? { get }
    var isPlaying: Bool { get }
    func play()
    func pause()
    func replaceCurrentItem(with item: AVPlayerItem?)
    func seek(to time: CMTime) async -> Bool
    func resetAfterMediaServicesFailure()
}

extension PlaybackPlayer {
    func resetAfterMediaServicesFailure() { replaceCurrentItem(with: nil) }
}

@MainActor final class NativePlaybackPlayer: PlaybackPlayer {
    private(set) var player = AVPlayer()
    func resetAfterMediaServicesFailure() { player = AVPlayer() }
    var nativePlayer: AVPlayer? { player }
    var isPlaying: Bool { player.timeControlStatus == .playing }
    func play() { player.play() }
    func pause() { player.pause() }
    func replaceCurrentItem(with item: AVPlayerItem?) { player.replaceCurrentItem(with: item) }
    func seek(to time: CMTime) async -> Bool {
        let seekPlayer = player
        return await withCheckedContinuation { continuation in
            let result = PlaybackSeekResult(continuation)
            let timeout = Task { @MainActor in
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                guard !Task.isCancelled else { return }
                seekPlayer.currentItem?.cancelPendingSeeks()
                result.finish(false)
            }
            seekPlayer.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero) { finished in
                Task { @MainActor in timeout.cancel(); result.finish(finished) }
            }
        }
    }
}

@MainActor private final class PlaybackSeekResult {
    private var continuation: CheckedContinuation<Bool, Never>?
    init(_ continuation: CheckedContinuation<Bool, Never>) { self.continuation = continuation }
    func finish(_ value: Bool) { let pending = continuation; continuation = nil; pending?.resume(returning: value) }
}

/// Asset inspection has a deadline too, so a broken asset cannot retain the gate.
@MainActor final class PlaybackAssetInspection {
    private var continuation: CheckedContinuation<CMTime, Error>?
    static func duration(of asset: AVURLAsset) async throws -> CMTime {
        let inspection = PlaybackAssetInspection()
        return try await withCheckedThrowingContinuation { continuation in
            inspection.continuation = continuation
            let timeout = Task { @MainActor in
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                guard !Task.isCancelled else { return }
                asset.cancelLoading()
                inspection.finish(.failure(AudioPlaybackError.playerFailed("Audio loading timed out. Try Play again.")))
            }
            Task { @MainActor in
                do {
                    let tracks = try await asset.loadTracks(withMediaType: .audio)
                    guard !tracks.isEmpty else { throw AudioPlaybackError.unsupportedAudio }
                    let duration = try await asset.load(.duration)
                    timeout.cancel(); inspection.finish(.success(duration))
                } catch { timeout.cancel(); inspection.finish(.failure(error)) }
            }
        }
    }
    private func finish(_ result: Result<CMTime, Error>) {
        let pending = continuation; continuation = nil; pending?.resume(with: result)
    }
}

/// FIFO suspension, without spinning or creating a retained chain of Tasks.
@MainActor final class PlaybackCommandGate {
    private(set) var activeOperation: UUID?
    private var waiters: [(UUID, CheckedContinuation<Bool, Never>)] = []
    func acquire(operationID: UUID, timeoutNanoseconds: UInt64 = 10_000_000_000) async -> Bool {
        if Task.isCancelled { return false }
        if activeOperation == nil { activeOperation = operationID; return true }
        return await withCheckedContinuation { continuation in
            waiters.append((operationID, continuation))
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: timeoutNanoseconds)
                guard let self, let index = self.waiters.firstIndex(where: { $0.0 == operationID }) else { return }
                self.waiters.remove(at: index).1.resume(returning: false)
            }
        }
    }
    func release() {
        if waiters.isEmpty { activeOperation = nil }
        else { let (id, continuation) = waiters.removeFirst(); activeOperation = id; continuation.resume(returning: true) }
    }
}
