import Foundation

enum MatchingCandidateArtwork {
    static func safe(_ url: URL?) -> URL? {
        guard let url = YouTubeImageURL.valid(url), url.query == nil, url.fragment == nil,
              url.user == nil, url.password == nil, url.port == nil || url.port == 443 else { return nil }
        return url
    }
    static func thumbnail(_ candidate: PlaylistMigrationCandidate) -> URL? {
        guard candidate.provider == "youtube", let id = candidate.providerTrackID, YouTubeURLValidator.isValidID(id) else { return nil }
        if let raw = candidate.evidence["thumbnailURL"], let url = safe(URL(string: raw)) { return url }
        return URL(string: "https://i.ytimg.com/vi/\(id)/hqdefault.jpg")
    }
    static func watchURL(_ candidate: PlaylistMigrationCandidate) -> URL? {
        guard candidate.provider == "youtube", let id = candidate.providerTrackID, YouTubeURLValidator.isValidID(id) else { return nil }
        return URL(string: "https://www.youtube.com/watch?v=\(id)")
    }
}
