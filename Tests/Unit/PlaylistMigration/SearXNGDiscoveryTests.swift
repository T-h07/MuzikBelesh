import XCTest
@testable import OFFLINE

/// Answers each SearXNG request with one YouTube result derived from the query ("Artist Track N").
private actor SearXJSONTransport: YouTubeTransport {
    private(set) var queries: [String] = []
    let status: Int
    let delay: Duration
    init(status: Int = 200, delay: Duration = .zero) { self.status = status; self.delay = delay }
    func send(_ request: URLRequest) async throws -> YouTubeHTTPResponse {
        let items = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let query = items.first { $0.name == "q" }?.value ?? ""
        queries.append(query)
        if delay > .zero { try await Task.sleep(for: delay) }
        guard status == 200 else {
            return .init(data: Data("<html>Forbidden</html>".utf8), status: status, url: request.url!, contentType: "text/html")
        }
        let number = Int(query.split(separator: " ").last ?? "") ?? 0
        let id = String(format: "%011d", number)
        let body: [String: Any] = ["query": query, "results": [[
            "url": "https://www.youtube.com/watch?v=\(id)", "title": "Artist - Track \(number)", "author": "Artist",
            "length": "3:00", "thumbnail": "https://i.ytimg.com/vi/\(id)/hqdefault.jpg", "engine": "bing videos"]]]
        return .init(data: try JSONSerialization.data(withJSONObject: body), status: 200, url: request.url!, contentType: "application/json")
    }
}

/// Named fixture source; `empty` positions return a successful response with no candidates.
private actor NamedSource: ExternalCandidateDiscovery {
    nonisolated let discoveryName: String
    var calls: [Int] = []
    let empty: Set<Int>
    let restricted: Bool
    let partialFailure: Bool
    init(_ name: String, empty: Set<Int> = [], restricted: Bool = false, partialFailure: Bool = false) {
        discoveryName = name; self.empty = empty; self.restricted = restricted; self.partialFailure = partialFailure
    }
    func discover(_ source: PlaylistMigrationSourceTrack) async throws -> MatchingDiscoveryResult {
        calls.append(source.position)
        if restricted { throw YouTubeError.providerRestricted }
        if empty.contains(source.position) { return .init() }
        let recording = SongRecording(provider: "youtube", identity: String(format: "%011d", source.position), title: source.title,
                                      artist: source.primaryArtist, durationMs: source.durationMs, channel: "Artist", discoverySource: discoveryName)
        if partialFailure {
            return .init(recordings: [recording], failures: [YouTubeError.searchUnavailable.localizedDescription], failure: .searchUnavailable, searchFailed: true)
        }
        return .init(recordings: [recording])
    }
}

private actor SleepRecorder {
    var count = 0
    func hit() { count += 1 }
}

final class SearXNGDiscoveryTests: XCTestCase {
    private func playlist(_ count: Int) -> PlaylistMigrationSourcePlaylist {
        .init(source: .exportify, name: "SearXNG", entries: (0..<count).map {
            .init(position: $0, title: "Track \($0)", primaryArtist: "Artist", album: "Album", durationMs: 180_000)
        })
    }
    private func settings(enabled: Bool = true, url: String = "https://searx.test") -> DiscoverySourceSettings {
        let value = DiscoverySourceSettings(defaults: UserDefaults(suiteName: "searx-" + UUID().uuidString)!)
        value.searxEnabled = enabled; value.searxBaseURL = url
        return value
    }
    private func searx(_ settings: DiscoverySourceSettings, _ transport: any YouTubeTransport) -> ConfiguredSearXNGDiscovery {
        ConfiguredSearXNGDiscovery(settings: settings, transport: transport, pacer: .init(interval: .zero), retryDelay: { _ in .zero })
    }

