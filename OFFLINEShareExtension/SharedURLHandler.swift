import Foundation
struct SharedURLHandler {
    static func youtubeURL(from value: URL) -> URL? {
        guard let host = value.host?.lowercased(), host == "youtube.com" || host.hasSuffix(".youtube.com") || host == "youtu.be", value.scheme?.lowercased() == "https" else { return nil }
        return value
    }
}

