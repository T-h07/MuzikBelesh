#if DEBUG
import Foundation

// Constructed only by AppBootstrap's explicitly isolated UI-test launch.
struct YouTubeUITestFixtures: YouTubeSearchProvider, YouTubeMetadataProvider, YouTubeAudioResolver {
    static let video = YouTubeVideo(id: "9bZkp7q19f0", title: "YouTube Fixture Song", channel: "Fixture Channel", duration: 253, availability: .available)
    func search(query: String, continuationToken: String?) async throws -> YouTubeSearchPage {
        try Task.checkCancellation()
        if query == "long page", continuationToken == nil {
            let videos = (1...16).map { index in
                YouTubeVideo(id: String(format: "fixture%04d", index), title: "Fixture result \(index)", channel: "Fixture Channel", duration: 210, availability: .available)
            }
            return YouTubeSearchPage(videos: videos, continuationToken: "fixture-next")
        }
        let video = continuationToken == nil ? Self.video : YouTubeVideo(id: "dQw4w9WgXcQ", title: "Second Fixture Song", channel: "Fixture Channel", duration: 210, availability: .available)
        return YouTubeSearchPage(videos: [video], continuationToken: continuationToken == nil ? "fixture-next" : nil)
    }
    func metadata(videoID: String) async throws -> YouTubeVideo {
        guard YouTubeURLValidator.isValidID(videoID) else { throw YouTubeError.invalidVideoID }
        return YouTubeVideo(id: videoID, title: "Resolved Fixture Song", channel: "Fixture Channel", duration: 253, availability: .available)
    }
    func resolve(video: YouTubeVideo, quality: AudioQuality) async throws -> ResolvedAudioStream {
        try Task.checkCancellation()
        let option = AudioStreamOption(id: 140, container: "m4a", codec: "mp4a.40.2", bitrate: 128_000, isAudioOnly: true, isNativelyPlayable: true)
        guard let url = URL(string: "https://fixture.invalid/never-transferred") else { throw YouTubeError.extractionFailed }
        return ResolvedAudioStream(video: video, options: [option], selected: option, url: url, resolvedAt: Date(), expiresAt: Date().addingTimeInterval(600))
    }
}
#endif