    func testValidJSONResultsAreParsedDefensively() throws {
        let id = "dQw4w9WgXcQ"
        let json: [String: Any] = ["results": [
            ["url": "https://www.youtube.com/watch?v=\(id)&list=PL123", "title": "Artist - Song", "author": "Artist Official",
             "length": "1:02:03", "thumbnail": "https://i.ytimg.com/vi/\(id)/hqdefault.jpg", "engine": "google videos"],
            ["url": "https://youtu.be/\(id)", "title": "Duplicate identity"],
            ["url": "https://www.youtube.com/shorts/abcdefghijk", "title": "Short clip", "length": 42, "engines": ["brave.videos"]],
            ["url": "https://m.youtube.com/watch?v=ABCDEFGHIJK", "title": "Mobile link", "thumbnail": "https://evil.example/x.jpg", "length": "PT3M5S"],
        ]]
        let videos = try SearXNGParser.videos(JSONSerialization.data(withJSONObject: json))
        XCTAssertEqual(videos.map(\.id), [id, "abcdefghijk", "ABCDEFGHIJK"], "Duplicate identities are dropped")
        XCTAssertEqual(videos[0].title, "Artist - Song"); XCTAssertEqual(videos[0].channel, "Artist Official")
        XCTAssertEqual(videos[0].duration, 3723); XCTAssertEqual(videos[0].thumbnailURL?.host, "i.ytimg.com")
        XCTAssertEqual(videos[0].canonicalURL?.absoluteString, "https://www.youtube.com/watch?v=\(id)")
        XCTAssertEqual(videos[0].discoverySource, "searxng:google videos")
        XCTAssertTrue(videos[1].isShort); XCTAssertEqual(videos[1].duration, 42); XCTAssertEqual(videos[1].discoverySource, "searxng:brave.videos")
        XCTAssertNil(videos[2].thumbnailURL, "Untrusted artwork hosts are not used"); XCTAssertEqual(videos[2].duration, 185)
        XCTAssertEqual(videos[2].availability, .unknown, "Availability is never invented")
    }

