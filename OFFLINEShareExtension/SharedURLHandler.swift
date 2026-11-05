import Foundation
struct SharedURLHandler {
    static func youtubeURL(from value: URL) -> URL? {
        guard let id = YouTubeURLValidator.videoID(from: value.absoluteString) else { return nil }
        return URL(string: "https://www.youtube.com/watch?v=\(id)")
    }
}
