import XCTest
@testable import OFFLINE

/// Exercises URLSession response handling without real network or redirect targets.
private final class FinalRedirectProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let response = HTTPURLResponse(url: request.url!, statusCode: 302, httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "text/html", "Location": "https://consent.youtube.com/m?continue=private-query"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data("<html>Consent</html>".utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() { }
}

private actor FinalMetadata: YouTubeMetadataProvider {
    var calls = 0
    func metadata(videoID: String) async throws -> YouTubeVideo {
        calls += 1
        return .init(id: videoID, title: "Artist - Song (Studio)", channel: "Uploader",
            thumbnailURL: URL(string: "https://i.ytimg.com/vi/\(videoID)/mqdefault.jpg"), duration: 180, availability: .available)
    }
}

private actor FinalEmptyRecovery: ExternalCandidateDiscovery {
    var calls: [Int] = []
    var restricted = true
    func discover(_ source: PlaylistMigrationSourceTrack) async throws -> MatchingDiscoveryResult {
        calls.append(source.position)
        if source.position == 0 { return .init() }
        if restricted { restricted = false; throw YouTubeError.rateLimited }
        return .init(recordings: [.init(provider: "fixture", identity: String(source.position), title: source.title, artist: source.primaryArtist)])
    }
}

final class FinalDiscoveryReliabilityTests: XCTestCase {
    private func redirect(_ delegate: YouTubeRedirectDelegate, from: String = "https://www.youtube.com/results?search_query=private",
                          to: String, method: String = "GET", nextMethod: String? = nil) -> URLRequest? {
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        var original = YouTubeHTTP.request(URL(string: from)!)
        original.httpMethod = method
        if method == "POST" { original.httpBody = Data("body".utf8) }
        let task = session.dataTask(with: original) // Not resumed: invoke Foundation's delegate contract directly.
        var proposed = URLRequest(url: URL(string: to)!)
        proposed.httpMethod = nextMethod ?? method
        proposed.setValue("private", forHTTPHeaderField: "Cookie")
        proposed.setValue("private", forHTTPHeaderField: "Authorization")
        var result: URLRequest?
        let response = HTTPURLResponse(url: original.url!, statusCode: 302, httpVersion: nil, headerFields: nil)!
        delegate.urlSession(session, task: task, willPerformHTTPRedirection: response, newRequest: proposed) { result = $0 }
        return result
    }
    func testLegitimateMobileAndCanonicalRedirectsPreserveMethodAndStripCredentials() throws {
        for host in ["youtube.com", "www.youtube.com", "m.youtube.com"] {
            let delegate = YouTubeRedirectDelegate()
            let request = try XCTUnwrap(redirect(delegate, to: "https://\(host)/results?search_query=private"))
            XCTAssertEqual(request.url?.host, host); XCTAssertEqual(delegate.category, .youtube)
            XCTAssertEqual(request.httpMethod, "GET"); XCTAssertFalse(request.httpShouldHandleCookies)
            XCTAssertNil(request.value(forHTTPHeaderField: "Cookie")); XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
            XCTAssertTrue(YouTubeURLSessionTransport.permitted(request.url!))
        }
        let post = try XCTUnwrap(redirect(YouTubeRedirectDelegate(), from: "https://youtube.com/youtubei/v1/search",
            to: "https://www.youtube.com/youtubei/v1/search", method: "POST"))
        XCTAssertEqual(post.httpBody, Data("body".utf8))
        XCTAssertNil(redirect(YouTubeRedirectDelegate(), from: "https://youtube.com/youtubei/v1/search",
            to: "https://www.youtube.com/youtubei/v1/search", method: "POST", nextMethod: "GET"))
    }
    func testRestrictionsForeignHostsLoopsAndCrossPurposeRedirectsAreNeverFollowed() {
        let cases: [(String, YouTubeRedirectCategory)] = [
            ("https://consent.youtube.com/m?continue=secret", .consent),
            ("https://consent.google.com/m", .consent), ("https://accounts.google.com/ServiceLogin", .login),
            ("https://www.youtube.com/signin?next=secret", .login),
            ("https://www.google.com/sorry/index?continue=secret", .verification),
            ("https://www.youtube.com/sorry/index", .verification),
            ("https://www.youtube.com/challenge", .verification),
            ("https://www.youtube.com/unknown", .unsupported),
            ("https://youtube.com.evil.example/results", .external),
            ("http://www.youtube.com/results", .unsafe),
            ("https://user:password@www.youtube.com/results", .unsafe),
            ("https://www.youtube.com:444/results", .unsafe),
            ("https://i.ytimg.com/vi/abcdefghijk/default.jpg", .artwork)
        ]
        for (url, category) in cases {
            let delegate = YouTubeRedirectDelegate()
            XCTAssertNil(redirect(delegate, to: url), url); XCTAssertEqual(delegate.category, category)
        }
        XCTAssertNil(redirect(YouTubeRedirectDelegate(), to: "https://www.youtube.com/watch?v=abcdefghijk"))
        XCTAssertNil(redirect(YouTubeRedirectDelegate(), from: "https://a.googlevideo.com/videoplayback",
            to: "https://www.youtube.com/watch?v=abcdefghijk", method: "HEAD"))
        XCTAssertNotNil(redirect(YouTubeRedirectDelegate(), from: "https://a.googlevideo.com/videoplayback",
            to: "https://b.googlevideo.com/videoplayback", method: "HEAD"))
        let loop = YouTubeRedirectDelegate()
        for _ in 0..<5 { XCTAssertNotNil(redirect(loop, to: "https://m.youtube.com/results")) }
        XCTAssertNil(redirect(loop, to: "https://m.youtube.com/results")); XCTAssertEqual(loop.category, .limit)
    }
    func testNativeTransportRetainsBlockedLocationCategoryWithoutPrivateURL() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [FinalRedirectProtocol.self]
        let transport = YouTubeURLSessionTransport(configuration: configuration)
        let response = try await transport.send(YouTubeHTTP.request(URL(string: "https://www.youtube.com/results")!))
        XCTAssertEqual(response.status, 302); XCTAssertEqual(response.redirect, .consent)
        XCTAssertThrowsError(try YouTubeHTTP.successful(response, fallback: .searchUnavailable)) {
            XCTAssertEqual($0 as? YouTubeError, .providerRestricted)
        }
        let event = YouTubeDiscoveryDiagnostic(stage: .transportRedirect, category: .providerRestricted,
            status: 302, responseType: .html, redirect: response.redirect)
        XCTAssertTrue(event.developerSummary.contains("Redirect: consent"))
        XCTAssertFalse(event.developerSummary.contains("private")); XCTAssertFalse(event.developerSummary.contains("https"))
    }
    func testBlockedRedirectAnd429PauseImmediatelyWithoutRetryOrFalseNoMatch() async throws {
        for (status, category, expected) in [(302, YouTubeRedirectCategory.consent, YouTubeError.providerRestricted),
                                            (302, .verification, .providerRestricted), (302, .external, .redirectUnavailable),
                                            (429, .youtube, .rateLimited)] {
            let f = try LibraryFixture(count: 0), repo = f.storage.playlistMigrations
            let source = MatchingCorrectionTests.source(200)
            let session = try await repo.createPlaylist(from: source, operationID: "blocked")
            var response = YTTransportStub.response(status: status); response.redirect = category
            let transport = YTTransportStub([response])
            let adapter = YouTubeSearchProviderAdapter(search: YouTubeWebProvider(transport: transport), pacer: .init(interval: .zero))
            try await PlaylistMigrationMatchingService(repository: repo, providers: [adapter]).run(migrationID: session.id) { _ in }
            let summary = try await repo.matchingSummary(migrationID: session.id), requests = await transport.requests
            let entries = try await repo.entries(migrationID: session.id)
            XCTAssertEqual(requests.count, 1); XCTAssertTrue(summary.discoveryPaused)
            XCTAssertEqual(summary.discoveryFailed, 1); XCTAssertEqual(summary.noMatch, 0); XCTAssertEqual(summary.deferred, 199)
            XCTAssertEqual(entries.map(\.source), source.entries)
            XCTAssertThrowsError(try YouTubeHTTP.successful(response, fallback: .searchUnavailable)) { XCTAssertEqual($0 as? YouTubeError, expected) }
        }
    }
    func testJSONAndHTMLShareValidationAndUnknownSchemasAreNotEmptyResults() async throws {
        let object = YTFixture.initial([YTFixture.renderer(title: "Artist - Song (Studio)")])
        let json = try YTFixture.json(object)
        for (type, body) in [("application/json", json), ("text/html", "window['ytInitialData'] = " + json + ";")] {
            let provider = YouTubeWebProvider(transport: YTTransportStub([YTTransportStub.response(body, contentType: type)]))
            let page = try await provider.search(query: "Song", continuationToken: nil)
            let video = try XCTUnwrap(page.videos.first)
            XCTAssertEqual(video.id, YTFixture.id); XCTAssertEqual(video.duration, 253); XCTAssertEqual(video.channel, "Artist")
            XCTAssertEqual(video.thumbnailURL?.host, "i.ytimg.com"); XCTAssertEqual(video.canonicalURL?.query, "v=" + YTFixture.id)
        }
        for object in [[String: Any](), YTFixture.initial([["newVideoRenderer": ["videoId": YTFixture.id]]]),
                       YTFixture.initial([["messageRenderer": ["text": ["simpleText": "Verify to continue"]]]])] {
            let provider = YouTubeWebProvider(transport: YTTransportStub([YTTransportStub.response(try YTFixture.json(object), contentType: "application/json")]))
            do { _ = try await provider.search(query: "Song", continuationToken: nil); XCTFail("Unknown response accepted") }
            catch { XCTAssertEqual(error as? YouTubeError, .searchUnavailable) }
        }
    }
    func testTwoHundredDuplicateOccurrencesReuseResponsesAndRetainMetadataAfterRestart() async throws {
        let f = try LibraryFixture(count: 0), repo = f.storage.playlistMigrations
        let source = PlaylistMigrationSourcePlaylist(source: .exportify, name: "Duplicates", entries: (0..<200).map {
            .init(position: $0, title: "Song (Studio)", primaryArtist: "Artist", durationMs: 180000)
        })
        let session = try await repo.createPlaylist(from: source, operationID: "duplicates")
        let video = YouTubeVideo(id: YTFixture.id, title: "Artist - Song (Studio)", duration: 180)
        let search = YTSearchStub([.success(.init(videos: [video], continuationToken: nil))]), metadata = FinalMetadata()
        let adapter = YouTubeSearchProviderAdapter(search: search, metadata: metadata, pacer: .init(interval: .zero))
        try await PlaylistMigrationMatchingService(repository: repo, providers: [adapter]).run(migrationID: session.id) { _ in }
        let searches = await search.calls, inspections = await metadata.calls
        XCTAssertEqual(searches.count, 1); XCTAssertEqual(inspections, 1)
        let entries = try await repo.entries(migrationID: session.id), summary = try await repo.matchingSummary(migrationID: session.id)
        XCTAssertEqual(entries.map(\.source), source.entries); XCTAssertEqual(summary.candidates, 200)
        XCTAssertEqual(summary.processed, 200); XCTAssertEqual(summary.deferred, 0)
        let saved = try await repo.candidates(entryID: entries[0].id)
        let candidate = try XCTUnwrap(saved.first)
        XCTAssertEqual(candidate.title, video.title); XCTAssertEqual(candidate.artist, "Artist"); XCTAssertEqual(candidate.durationMs, 180000)
        XCTAssertEqual(candidate.evidence["channel"], "Uploader"); XCTAssertEqual(candidate.decision, .pending)
        XCTAssertNotNil(candidate.confidence); XCTAssertEqual(MatchingCandidateArtwork.thumbnail(candidate)?.lastPathComponent, "mqdefault.jpg")
        XCTAssertEqual(MatchingCandidateArtwork.watchURL(candidate)?.query, "v=" + YTFixture.id)
        let database = try DatabaseManager(url: f.paths.database)
        let reopened = GRDBPlaylistMigrationRepository(db: database.dbQueue, paths: f.paths)
        try await PlaylistMigrationMatchingService(repository: reopened, providers: [adapter]).run(migrationID: session.id) { _ in }
        let retained = try await reopened.candidates(entryID: entries[0].id), afterSearches = await search.calls
        XCTAssertEqual(retained, saved); XCTAssertEqual(afterSearches.count, 1)
        let second = try await reopened.candidates(entryID: entries[1].id)
        XCTAssertNotEqual(second.first?.id, candidate.id)
    }
    func testResumeSkipsCompletedEmptySearchAndRetriesOnlyUnfinishedEntries() async throws {
        let f = try LibraryFixture(count: 0), repo = f.storage.playlistMigrations
        let session = try await repo.createPlaylist(from: MatchingCorrectionTests.source(3), operationID: "empty-resume")
        let provider = FinalEmptyRecovery()
        let worker = PlaylistMigrationMatchingService(repository: repo, providers: [provider])
        try await worker.run(migrationID: session.id) { _ in }
        try await worker.run(migrationID: session.id) { _ in }
        let calls = await provider.calls, summary = try await repo.matchingSummary(migrationID: session.id)
        XCTAssertEqual(calls, [0, 1, 1, 2]); XCTAssertEqual(summary.noMatch, 1)
        XCTAssertEqual(summary.discoveryFailed, 0); XCTAssertEqual(summary.deferred, 0)
    }
    func testRunCacheDoesNotRememberFailuresAndBrowserFallbackPreservesQuery() async throws {
        let source = PlaylistMigrationSourceTrack(position: 0, title: "Song & More (Live)", primaryArtist: "Artist")
        let search = YTSearchStub([.failure(.providerRestricted), .success(.init(videos: [YTFixture.video], continuationToken: nil)),
                                  .success(.init(videos: [YTFixture.video], continuationToken: nil))])
        let adapter = YouTubeSearchProviderAdapter(search: search, pacer: .init(interval: .zero)).forRun()
        let first = try await adapter.discover(source)
        XCTAssertTrue(first.pauseDiscovery)
        _ = try await adapter.discover(source)
        let calls = await search.calls
        XCTAssertEqual(calls.count, 3) // Failed first query is fetched again; unrelated title needs fallback.
        let url = try XCTUnwrap(YouTubeSearchProviderAdapter.browserSearchURL(source))
        XCTAssertEqual(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first?.value, "Artist Song & More (Live)")
    }
}