    func testMissingOrInvalidMetadataStaysUnknownAndBadPayloadsThrow() throws {
        let json: [String: Any] = ["results": [
            ["url": "https://www.youtube.com/watch?v=dQw4w9WgXcQ", "title": "Song", "length": "about three minutes", "author": "  "],
            ["url": "https://www.youtube.com/watch?v=abcdefghijk"], // no title
            ["title": "No URL"],
        ]]
        let videos = try SearXNGParser.videos(JSONSerialization.data(withJSONObject: json))
        XCTAssertEqual(videos.count, 1); XCTAssertNil(videos[0].duration); XCTAssertNil(videos[0].channel); XCTAssertNil(videos[0].thumbnailURL)
        XCTAssertThrowsError(try SearXNGParser.videos(Data("<html>".utf8)))
        XCTAssertThrowsError(try SearXNGParser.videos(Data(#"{"query":"x"}"#.utf8)))
        for value: Any in ["0", -5, "99:99:99:99", 100_000] { XCTAssertNil(SearXNGParser.duration(value)) }
    }

    func testVideoIDExtractionAndRejectionOfUnrelatedURLs() {
        let id = "dQw4w9WgXcQ"
        for url in ["https://www.youtube.com/watch?v=\(id)", "https://youtube.com/watch?v=\(id)&t=30", "https://youtu.be/\(id)",
                    "https://www.youtube.com/shorts/\(id)", "https://www.youtube.com/embed/\(id)", "https://m.youtube.com/watch?v=\(id)"] {
            XCTAssertEqual(SearXNGParser.videoID(url), id, url)
        }
        for url in ["https://www.youtube.com/playlist?list=PL123", "https://www.youtube.com/@channel", "https://vimeo.com/123456",
                    "http://www.youtube.com/watch?v=\(id)", "https://www.youtube.com.evil.example/watch?v=\(id)",
                    "https://www.youtube.com/watch?v=short", "https://www.youtube.com/live/\(id)", "javascript:alert(1)",
                    "https://user:pass@www.youtube.com/watch?v=\(id)", "not a url"] {
            XCTAssertNil(SearXNGParser.videoID(url), url)
        }
    }

    func testEndpointValidationRequiresHTTPSExceptExplicitLAN() throws {
        XCTAssertEqual(try SearXNGEndpoint.validate("https://search.example.com/searx/", allowLANHTTP: false).absoluteString, "https://search.example.com/searx")
        XCTAssertThrowsError(try SearXNGEndpoint.validate("http://192.168.1.20:8080", allowLANHTTP: false))
        XCTAssertNoThrow(try SearXNGEndpoint.validate("http://192.168.1.20:8080", allowLANHTTP: true))
        XCTAssertThrowsError(try SearXNGEndpoint.validate("http://search.example.com", allowLANHTTP: true), "Public hosts never allow HTTP")
        XCTAssertThrowsError(try SearXNGEndpoint.validate("https://x.test/?q=1", allowLANHTTP: false))
        XCTAssertThrowsError(try SearXNGEndpoint.validate("", allowLANHTTP: true))
        XCTAssertNil(settings(enabled: false).searxURL); XCTAssertNil(settings(url: "http://8.8.8.8").searxURL)
    }

    func testDuplicateCandidatesAcrossProvidersAreSavedOnce() async throws {
        let f = try LibraryFixture(count: 0), repo = f.storage.playlistMigrations
        let session = try await repo.createPlaylist(from: playlist(3), operationID: "dedupe")
        let first = NamedSource("searxng", partialFailure: true), second = NamedSource("youtube")
        try await PlaylistMigrationMatchingService(repository: repo, providers: [first, second], restriction: .noWait).run(migrationID: session.id) { _ in }
        let secondCalls = await second.calls
        XCTAssertEqual(secondCalls, [0, 1, 2], "Fallback runs when the first source is incomplete")
        let entries = try await repo.entries(migrationID: session.id)
        let saved = try await repo.candidates(entryID: entries[0].id)
        XCTAssertEqual(saved.count, 1, "Same video identity from two sources is one candidate")
        XCTAssertEqual(entries[0].status, .needsReview)
    }

    func testDirectYouTubeVerificationDoesNotBlockSearXNGDiscovery() async throws {
        let f = try LibraryFixture(count: 0), repo = f.storage.playlistMigrations
        let session = try await repo.createPlaylist(from: playlist(50), operationID: "parallel-health")
        let searx = NamedSource("searxng", empty: [5, 20]), youtube = NamedSource("youtube", restricted: true)
        let sleeps = SleepRecorder()
        let policy = ProviderRestrictionPolicy(cooldowns: [.seconds(300)], sleep: { _ in await sleeps.hit() })
        let clock = ContinuousClock(), started = clock.now
        try await PlaylistMigrationMatchingService(repository: repo, providers: [searx, youtube], restriction: policy).run(migrationID: session.id) { _ in }
        XCTAssertLessThan(started.duration(to: clock.now), .seconds(30), "No multi-minute YouTube cooldown blocks the worker")
        let searxCalls = await searx.calls, youtubeCalls = await youtube.calls, slept = await sleeps.count
        XCTAssertEqual(searxCalls, Array(0..<50)); XCTAssertEqual(youtubeCalls, [5], "Restricted YouTube is not called again while cooling down")
        XCTAssertEqual(slept, 0)
        let entries = try await repo.entries(migrationID: session.id)
        XCTAssertEqual(entries.filter { $0.status == .needsReview }.count, 48)
        let summary = try await repo.matchingSummary(migrationID: session.id)
        XCTAssertEqual(summary.externalDeferred, 0); XCTAssertFalse(summary.discoveryPaused)
        XCTAssertEqual(summary.discoveryFailed, 2, "Songs whose fallback was skipped stay retryable, not no-match"); XCTAssertEqual(summary.noMatch, 0)
        let evidence = try await repo.candidates(entryID: entries[6].id).first?.evidence["discoveryProvider"]
        XCTAssertEqual(evidence, "searxng")
    }

    func testSearXNGUnavailableOrJSONDisabledFallsBackAndUnconfiguredIsNeverCalled() async throws {
        let forbidden = SearXJSONTransport(status: 403)
        let result = await SearXNGConnectionTest.run(settings: settings(), transport: forbidden)
        XCTAssertEqual(result, .failure(.jsonDisabled))
        let unreachable = await SearXNGConnectionTest.run(settings: settings(), transport: YTTransportStub([]))
        XCTAssertEqual(unreachable, .failure(.timeout))

        let f = try LibraryFixture(count: 0), repo = f.storage.playlistMigrations
        let session = try await repo.createPlaylist(from: playlist(6), operationID: "json-off")
        let youtube = NamedSource("youtube")
        try await PlaylistMigrationMatchingService(repository: repo, providers: [searx(settings(), forbidden), youtube], restriction: .noWait)
            .run(migrationID: session.id) { _ in }
        let youtubeCalls = await youtube.calls
        XCTAssertEqual(youtubeCalls, Array(0..<6))
        let entries = try await repo.entries(migrationID: session.id)
        XCTAssertTrue(entries.allSatisfy { $0.status == .needsReview })

        let idle = SearXJSONTransport()
        let other = try await repo.createPlaylist(from: playlist(2), operationID: "unconfigured")
        let summaryBefore = NamedSource("youtube")
        try await PlaylistMigrationMatchingService(repository: repo, providers: [searx(settings(enabled: false), idle), summaryBefore], restriction: .noWait)
            .run(migrationID: other.id) { _ in }
        let idleQueries = await idle.queries
        XCTAssertTrue(idleQueries.isEmpty, "A disabled source is never called")
        let summary = try await repo.matchingSummary(migrationID: other.id)
        XCTAssertEqual(summary.externalAttempted, 2)
    }

    func testTwoHundredSongsViaSearXNGSaveEachResultAndSkipYouTube() async throws {
        let f = try LibraryFixture(count: 0), repo = f.storage.playlistMigrations, input = playlist(200)
        let session = try await repo.createPlaylist(from: input, operationID: "searx-200")
        let transport = SearXJSONTransport(), youtube = NamedSource("youtube")
        try await PlaylistMigrationMatchingService(repository: repo, providers: [searx(settings(), transport), youtube], restriction: .noWait)
            .run(migrationID: session.id) { _ in }
        let queries = await transport.queries, youtubeCalls = await youtube.calls
        XCTAssertEqual(queries.count, 200); XCTAssertTrue(youtubeCalls.isEmpty)
        let entries = try await repo.entries(migrationID: session.id)
        XCTAssertEqual(entries.map(\.source), input.entries)
        for entry in entries.prefix(5) + entries.suffix(5) {
            let stored = try await repo.candidates(entryID: entry.id)
            let candidate = try XCTUnwrap(stored.first)
            XCTAssertEqual(candidate.providerTrackID, String(format: "%011d", entry.position))
            XCTAssertEqual(candidate.evidence["discoveryProvider"], "searxng:bing videos")
            XCTAssertEqual(candidate.durationMs, 180_000); XCTAssertEqual(candidate.decision, .pending)
            XCTAssertEqual(entry.status, .needsReview, "A SearXNG video is a candidate, never offline-ready")
        }
        let summary = try await repo.matchingSummary(migrationID: session.id)
        XCTAssertEqual(summary.externalAttempted, 200); XCTAssertEqual(summary.candidates, 200)
        XCTAssertEqual(summary.alreadyLocal + summary.localMatches, 0)
    }

    func testResumeAfterInterruptionAndConfirmedSelectionsAreUntouched() async throws {
        let f = try LibraryFixture(count: 0), repo = f.storage.playlistMigrations
        let session = try await repo.createPlaylist(from: playlist(40), operationID: "searx-resume")
        let slow = SearXJSONTransport(delay: .milliseconds(20))
        let worker = PlaylistMigrationMatchingService(repository: repo, providers: [searx(settings(), slow)], restriction: .noWait)
        let task = Task { try await worker.run(migrationID: session.id) { _ in } }
        for _ in 0..<500 { if await slow.queries.count >= 10 { break }; try await Task.sleep(for: .milliseconds(5)) }
        task.cancel()
        _ = try? await task.value
        let interrupted = await slow.queries.count
        XCTAssertLessThan(interrupted, 40)

        // User decisions made between runs are preserved.
        var entries = try await repo.entries(migrationID: session.id)
        let chosen = try await repo.candidates(entryID: entries[0].id)[0]
        try await repo.selectCandidate(for: entries[0], candidateID: chosen.id)

        let reopened = try StorageCoordinator(paths: f.paths).playlistMigrations
        try reopened.recover()
        let transport = SearXJSONTransport()
        try await PlaylistMigrationMatchingService(repository: reopened, providers: [searx(settings(), transport)], restriction: .noWait)
            .run(migrationID: session.id) { _ in }
        let resumed = await transport.queries
        XCTAssertFalse(resumed.contains("Artist Track 0"), "Completed and confirmed songs are not searched again")
        XCTAssertLessThanOrEqual(interrupted + resumed.count, 41, "At most the in-flight song is repeated")
        entries = try await reopened.entries(migrationID: session.id)
        XCTAssertEqual(entries[0].status, .matched)
        XCTAssertTrue(entries.dropFirst().allSatisfy { $0.status == .needsReview })
        let accepted = try await reopened.candidates(entryID: entries[0].id).filter { $0.decision == .accepted }
        XCTAssertEqual(accepted.map(\.id), [chosen.id])
    }
}
