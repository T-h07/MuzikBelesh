import Foundation

struct YouTubeManualLookupResult: Sendable, Equatable {
    let video: YouTubeVideo
    /// False when only the validated ID is known. The user may still confirm after
    /// inspecting the video in the browser; nothing is marked playable either way.
    let metadataVerified: Bool
}

/// Credential-free metadata for a pasted link: the existing watch-page reader,
/// then YouTube's public oEmbed endpoint, then the validated ID alone. Requests use
/// the shared restricted transport; verification or consent pages are never bypassed.
struct YouTubeManualLookup: Sendable {
    let metadata: any YouTubeMetadataProvider
    let transport: any YouTubeTransport

    static func fallbackThumbnail(_ id: String) -> URL? { URL(string: "https://i.ytimg.com/vi/\(id)/hqdefault.jpg") }

    func lookup(_ input: String) async throws -> YouTubeManualLookupResult {
        let id: String
        do { id = try YouTubeURLValidator.parse(input) } catch { throw YouTubeError.invalidURL }
        do {
            var video = try await metadata.metadata(videoID: id)
            try Task.checkCancellation()
            if video.id == id, !video.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                if YouTubeImageURL.valid(video.thumbnailURL) == nil { video.thumbnailURL = Self.fallbackThumbnail(id) }
                return YouTubeManualLookupResult(video: video, metadataVerified: true)
            }
        } catch {
            if Task.isCancelled || error is CancellationError { throw CancellationError() }
            let mapped = YouTubeError.map(error, fallback: .metadataUnavailable)
            if mapped == .cancelled { throw CancellationError() }
            if mapped == .videoUnavailable { throw mapped }
        }
        if let video = try await oEmbed(id) { return YouTubeManualLookupResult(video: video, metadataVerified: true) }
        return YouTubeManualLookupResult(video: YouTubeVideo(id: id, title: "", thumbnailURL: Self.fallbackThumbnail(id)), metadataVerified: false)
    }

    /// Title, uploader and artwork only (no duration). nil when unavailable;
    /// throws `videoUnavailable` only for an explicit not-found response.
    func oEmbed(_ id: String) async throws -> YouTubeVideo? {
        var components = URLComponents(string: "https://www.youtube.com/oembed")
        components?.queryItems = [URLQueryItem(name: "url", value: "https://www.youtube.com/watch?v=" + id), URLQueryItem(name: "format", value: "json")]
        guard let url = components?.url else { return nil }
        let response: YouTubeHTTPResponse
        do { response = try await transport.send(YouTubeHTTP.request(url)) }
        catch {
            if Task.isCancelled || error is CancellationError || (error as? URLError)?.code == .cancelled { throw CancellationError() }
            return nil
        }
        try Task.checkCancellation()
        if [400, 404].contains(response.status) { throw YouTubeError.videoUnavailable }
        guard response.status == 200, response.data.count <= 100_000,
              let json = (try? JSONSerialization.jsonObject(with: response.data)) as? [String: Any],
              let title = (json["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty else { return nil }
        let thumbnail = (json["thumbnail_url"] as? String).flatMap { YouTubeImageURL.valid(URL(string: $0)) } ?? Self.fallbackThumbnail(id)
        return YouTubeVideo(id: id, title: String(title.prefix(500)), channel: json["author_name"] as? String, thumbnailURL: thumbnail)
    }
}
