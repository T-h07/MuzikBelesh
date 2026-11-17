import XCTest
import GRDB
@testable import OFFLINE

/// Mocked HTTP per host. `.search` answers each query with one video derived from "Artist Track N".
private actor HostStub: YouTubeTransport {
    enum Behavior: Sendable { case search, status(Int, String), timeout, unreachable, empty }
    private var behaviors: [String: Behavior]
    private(set) var requests: [String] = []
    init(_ behaviors: [String: Behavior]) { self.behaviors = behaviors }
    func set(_ host: String, _ behavior: Behavior) { behaviors[host] = behavior }
    func count(_ host: String) -> Int { requests.filter { $0.hasPrefix(host + " ") }.count }
    func send(_ request: URLRequest) async throws -> YouTubeHTTPResponse {
        let url = request.url!, host = url.host ?? ""
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "q" }?.value ?? ""
        requests.append(host + " " + query)
        switch behaviors[host] ?? .unreachable {
        case .timeout: throw URLError(.timedOut)
        case .unreachable: throw URLError(.cannotConnectToHost)
        case .status(let code, let body): return .init(data: Data(body.utf8), status: code, url: url, contentType: "text/plain")
        case .empty: return .init(data: Data("[]".utf8), status: 200, url: url, contentType: "application/json")
        case .search:
            let number = Int(query.split(separator: " ").last ?? "") ?? 7
            let id = String(format: "%011d", number)
            let body: [[String: Any]] = [
                ["type": "channel", "author": "Artist", "authorId": "UC1"],
                ["type": "video", "title": "Artist - Track \(number)", "videoId": id, "author": "Artist", "lengthSeconds": 180,
                 "videoThumbnails": [["quality": "maxres", "url": "https://\(host)/vi/\(id)/maxres.jpg"]],
                 "liveNow": false, "premium": false, "isUpcoming": false]]
            return .init(data: try JSONSerialization.data(withJSONObject: body), status: 200, url: url, contentType: "application/json")
        }
    }
}

private actor BlockedYouTube: ExternalCandidateDiscovery {
    nonisolated let discoveryName = "youtube"
    var calls: [Int] = []
    func discover(_ source: PlaylistMigrationSourceTrack) async throws -> MatchingDiscoveryResult {
        calls.append(source.position); throw YouTubeError.providerRestricted
    }
}

final class InvidiousDiscoveryTests: XCTestCase {
    private func playlist(_ count: Int) -> PlaylistMigrationSourcePlaylist {
        .init(source: .exportify, name: "Invidious", entries: (0..<count).map {
            .init(position: $0, title: "Track \($0)", primaryArtist: "Artist", album: "Album", durationMs: 180_000)
        })
    }
    private func settings() -> DiscoverySourceSettings { DiscoverySourceSettings(defaults: UserDefaults(suiteName: "inv-" + UUID().uuidString)!) }
    private func pool(_ stub: HostStub, _ hosts: [String]) -> InvidiousInstancePool {
        InvidiousInstancePool(transport: stub, hosts: hosts, useRegistry: false)
    }
    private func source(_ pool: InvidiousInstancePool, _ settings: DiscoverySourceSettings? = nil) -> PublicInvidiousDiscovery {
        PublicInvidiousDiscovery(settings: settings ?? self.settings(), pool: pool, pacer: .init(interval: .zero), retryDelay: { _ in .zero })
    }

