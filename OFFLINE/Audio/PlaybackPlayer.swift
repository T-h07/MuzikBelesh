import AVFoundation

/// Injectable transport; navigation and recovery stay in AudioPlayerService.
@MainActor protocol PlaybackPlayer: AnyObject {
    var nativePlayer: AVPlayer? { get }
    var isPlaying: Bool { get }
    func play()
    func pause()
    func replaceCurrentItem(with item: AVPlayerItem?)
    func seek(to time: CMTime) async -> Bool
}

@MainActor final class NativePlaybackPlayer: PlaybackPlayer {
    let player = AVPlayer()
    var nativePlayer: AVPlayer? { player }
    var isPlaying: Bool { player.timeControlStatus == .playing }
    func play() { player.play() }
    func pause() { player.pause() }
    func replaceCurrentItem(with item: AVPlayerItem?) { player.replaceCurrentItem(with: item) }
    func seek(to time: CMTime) async -> Bool { await player.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero) }
}

/// FIFO suspension, without spinning or creating a retained chain of Tasks.
@MainActor final class PlaybackCommandGate {
    private var occupied = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func acquire() async {
        if !occupied { occupied = true; return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func release() {
        if waiters.isEmpty { occupied = false }
        else { waiters.removeFirst().resume() }
    }
}
