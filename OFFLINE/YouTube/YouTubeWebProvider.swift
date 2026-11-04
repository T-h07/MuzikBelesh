import Foundation

// Public, anonymous web responses only. No login, cookies, API key or consent bypass.
struct YouTubeWebProvider: YouTubeSearchProvider, YouTubeMetadataProvider {
    let transport: any YouTubeTransport
    private struct Cursor: Codable {
        let query: String
        let token: String
        let context: Data
    }
    func search(query: String, continuationToken: String?) async throws -> YouTubeSearchPage {
        do {
            let object: [String: Any], context: [String: Any]
            if let continuationToken {
                guard continuationToken.count < 100_000, let bytes = Data(base64Encoded: continuationToken),
                      let cursor = try? JSONDecoder().decode(Cursor.self, from: bytes), cursor.query == query,
                      let decoded = try? JSONSerialization.jsonObject(with: cursor.context) as? [String: Any],
                      let url = URL(string: "https://www.youtube.com/youtubei/v1/search") else { throw YouTubeError.searchUnavailable }
                context = decoded
                var request = YouTubeHTTP.request(url)
                request.httpMethod = "POST"
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                request.httpBody = try JSONSerialization.data(withJSONObject: ["context": context, "continuation": cursor.token])
                let response = try await transport.send(request)
                try YouTubeHTTP.successful(response, fallback: .searchUnavailable)
                guard let decoded = try JSONSerialization.jsonObject(with: response.data) as? [String: Any] else { throw YouTubeError.searchUnavailable }
                object = decoded
            } else {
                var components = URLComponents(string: "https://www.youtube.com/results")
                components?.queryItems = [URLQueryItem(name: "search_query", value: query), URLQueryItem(name: "hl", value: "en")]
                guard let url = components?.url else { throw YouTubeError.invalidURL }
                let response = try await transport.send(YouTubeHTTP.request(url))
                try YouTubeHTTP.successful(response, fallback: .searchUnavailable)
                guard let html = String(data: response.data, encoding: .utf8) else { throw YouTubeError.searchUnavailable }
                object = try YouTubeWebParser.object(in: html, markers: ["var ytInitialData =", "window[\"ytInitialData\"] =", "ytInitialData ="])
                let config = try YouTubeWebParser.object(in: html, markers: ["ytcfg.set("])
                guard let liveContext = config["INNERTUBE_CONTEXT"] as? [String: Any], liveContext["client"] is [String: Any] else { throw YouTubeError.searchUnavailable }
                context = liveContext // observed web client version; never a hardcoded rotating version
            }
            try Task.checkCancellation()
            let page = try YouTubeWebParser.search(object)
            let encoder = JSONEncoder()
            encoder.outputFormatting = .sortedKeys
            let token = try page.continuationToken.map {
                // Canonical encoding keeps a repeated server token identical after decoding
                // context dictionaries, so the UI's consumed-token guard remains effective.
                try encoder.encode(Cursor(query: query, token: $0, context: JSONSerialization.data(withJSONObject: context, options: .sortedKeys))).base64EncodedString()
            }
            return YouTubeSearchPage(videos: page.videos, continuationToken: token)
        } catch { throw YouTubeError.map(error, fallback: .searchUnavailable) }
    }
    func metadata(videoID: String) async throws -> YouTubeVideo {
        guard YouTubeURLValidator.isValidID(videoID), let url = URL(string: "https://www.youtube.com/watch?v=\(videoID)&hl=en") else { throw YouTubeError.invalidVideoID }
        do {
            let response = try await transport.send(YouTubeHTTP.request(url))
            try YouTubeHTTP.successful(response, fallback: .metadataUnavailable)
            guard let html = String(data: response.data, encoding: .utf8) else { throw YouTubeError.metadataUnavailable }
            let object: [String: Any]
            do { object = try YouTubeWebParser.object(in: html, markers: ["var ytInitialPlayerResponse =", "ytInitialPlayerResponse ="]) }
            catch { throw YouTubeError.metadataUnavailable }
            return try YouTubeWebParser.watch(object, videoID: videoID)
        } catch { throw YouTubeError.map(error, fallback: .metadataUnavailable) }
    }
}