    func testParsesRealShapedSearchResponseAndRejectsNonVideos() throws {
        let json: [[String: Any]] = [
            ["type": "video", "title": "Adele - Hello (Official Music Video)", "videoId": "YQHsXMglC9A", "author": "Adele",
             "lengthSeconds": 367, "videoThumbnails": [["quality": "maxres", "url": "https://yt.example.com/vi/YQHsXMglC9A/maxres.jpg"]],
             "liveNow": false, "premium": false, "isUpcoming": false],
            ["type": "video", "title": "Duplicate", "videoId": "YQHsXMglC9A"],
            ["type": "playlist", "title": "Mix", "playlistId": "PL1"], ["type": "channel", "author": "Adele"],
            ["type": "video", "title": "Bad id", "videoId": "short"],
            ["type": "video", "title": "Live now", "videoId": "abcdefghijk", "lengthSeconds": 0, "liveNow": true,
             "videoThumbnails": [["url": "https://i.ytimg.com/vi/abcdefghijk/hqdefault.jpg"]]],
            ["type": "video", "title": "Members only", "videoId": "ABCDEFGHIJK", "premium": true],
            ["type": "video", "videoId": "zzzzzzzzzzz"],
        ]
        let videos = try InvidiousParser.videos(JSONSerialization.data(withJSONObject: json), host: "yt.example.com")
        XCTAssertEqual(videos.map(\.id), ["YQHsXMglC9A", "abcdefghijk", "ABCDEFGHIJK"])
        XCTAssertEqual(videos[0].title, "Adele - Hello (Official Music Video)"); XCTAssertEqual(videos[0].channel, "Adele")
        XCTAssertEqual(videos[0].duration, 367); XCTAssertEqual(videos[0].availability, .unknown, "Availability is not invented")
        XCTAssertEqual(videos[0].thumbnailURL?.absoluteString, "https://i.ytimg.com/vi/YQHsXMglC9A/hqdefault.jpg", "Instance-hosted artwork is replaced by YouTube's CDN")
        XCTAssertEqual(videos[0].canonicalURL?.absoluteString, "https://www.youtube.com/watch?v=YQHsXMglC9A")
        XCTAssertEqual(videos[0].discoverySource, "invidious:yt.example.com")
        XCTAssertEqual(videos[1].availability, .live); XCTAssertNil(videos[1].duration)
        XCTAssertEqual(videos[1].thumbnailURL?.host, "i.ytimg.com")
        XCTAssertEqual(videos[2].availability, .unavailable); XCTAssertNil(videos[2].channel)
        XCTAssertThrowsError(try InvidiousParser.videos(Data(#"{"error":"x"}"#.utf8), host: "h"))
        XCTAssertThrowsError(try InvidiousParser.videos(Data("Endpoint disabled".utf8), host: "h"))
    }

    func testRegistryKeepsOnlyHTTPSDomainHosts() throws {
        let rows: [[Any]] = [["good.example.com", ["type": "https", "api": true]], ["noapi.example.com", ["type": "https", "api": false]],
                             ["unknown.example.com", ["type": "https"]], ["abc.onion", ["type": "onion"]], ["x.i2p", ["type": "i2p"]],
                             ["1.2.3.4", ["type": "https", "api": true]], ["bad host/x", ["type": "https", "api": true]]]
        XCTAssertEqual(InvidiousParser.registryHosts(try JSONSerialization.data(withJSONObject: rows)), ["good.example.com", "unknown.example.com"])
    }

    func testHealthCheckUsesRealSearchAndSkipsDisabledInstances() async throws {
        let stub = HostStub(["a.example": .status(403, "Endpoint disabled"), "b.example": .timeout, "c.example": .empty, "d.example": .search])
        let pool = pool(stub, ["a.example", "b.example", "c.example", "d.example"])
        let selected = try await pool.select()
        XCTAssertEqual(selected, "d.example", "A host counts only after the search API returns valid videos")
        let again = try await pool.select()
        XCTAssertEqual(again, "d.example")
        let aCount = await stub.count("a.example"), bCount = await stub.count("b.example")
        XCTAssertEqual(aCount, 1); XCTAssertEqual(bCount, 1, "Unavailable hosts are not rechecked during their cooldown")
        let statuses = await pool.statuses
        XCTAssertEqual(statuses.first { $0.host == "a.example" }?.state, .unavailable("search API disabled or requires credentials (HTTP 403)"))
        XCTAssertEqual(statuses.first { $0.host == "d.example" }?.state, .healthy)
    }

    func testFailoverOnlyForConnectionFailuresNeverForRateLimits() async throws {
        let stub = HostStub(["a.example": .search, "b.example": .search])
        let pool = pool(stub, ["a.example", "b.example"])
        _ = try await pool.select()
        await stub.set("a.example", .status(502, "bad gateway"))
        let page = try await InvidiousPoolSearch(pool: pool).search(query: "Artist Track 3", continuationToken: nil)
        XCTAssertEqual(page.videos.first?.discoverySource, "invidious:b.example", "Server error fails over once")

        await stub.set("b.example", .status(429, "slow down"))
        await stub.set("a.example", .search)
        let before = await stub.requests.count
        do { _ = try await InvidiousPoolSearch(pool: pool).search(query: "Artist Track 4", continuationToken: nil); XCTFail("429 hidden") }
        catch { XCTAssertEqual(error as? YouTubeError, .rateLimited) }
        let after = await stub.requests.count
        XCTAssertEqual(after - before, 1, "A rate limit is not evaded by switching instances")
    }

    func testAllInstancesUnavailableFallsBackWithoutHammering() async throws {
        let stub = HostStub(["a.example": .unreachable, "b.example": .timeout])
        let f = try LibraryFixture(count: 0), repo = f.storage.playlistMigrations
        let session = try await repo.createPlaylist(from: playlist(30), operationID: "inv-down")
        let fallback = BlockedYouTube()
        try await PlaylistMigrationMatchingService(repository: repo, providers: [source(pool(stub, ["a.example", "b.example"])), fallback],
                                                   restriction: .noWait).run(migrationID: session.id) { _ in }
        let requests = await stub.requests.count, calls = await fallback.calls
        XCTAssertEqual(requests, 2, "Each down host is checked once, then left alone during its cooldown")
        XCTAssertEqual(calls, [0, 1, 2], "Fallback is used; its own verification restriction is respected")
        let summary = try await repo.matchingSummary(migrationID: session.id)
        XCTAssertEqual(summary.processed, 30); XCTAssertEqual(summary.noMatch, 0)
        XCTAssertEqual(summary.externalDeferred, 27, "Songs never searched are deferred, not counted as searched")
    }

    func testTwoHundredSongsViaPublicInvidiousWhileDirectYouTubeIsBlocked() async throws {
        let stub = HostStub(["inv.example": .search])
        let f = try LibraryFixture(count: 2), repo = f.storage.playlistMigrations, input = playlist(200)
        let tracksBefore = try await f.storage.database.dbQueue.read { try StoredTrack.fetchCount($0) }
        let session = try await repo.createPlaylist(from: input, operationID: "inv-200")
        let youtube = BlockedYouTube()
        let invidious = source(pool(stub, ["inv.example"]))
        try await PlaylistMigrationMatchingService(repository: repo, providers: [invidious, youtube], restriction: .noWait)
            .run(migrationID: session.id) { _ in }
        let youtubeCalls = await youtube.calls, requests = await stub.requests.count
        XCTAssertTrue(youtubeCalls.isEmpty, "Direct YouTube is not needed when public search found candidates")
        XCTAssertEqual(requests, 201, "One health check plus one search per song")
        var entries = try await repo.entries(migrationID: session.id)
        XCTAssertEqual(entries.map(\.source), input.entries)
        let sample = try await repo.candidates(entryID: entries[123].id)
        XCTAssertEqual(sample.first?.providerTrackID, String(format: "%011d", 123))
        XCTAssertEqual(sample.first?.title, "Artist - Track 123"); XCTAssertEqual(sample.first?.durationMs, 180_000)
        XCTAssertEqual(sample.first?.evidence["discoveryProvider"], "invidious:inv.example")
        XCTAssertEqual(sample.first.flatMap(MatchingCandidateArtwork.thumbnail)?.host, "i.ytimg.com")
        let summary = try await repo.matchingSummary(migrationID: session.id)
        XCTAssertEqual(summary.externalAttempted, 200); XCTAssertEqual(summary.candidates, 200); XCTAssertEqual(summary.externalDeferred, 0)

        // Confirmed decisions and the playlist survive restart; nothing is acquired.
        try await repo.selectCandidate(for: entries[0], candidateID: try await repo.candidates(entryID: entries[0].id)[0].id)
        let reopened = try StorageCoordinator(paths: f.paths).playlistMigrations
        try reopened.recover()
        entries = try await reopened.entries(migrationID: session.id)
        XCTAssertEqual(entries.map(\.source), input.entries); XCTAssertEqual(entries[0].status, .matched)
        let tracksAfter = try await f.storage.database.dbQueue.read { try StoredTrack.fetchCount($0) }
        let jobs = try await f.storage.database.dbQueue.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM download_jobs") ?? 0 }
        XCTAssertEqual(tracksAfter, tracksBefore); XCTAssertEqual(jobs, 0)
    }

    func testIndividualFailuresDoNotStopTheRunAndDisabledSourceIsNeverCalled() async throws {
        let stub = HostStub(["inv.example": .search])
        let f = try LibraryFixture(count: 0), repo = f.storage.playlistMigrations
        let session = try await repo.createPlaylist(from: playlist(20), operationID: "inv-off")
        let off = settings(); off.automaticDiscovery = false; off.invidiousEnabled = false
        let youtube = BlockedYouTube()
        try await PlaylistMigrationMatchingService(repository: repo, providers: [source(pool(stub, ["inv.example"]), off), youtube], restriction: .noWait)
            .run(migrationID: session.id) { _ in }
        let requests = await stub.requests.count, calls = await youtube.calls
        XCTAssertEqual(requests, 0, "A disabled public source sends no queries")
        XCTAssertEqual(calls, [0, 1, 2], "The restricted fallback gets bounded probes only")
        let summary = try await repo.matchingSummary(migrationID: session.id)
        XCTAssertEqual(summary.processed, 20); XCTAssertEqual(summary.externalDeferred, 17); XCTAssertEqual(summary.noMatch, 0)
        XCTAssertTrue(off.useDirectYouTube)
        XCTAssertTrue(settings().useInvidious && settings().useDirectYouTube, "Automatic Discovery is the default")
    }
}
