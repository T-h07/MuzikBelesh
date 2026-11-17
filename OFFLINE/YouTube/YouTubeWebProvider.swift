import Foundation

// Public, anonymous web responses only. No login, cookies, API key or consent bypass.
struct YouTubeWebProvider: YouTubeSearchProvider, YouTubeMetadataProvider {
    let transport: any YouTubeTransport
    var diagnostics: @Sendable (YouTubeDiscoveryDiagnostic) -> Void = YouTubeDiscoveryDiagnostics.record
    private struct Cursor: Codable {
        let query: String
        let token: String
        let context: Data
    }
    func search(query: String, continuationToken: String?) async throws -> YouTubeSearchPage {
        var stage = YouTubeDiscoveryStage.request, status: Int?
        var responseType = YouTubeResponseType.unknown
        var redirect: YouTubeRedirectCategory?
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
                stage = .transport
                let response = try await transport.send(request)
                status = response.status; responseType = YouTubeResponseType(response.contentType); redirect = response.redirect
                stage = (300..<400).contains(response.status) ? .transportRedirect : .http
                try YouTubeHTTP.successful(response, fallback: .searchUnavailable)
                stage = .jsonDecoding
                guard let decoded = try JSONSerialization.jsonObject(with: response.data) as? [String: Any] else { throw YouTubeError.searchUnavailable }
                object = decoded
            } else {
                var components = URLComponents(string: "https://www.youtube.com/results")
                components?.queryItems = [URLQueryItem(name: "search_query", value: query), URLQueryItem(name: "hl", value: "en")]
                guard let url = components?.url else { throw YouTubeError.invalidURL }
                stage = .transport
                let response = try await transport.send(YouTubeHTTP.request(url))
                status = response.status; responseType = YouTubeResponseType(response.contentType); redirect = response.redirect
                stage = (300..<400).contains(response.status) ? .transportRedirect : .http
                try YouTubeHTTP.successful(response, fallback: .searchUnavailable)
                stage = .responseType
                guard responseType == .html || responseType == .json || responseType == .unknown else { throw YouTubeError.searchUnavailable }
                if responseType == .json {
                    stage = .jsonDecoding
                    guard let decoded = try JSONSerialization.jsonObject(with: response.data) as? [String: Any] else { throw YouTubeError.searchUnavailable }
                    object = decoded
                    context = [:]
                } else {
                    stage = .htmlEncoding
                    guard let html = String(data: response.data, encoding: .utf8) else { throw YouTubeError.searchUnavailable }
                    object = try YouTubeWebParser.initialData(in: html)
                    // Pagination configuration is optional for a valid first page.
                    let config = try? YouTubeWebParser.object(in: html, markers: ["ytcfg.set("])
                    let liveContext = config?["INNERTUBE_CONTEXT"] as? [String: Any]
                    context = liveContext?["client"] is [String: Any] ? (liveContext ?? [:]) : [:]
                }
            }
            try Task.checkCancellation()
            stage = .searchStructure
            let page = try YouTubeWebParser.search(object)
            let encoder = JSONEncoder()
            encoder.outputFormatting = .sortedKeys
            let token = try (context.isEmpty ? nil : page.continuationToken).map {
                // Canonical encoding keeps a repeated server token identical after decoding
                // context dictionaries, so the UI's consumed-token guard remains effective.
                try encoder.encode(Cursor(query: query, token: $0, context: JSONSerialization.data(withJSONObject: context, options: .sortedKeys))).base64EncodedString()
            }
            return YouTubeSearchPage(videos: page.videos, continuationToken: token)
        } catch {
            let category = YouTubeError.map(error, fallback: .searchUnavailable)
            diagnostics(.init(stage: (error as? YouTubeParserFailure)?.stage ?? stage, category: category, status: status, responseType: responseType, redirect: redirect))
            throw category
        }
    }
    func metadata(videoID: String) async throws -> YouTubeVideo {
        guard YouTubeURLValidator.isValidID(videoID), let url = URL(string: "https://www.youtube.com/watch?v=\(videoID)&hl=en") else { throw YouTubeError.invalidVideoID }
        var stage = YouTubeDiscoveryStage.transport, status: Int?
        var responseType = YouTubeResponseType.unknown
        var redirect: YouTubeRedirectCategory?
        do {
            let response = try await transport.send(YouTubeHTTP.request(url))
            status = response.status; responseType = YouTubeResponseType(response.contentType); redirect = response.redirect
            stage = (300..<400).contains(response.status) ? .transportRedirect : .http
            try YouTubeHTTP.successful(response, fallback: .metadataUnavailable)
            stage = .htmlEncoding
            guard let html = String(data: response.data, encoding: .utf8) else { throw YouTubeError.metadataUnavailable }
            let object = try YouTubeWebParser.object(in: html, markers: ["var ytInitialPlayerResponse =", "ytInitialPlayerResponse ="])
            stage = .watchStructure
            return try YouTubeWebParser.watch(object, videoID: videoID)
        } catch {
            let category = YouTubeError.map(error, fallback: .metadataUnavailable)
            diagnostics(.init(stage: (error as? YouTubeParserFailure)?.stage ?? stage, category: category, status: status, responseType: responseType, operation: .metadata, redirect: redirect))
            throw category
        }
    }
}
