import Foundation

enum SearXNGError: Error, Equatable, LocalizedError, Sendable {
    case notConfigured, insecureURL, unreachable, timeout, jsonDisabled, rateLimited, redirected, badResponse(Int?)
    var errorDescription: String? {
        switch self {
        case .notConfigured: "SearXNG is not configured."
        case .insecureURL: "Use an HTTPS address. Plain HTTP is allowed only for a LAN address when development LAN access is enabled."
        case .unreachable: "SearXNG could not be reached. Check that the computer running it is on and on the same network."
        case .timeout: "SearXNG did not respond in time."
        case .jsonDisabled: "SearXNG refused JSON output. Add `json` to search.formats in settings.yml."
        case .rateLimited: "SearXNG is limiting requests. Try again shortly."
        case .redirected: "SearXNG redirected the request. Enter the final instance address."
        case .badResponse(let status): "SearXNG returned an unexpected response" + (status.map { " (HTTP \($0))." } ?? ".")
        }
    }
}

/// User-controlled discovery sources. Reads are thread-safe (UserDefaults), so the
/// matching actor picks up changes at the start of each run.
final class DiscoverySourceSettings: @unchecked Sendable {
    static let defaultEngines = "bing videos, google videos, brave.videos"
    private let defaults: UserDefaults
    init(defaults: UserDefaults = .standard) { self.defaults = defaults }
    var searxEnabled: Bool { get { defaults.bool(forKey: "searxng.enabled") } set { defaults.set(newValue, forKey: "searxng.enabled") } }
    var searxBaseURL: String { get { defaults.string(forKey: "searxng.baseURL") ?? "" } set { defaults.set(newValue, forKey: "searxng.baseURL") } }
    var searxEngines: String { get { defaults.string(forKey: "searxng.engines") ?? Self.defaultEngines } set { defaults.set(newValue, forKey: "searxng.engines") } }
    var allowLANHTTP: Bool { get { defaults.bool(forKey: "searxng.allowLANHTTP") } set { defaults.set(newValue, forKey: "searxng.allowLANHTTP") } }
    /// Direct YouTube search is a fallback; enabled by default for compatibility.
    var directYouTubeEnabled: Bool {
        get { defaults.object(forKey: "discovery.directYouTube") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "discovery.directYouTube") }
    }
    var lastHealth: String? { get { defaults.string(forKey: "searxng.lastHealth") } set { defaults.set(newValue, forKey: "searxng.lastHealth") } }
    var engineList: [String] {
        searxEngines.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty && $0.count <= 40 }.prefix(8).map { $0 }
    }
    /// nil when SearXNG is disabled or the address is invalid/insecure.
    var searxURL: URL? { searxEnabled ? try? SearXNGEndpoint.validate(searxBaseURL, allowLANHTTP: allowLANHTTP) : nil }
}

enum SearXNGEndpoint {
    /// HTTPS anywhere; HTTP only for an explicit private-LAN/localhost host with the development switch on.
    static func validate(_ input: String, allowLANHTTP: Bool) throws -> URL {
        let value = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { throw SearXNGError.notConfigured }
        guard var components = URLComponents(string: value), let scheme = components.scheme?.lowercased(),
              let host = components.host?.lowercased(), !host.isEmpty,
              components.user == nil, components.password == nil, components.query == nil, components.fragment == nil else { throw SearXNGError.insecureURL }
        switch scheme {
        case "https": break
        case "http" where allowLANHTTP && isLAN(host): break
        default: throw SearXNGError.insecureURL
        }
        while components.path.hasSuffix("/") { components.path.removeLast() }
        guard let url = components.url else { throw SearXNGError.insecureURL }
        return url
    }
    static func isLAN(_ host: String) -> Bool {
        if host == "localhost" || host.hasSuffix(".local") { return true }
        let parts = host.split(separator: ".").compactMap { Int($0) }
        guard parts.count == 4, parts.allSatisfy({ (0...255).contains($0) }) else { return false }
        return parts[0] == 10 || parts[0] == 127 || (parts[0] == 192 && parts[1] == 168) || (parts[0] == 172 && (16...31).contains(parts[1]))
    }
}

/// Dedicated transport: short timeouts, no cookies/cache, and no redirects at all.
final class SearXNGURLSessionTransport: NSObject, YouTubeTransport, URLSessionTaskDelegate, @unchecked Sendable {
    private lazy var session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil; configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil; configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = 8; configuration.timeoutIntervalForResource = 12
        configuration.httpMaximumConnectionsPerHost = 2
        return URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
    }()
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
    func send(_ request: URLRequest) async throws -> YouTubeHTTPResponse {
        guard let url = request.url, ["https", "http"].contains(url.scheme?.lowercased() ?? "") else { throw SearXNGError.insecureURL }
        let (data, response) = try await session.data(for: request)
        try Task.checkCancellation()
        guard let http = response as? HTTPURLResponse, data.count <= 4_000_000 else { throw SearXNGError.badResponse(nil) }
        return YouTubeHTTPResponse(data: data, status: http.statusCode, url: http.url ?? url, contentType: http.value(forHTTPHeaderField: "Content-Type"))
    }
}

