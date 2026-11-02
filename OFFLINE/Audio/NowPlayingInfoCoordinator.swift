import MediaPlayer
import UIKit

final class NowPlayingInfoCoordinator {
    private let center = MPNowPlayingInfoCenter.default()

    func update(state: AudioPlaybackState, track: StoredTrack?, artist: String?, album: String?, artworkData: Data?) {
        guard let track else { center.nowPlayingInfo = nil; return }
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: track.title,
            MPMediaItemPropertyArtist: artist ?? "Muzik Belesh",
            MPMediaItemPropertyAlbumTitle: album ?? "Local Music",
            MPNowPlayingInfoPropertyElapsedPlaybackTime: state.elapsedTime,
            MPMediaItemPropertyPlaybackDuration: state.duration,
            MPNowPlayingInfoPropertyPlaybackRate: state.isPlaying ? 1.0 : 0.0
        ]
        if let artworkData, let image = UIImage(data: artworkData) {
            info[MPMediaItemPropertyArtwork] = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
        }
        center.nowPlayingInfo = info
    }

    func clear() { center.nowPlayingInfo = nil }
}
