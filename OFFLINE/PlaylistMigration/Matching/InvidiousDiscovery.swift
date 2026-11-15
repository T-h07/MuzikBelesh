import Foundation

enum InvidiousError: Error, Equatable, Sendable {
    case unreachable, timeout, server(Int), badResponse, rateLimited, apiDisabled(Int), noHealthyInstance, insecure
    /// Genuine connection/server failures may fail over to another instance.
    /// Rate limits and access refusals never do.
    var allowsFailover: Bool {
        switch self { case .unreachable, .timeout, .server, .badResponse: true; default: false }
    }
    var message: String {
        switch self {
        case .unreachable: "unreachable"
        case .timeout: "timed out"
        case .server(let code): "server error (HTTP \(code))"
        case .badResponse: "search API returned an invalid response"
        case .rateLimited: "rate limited (HTTP 429)"
        case .apiDisabled(let code): "search API disabled or requires credentials (HTTP \(code))"
        case .noHealthyInstance: "no public instance is currently available"
        case .insecure: "not HTTPS"
        }
    }
}

enum InvidiousParser {
    /// `GET /api/v1/search?type=video` returns a JSON array. Only `type == "video"`
    /// items with a valid 11-character ID survive; unknown metadata stays unknown.
    static func videos(_ data: Data, host: String, limit: Int = 30) throws -> [YouTubeVideo] {
        guard let items = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { throw InvidiousError.badResponse }
        var seen = Set<String>(), videos: [YouTubeVideo] = []
        for item in items.prefix(100) {
            guard item["type"] as? String == "video", let id = item["videoId"] as? String, YouTubeURLValidator.isValidID(id),
                  seen.insert(id).inserted,
                  let title = (item["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty, title.count <= 500 else { continue }
            let author = (item["author"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            let length = (item["lengthSeconds"] as? NSNumber)?.doubleValue
            // Instance-hosted thumbnails are not trusted artwork hosts; use YouTube's CDN for this ID.
            let thumbnail = (item["videoThumbnails"] as? [[String: Any]] ?? []).lazy
                .compactMap { ($0["url"] as? String).flatMap { YouTubeImageURL.valid(URL(string: $0)) } }.first
                ?? URL(string: "https://i.ytimg.com/vi/\(id)/hqdefault.jpg")
            var video = YouTubeVideo(id: id, title: title, channel: author?.isEmpty == false ? author : nil, thumbnailURL: thumbnail,
                                     duration: length.flatMap { $0 > 0 && $0 < 86_400 ? $0 : nil })
            if item["liveNow"] as? Bool == true { video.availability = .live }
            else if item["isUpcoming"] as? Bool == true { video.availability = .upcoming }
            else if item["premium"] as? Bool == true { video.availability = .unavailable } // Paid-only content.
            video.discoverySource = "invidious:" + String(host.prefix(60))
            videos.append(video)
            if videos.count == limit { break }
        }
        return videos
    }

    /// Official registry (api.invidious.io/instances.json): HTTPS domain hosts only; onion/i2p and IPs excluded.
    static func registryHosts(_ data: Data) -> [String] {
        guard let rows = try? JSONSerialization.jsonObject(with: data) as? [[Any]] else { return [] }
        return rows.compactMap { row -> String? in
            guard row.count >= 2, let host = (row[0] as? String)?.lowercased(), let info = row[1] as? [String: Any],
                  info["type"] as? String == "https", info["api"] as? Bool != false, InvidiousInstancePool.validHost(host) else { return nil }
            return host
        }
    }
}

struct InvidiousInstanceStatus: Equatable, Sendable, Identifiable {
    enum State: Equatable, Sendable { case unknown, healthy, unavailable(String), rateLimited }
    let host: String
    var state: State = .unknown
    var latency: Double?
    var id: String { host }
    var summary: String {
        switch state {
        case .unknown: "\(host): not checked"
        case .healthy: "\(host): search API OK" + (latency.map { String(format: " • %.2f s", $0) } ?? "")
        case .unavailable(let reason): "\(host): unavailable — \(reason)"
        case .rateLimited: "\(host): rate limited — cooling down"
        }
    }
}

/// Small trusted registry of public Invidious instances with health checks.
/// A host is considered working only after the actual search API answered a
/// harmless sample query with valid video results.
actor InvidiousInstancePool {
    /// HTTPS hosts from the official public list (docs.invidious.io/instances), Nov 2026.
    static let seedHosts = ["yt.chocolatemoo53.com", "inv.nadeko.net", "invidious.nerdvpn.de", "invidious.tiekoetter.com"]
    static let registryURL = URL(string: "https://api.invidious.io/instances.json?sort_by=type,users")!
    private struct Entry { var status: InvidiousInstanceStatus; var retryAt: ContinuousClock.Instant?; var checkedAt: ContinuousClock.Instant? }
    private let transport: any YouTubeTransport
    private let clock = ContinuousClock()
    private let unavailableCooldown: Duration
    private let disabledCooldown: Duration
    private let rateLimitCooldown: Duration
    private let healthTTL: Duration
    private let useRegistry: Bool
    private var entries: [Entry]
    private var registryLoaded = false

    init(transport: any YouTubeTransport, hosts: [String] = InvidiousInstancePool.seedHosts, useRegistry: Bool = true,
         unavailableCooldown: Duration = .seconds(300), disabledCooldown: Duration = .seconds(3600),
         rateLimitCooldown: Duration = .seconds(600), healthTTL: Duration = .seconds(900)) {
        self.transport = transport; self.useRegistry = useRegistry
        self.unavailableCooldown = unavailableCooldown; self.disabledCooldown = disabledCooldown
        self.rateLimitCooldown = rateLimitCooldown; self.healthTTL = healthTTL
        entries = hosts.filter(Self.validHost).map { Entry(status: .init(host: $0), retryAt: nil, checkedAt: nil) }
    }

    nonisolated static func validHost(_ host: String) -> Bool {
        host.count <= 100 && host.contains(".") && !host.hasSuffix(".onion") && !host.hasSuffix(".i2p") && !host.hasSuffix(".ygg")
            && host.range(of: #"^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+$"#, options: .regularExpression) != nil
            && host.range(of: #"^[0-9.]+$"#, options: .regularExpression) == nil
    }

    var statuses: [InvidiousInstanceStatus] { entries.map(\.status) }

    /// Adds HTTPS hosts from the official registry once per process (best effort).
    func loadRegistryIfNeeded() async {
        guard useRegistry, !registryLoaded else { return }
        registryLoaded = true
        var request = URLRequest(url: Self.registryURL, timeoutInterval: 6)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        guard let response = try? await transport.send(request), response.status == 200 else { return }
        for host in InvidiousParser.registryHosts(response.data).prefix(12) where !entries.contains(where: { $0.status.host == host }) {
            entries.append(Entry(status: .init(host: host), retryAt: nil, checkedAt: nil))
        }
    }

    private func cooling(_ entry: Entry) -> Bool { entry.retryAt.map { clock.now < $0 } ?? false }

    /// Lowest-latency healthy host; otherwise health-checks unchecked/expired hosts in order.
    func select() async throws -> String {
        await loadRegistryIfNeeded()
        let healthy = entries.filter { $0.status.state == .healthy && !cooling($0)
            && ($0.checkedAt.map { $0.duration(to: clock.now) < healthTTL } ?? false) }
        if let best = healthy.min(by: { ($0.status.latency ?? .infinity) < ($1.status.latency ?? .infinity) }) { return best.status.host }
        for index in entries.indices where !cooling(entries[index]) {
            if await check(index) { return entries[index].status.host }
        }
        throw InvidiousError.noHealthyInstance
    }

    /// Health-checks every host (Test Discovery Providers). Sequential and paced by the caller.
    func checkAll() async -> [InvidiousInstanceStatus] {
        await loadRegistryIfNeeded()
        for index in entries.indices where !cooling(entries[index]) || entries[index].status.state != .rateLimited { _ = await check(index) }
        return statuses
    }

    private func check(_ index: Int) async -> Bool {
        let host = entries[index].status.host
        do {
            let (videos, seconds) = try await request(host: host, query: "music")
            entries[index].checkedAt = clock.now
            guard !videos.isEmpty else { mark(index, .badResponse); return false }
            entries[index].status.state = .healthy; entries[index].status.latency = seconds; entries[index].retryAt = nil
            return true
        } catch let error as InvidiousError { mark(index, error); return false }
        catch { mark(index, .unreachable); return false }
    }

    private func mark(_ index: Int, _ error: InvidiousError) {
        entries[index].checkedAt = clock.now
        switch error {
        case .rateLimited:
            entries[index].status.state = .rateLimited; entries[index].retryAt = clock.now.advanced(by: rateLimitCooldown)
        case .apiDisabled:
            entries[index].status.state = .unavailable(error.message); entries[index].retryAt = clock.now.advanced(by: disabledCooldown)
        default:
            entries[index].status.state = .unavailable(error.message); entries[index].retryAt = clock.now.advanced(by: unavailableCooldown)
        }
    }

    func report(_ host: String, _ error: InvidiousError) {
        if let index = entries.firstIndex(where: { $0.status.host == host }) { mark(index, error) }
    }

    /// One search on one host; records latency on success.
    func search(_ query: String, on host: String) async throws -> [YouTubeVideo] {
        let (videos, seconds) = try await request(host: host, query: query)
        if let index = entries.firstIndex(where: { $0.status.host == host }) {
            entries[index].status.state = .healthy; entries[index].status.latency = seconds; entries[index].checkedAt = clock.now
        }
        return videos
    }

    private func request(host: String, query: String) async throws -> ([YouTubeVideo], Double) {
        var components = URLComponents()
        components.scheme = "https"; components.host = host; components.path = "/api/v1/search"
        components.queryItems = [URLQueryItem(name: "q", value: query), URLQueryItem(name: "type", value: "video")]
        guard let url = components.url, url.scheme == "https" else { throw InvidiousError.insecure }
        // Public instances measured ~2–8 s per search; 12 s bounds a slow request.
        var request = URLRequest(url: url, timeoutInterval: 12)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpShouldHandleCookies = false
        let started = clock.now
        let response: YouTubeHTTPResponse
        do { response = try await transport.send(request) }
        catch {
            if error is CancellationError || (error as? URLError)?.code == .cancelled { throw CancellationError() }
            throw (error as? URLError)?.code == .timedOut ? InvidiousError.timeout : InvidiousError.unreachable
        }
        try Task.checkCancellation()
        let elapsed = started.duration(to: clock.now)
        let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
        switch response.status {
        case 200..<300: break
        case 401, 403: throw InvidiousError.apiDisabled(response.status)
        case 429: throw InvidiousError.rateLimited
        case 500..<600: throw InvidiousError.server(response.status)
        default: throw InvidiousError.badResponse
        }
        return (try InvidiousParser.videos(response.data, host: host), seconds)
    }
}

/// YouTubeSearchProvider over the pool: at most one failover per query, and only
/// for genuine connection/server failures.
struct InvidiousPoolSearch: YouTubeSearchProvider {
    let pool: InvidiousInstancePool
    func search(query: String, continuationToken: String?) async throws -> YouTubeSearchPage {
        let query = YouTubeSearchService.normalize(query)
        guard continuationToken == nil, !query.isEmpty else { return YouTubeSearchPage(videos: [], continuationToken: nil) }
        var last = InvidiousError.noHealthyInstance
        for _ in 0..<2 {
            let host: String
            do { host = try await pool.select() } catch { break }
            do { return YouTubeSearchPage(videos: try await pool.search(query, on: host), continuationToken: nil) }
            catch let error as InvidiousError {
                await pool.report(host, error)
                last = error
                if !error.allowsFailover { break }
            }
        }
        switch last {
        case .rateLimited: throw YouTubeError.rateLimited          // Provider-wide: service cooldown, no instance hopping.
        case .timeout: throw YouTubeError.requestTimeout
        case .unreachable: throw YouTubeError.networkUnavailable
        // Every instance is down or cooling down: provider-wide, so songs are deferred, not "searched".
        case .noHealthyInstance: throw YouTubeError.sourceUnavailable
        default: throw YouTubeError.searchUnavailable
        }
    }
}

/// Public Invidious (default, no server or credentials). Reads settings per run.
struct PublicInvidiousDiscovery: ExternalCandidateDiscovery {
    let settings: DiscoverySourceSettings
    let pool: InvidiousInstancePool
    var pacer = MatchingRequestPacer(interval: .milliseconds(500)) // Courtesy pacing for volunteer-run instances.
    var retryDelay: @Sendable (Int) -> Duration = { YouTubeSearchProviderAdapter.backoff($0) }
    var discoveryName: String { "invidious" }
    func discover(_ source: PlaylistMigrationSourceTrack) async throws -> MatchingDiscoveryResult { try await forRun().discover(source) }
    func forRun() -> any ExternalCandidateDiscovery {
        guard settings.useInvidious else { return DisabledDiscovery(discoveryName: discoveryName) }
        return YouTubeSearchProviderAdapter(search: InvidiousPoolSearch(pool: pool), pacer: pacer, maxAttempts: 2,
                                            retryDelay: retryDelay, name: discoveryName).forRun()
    }
}