enum SearXNGParser {
    /// Parses the documented `format=json` response. Only individual YouTube videos
    /// survive; metadata the engine did not provide stays unknown.
    static func videos(_ data: Data, limit: Int = 30) throws -> [YouTubeVideo] {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let results = object["results"] as? [[String: Any]] else { throw SearXNGError.badResponse(200) }
        var seen = Set<String>(), videos: [YouTubeVideo] = []
        for result in results.prefix(200) {
            guard let raw = result["url"] as? String, let id = videoID(raw), seen.insert(id).inserted,
                  let title = (result["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty, title.count <= 500 else { continue }
            let engine = (result["engine"] as? String) ?? (result["engines"] as? [String])?.first
            let thumbnail = ["thumbnail", "img_src", "thumbnail_src"].lazy.compactMap { result[$0] as? String }
                .compactMap { YouTubeImageURL.valid(URL(string: $0)) }.first
            let author = (result["author"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            var video = YouTubeVideo(id: id, title: title, channel: author?.isEmpty == false ? author : nil,
                                     thumbnailURL: thumbnail, duration: duration(result["length"] ?? result["duration"]))
            video.isShort = (URLComponents(string: raw)?.path.lowercased().hasPrefix("/shorts/")) == true
            video.discoverySource = "searxng" + (engine.map { ":" + String($0.prefix(40)) } ?? "")
            videos.append(video)
            if videos.count == limit { break }
        }
        return videos
    }
    /// watch, youtu.be, shorts and embed links with one 11-character ID; never playlists/channels.
    static func videoID(_ raw: String) -> String? {
        guard raw.count <= 2048, let components = URLComponents(string: raw), components.scheme?.lowercased() == "https" else { return nil }
        if components.path == "/playlist" { return nil }
        guard let id = try? YouTubeURLValidator.parse(raw) else { return nil }
        if components.path.lowercased().hasPrefix("/live/") { return nil }
        return id
    }
    /// "3:45", "1:02:03", seconds as number/string, or ISO-8601 "PT3M45S". Unknown → nil.
    static func duration(_ value: Any?) -> TimeInterval? {
        var seconds: Double?
        if let number = value as? NSNumber { seconds = number.doubleValue }
        else if let text = (value as? String)?.trimmingCharacters(in: .whitespaces), !text.isEmpty {
            if let plain = Double(text) { seconds = plain }
            else if text.range(of: #"^\d{1,2}(:\d{2}){1,2}$"#, options: .regularExpression) != nil {
                seconds = text.split(separator: ":").reduce(0.0) { $0 * 60 + (Double($1) ?? 0) }
            } else if text.range(of: #"^PT(\d+H)?(\d+M)?(\d+S)?$"#, options: .regularExpression) != nil {
                var total = 0.0, number = ""
                for character in text.dropFirst(2) {
                    if character.isNumber { number.append(character); continue }
                    total += (Double(number) ?? 0) * (character == "H" ? 3600 : character == "M" ? 60 : 1); number = ""
                }
                seconds = total
            }
        }
        guard let seconds, seconds.isFinite, seconds > 0, seconds < 86_400 else { return nil }
        return seconds
    }
}

struct SearXNGSearchProvider: YouTubeSearchProvider {
    let baseURL: URL
    var engines: [String] = []
    let transport: any YouTubeTransport

    func request(_ query: String) throws -> URLRequest {
        guard var components = URLComponents(url: baseURL.appendingPathComponent("search"), resolvingAgainstBaseURL: false) else { throw SearXNGError.notConfigured }
        components.queryItems = [URLQueryItem(name: "q", value: query), URLQueryItem(name: "categories", value: "videos"),
                                 URLQueryItem(name: "format", value: "json")]
            + (engines.isEmpty ? [] : [URLQueryItem(name: "engines", value: engines.joined(separator: ","))])
        guard let url = components.url else { throw SearXNGError.notConfigured }
        var request = URLRequest(url: url, timeoutInterval: 8)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpShouldHandleCookies = false
        return request
    }

    /// Typed SearXNG errors (used by Test Connection).
    func fetch(_ query: String) async throws -> [YouTubeVideo] {
        let response: YouTubeHTTPResponse
        do { response = try await transport.send(try request(query)) }
        catch let error as SearXNGError { throw error }
        catch {
            if error is CancellationError || (error as? URLError)?.code == .cancelled { throw CancellationError() }
            throw (error as? URLError)?.code == .timedOut ? SearXNGError.timeout : SearXNGError.unreachable
        }
        try Task.checkCancellation()
        switch response.status {
        case 200..<300: break
        case 300..<400: throw SearXNGError.redirected
        case 403: throw SearXNGError.jsonDisabled
        case 429: throw SearXNGError.rateLimited
        default: throw SearXNGError.badResponse(response.status)
        }
        guard response.contentType?.lowercased().contains("json") != false else { throw SearXNGError.jsonDisabled }
        return try SearXNGParser.videos(response.data)
    }

    /// Maps to YouTubeError so the shared adapter's retry and restriction rules apply.
    func search(query: String, continuationToken: String?) async throws -> YouTubeSearchPage {
        guard continuationToken == nil else { return YouTubeSearchPage(videos: [], continuationToken: nil) }
        let query = YouTubeSearchService.normalize(query)
        guard !query.isEmpty else { return YouTubeSearchPage(videos: [], continuationToken: nil) }
        do { return YouTubeSearchPage(videos: try await fetch(query), continuationToken: nil) }
        catch let error as SearXNGError {
            switch error {
            case .unreachable: throw YouTubeError.networkUnavailable
            case .timeout: throw YouTubeError.requestTimeout
            case .rateLimited: throw YouTubeError.rateLimited
            case .redirected: throw YouTubeError.redirectUnavailable
            default: throw YouTubeError.searchUnavailable
            }
        }
    }
}

struct SearXNGHealth: Equatable, Sendable {
    let results: Int
    let seconds: Double
    var summary: String { "Connected • \(results) YouTube video result(s) • \(String(format: "%.2f", seconds)) s" }
}

enum SearXNGConnectionTest {
    static func run(settings: DiscoverySourceSettings, transport: any YouTubeTransport, query: String = "Daft Punk Get Lucky") async -> Result<SearXNGHealth, SearXNGError> {
        do {
            let url = try SearXNGEndpoint.validate(settings.searxBaseURL, allowLANHTTP: settings.allowLANHTTP)
            let clock = ContinuousClock(), start = clock.now
            let videos = try await SearXNGSearchProvider(baseURL: url, engines: settings.engineList, transport: transport).fetch(query)
            let elapsed = start.duration(to: clock.now)
            let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
            return .success(SearXNGHealth(results: videos.count, seconds: seconds))
        } catch let error as SearXNGError { return .failure(error) }
        catch { return .failure(.unreachable) }
    }
}

/// A source that is switched off for this run: never called, never counted.
struct DisabledDiscovery: ExternalCandidateDiscovery {
    let discoveryName: String
    var isEnabled: Bool { false }
    func discover(_ source: PlaylistMigrationSourceTrack) async throws -> MatchingDiscoveryResult { MatchingDiscoveryResult() }
}

/// SearXNG first (when configured); reads settings at the start of each run.
struct ConfiguredSearXNGDiscovery: ExternalCandidateDiscovery {
    let settings: DiscoverySourceSettings
    let transport: any YouTubeTransport
    var pacer = MatchingRequestPacer(interval: .milliseconds(300))
    var retryDelay: @Sendable (Int) -> Duration = { YouTubeSearchProviderAdapter.backoff($0) }
    var discoveryName: String { "searxng" }
    func discover(_ source: PlaylistMigrationSourceTrack) async throws -> MatchingDiscoveryResult { try await forRun().discover(source) }
    func forRun() -> any ExternalCandidateDiscovery {
        guard let url = settings.searxURL else { return DisabledDiscovery(discoveryName: discoveryName) }
        // Watch-page enrichment would contact YouTube directly; SearXNG candidates stay unverified.
        return YouTubeSearchProviderAdapter(search: SearXNGSearchProvider(baseURL: url, engines: settings.engineList, transport: transport),
                                            pacer: pacer, maxAttempts: 2, retryDelay: retryDelay, name: discoveryName).forRun()
    }
}

/// Direct YouTube search, gated by the user's fallback setting.
struct GatedDiscovery: ExternalCandidateDiscovery {
    let base: any ExternalCandidateDiscovery
    let enabled: @Sendable () -> Bool
    var discoveryName: String { base.discoveryName }
    func discover(_ source: PlaylistMigrationSourceTrack) async throws -> MatchingDiscoveryResult { try await base.discover(source) }
    func forRun() -> any ExternalCandidateDiscovery { enabled() ? base.forRun() : DisabledDiscovery(discoveryName: discoveryName) }
}
