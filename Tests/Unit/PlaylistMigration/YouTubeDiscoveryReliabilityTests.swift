import XCTest
@testable import OFFLINE

private final class DiscoveryEvents: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [YouTubeDiscoveryDiagnostic] = []
    func record(_ event: YouTubeDiscoveryDiagnostic) { lock.lock(); defer { lock.unlock() }; events.append(event) }
    var last: YouTubeDiscoveryDiagnostic? { lock.lock(); defer { lock.unlock() }; return events.last }
}
private actor RestrictedMetadata: YouTubeMetadataProvider {
    func metadata(videoID: String) async throws -> YouTubeVideo { throw YouTubeError.accessRestricted }
}
private actor PacedDiscovery: ExternalCandidateDiscovery {
    let pacer: MatchingRequestPacer
    var calls: [Int] = []
    init(interval: Duration) { pacer = .init(interval: interval) }
    func discover(_ source: PlaylistMigrationSourceTrack) async throws -> MatchingDiscoveryResult {
        calls.append(source.position)
        try await pacer.wait()
        return .init(recordings: [.init(provider: "fixture", identity: String(source.position), title: source.title, artist: source.primaryArtist, durationMs: source.durationMs)])
    }
}
final class YouTubeDiscoveryReliabilityTests: XCTestCase {
    func testHTTPAndParserFailuresHaveSafeDistinctStages() async throws {
        let cases: [(Int, String, YouTubeDiscoveryStage)] = [
            (429, "", .http), (403, "", .http), (503, "", .http),
            (200, "<html>Unavailable</html>", .htmlExtraction),
            (200, "ytInitialData={invalid};", .jsonDecoding),
            (200, "ytInitialData={};", .searchStructure),
            (200, "ytInitialData=\(try YTFixture.json(YTFixture.initial([["unknownRenderer": [:]]])));", .resultRenderers)
        ]
        for (status, body, stage) in cases {
            let events = DiscoveryEvents()
            let provider = YouTubeWebProvider(transport: YTTransportStub([YTTransportStub.response(body, status: status)]), diagnostics: events.record)
            do { _ = try await provider.search(query: "fixture", continuationToken: nil); XCTFail("Expected failure") } catch { }
            XCTAssertEqual(events.last?.stage, stage); XCTAssertEqual(events.last?.status, status)
            XCTAssertEqual(events.last?.responseType, .html)
            XCTAssertEqual(events.last?.category, status == 429 ? .rateLimited : status == 403 ? .accessRestricted : .searchUnavailable)
        }
        XCTAssertEqual(YouTubeResponseType("text/plain; private=value"), .other)
        let events = DiscoveryEvents()
        do { _ = try await YouTubeWebProvider(transport: YTTransportStub([]), diagnostics: events.record).search(query: "fixture", continuationToken: nil); XCTFail() } catch { }
        XCTAssertEqual(events.last?.stage, .transport); XCTAssertNil(events.last?.status)
        XCTAssertEqual(events.last?.category, .requestTimeout)
    }
    func testAssignmentWhitespaceMobileRichAndContinuationRenderers() throws {
        let items = [["richItemRenderer": ["content": YTFixture.renderer()]]]
        let mobile: [String: Any] = ["contents": ["singleColumnSearchResultsRenderer": ["sectionListRenderer": ["contents": items]]]]
        for assignment in ["ytInitialData=", "window [ 'ytInitialData' ] =\n", "var ytInitialData  = "] {
            let object = try YouTubeWebParser.initialData(in: assignment + YTFixture.json(mobile) + ";")
            XCTAssertEqual(try YouTubeWebParser.search(object).videos.first?.id, YTFixture.id)
        }
        let compact = ["compactVideoRenderer": YTFixture.renderer()["videoRenderer"]!]
        let continuation: [String: Any] = ["continuationContents": ["itemSectionContinuation": ["contents": [compact]]]]
        XCTAssertEqual(try YouTubeWebParser.search(continuation).videos.first?.id, YTFixture.id)
    }
    func testSearchMetadataReuseAndRestrictedWatchDoesNotPausePlaylist() async throws {
        let source = PlaylistMigrationSourceTrack(position: 0, title: "Song", primaryArtist: "Artist", durationMs: 180000)
        let video = YouTubeVideo(id: YTFixture.id, title: "Artist - Song", channel: "Uploader", duration: 180, availability: .unknown)
        let search = YTSearchStub([.success(.init(videos: [video], continuationToken: nil))])
        let reused = try await YouTubeSearchProviderAdapter(search: search, metadata: RestrictedMetadata(), pacer: .init(interval: .zero)).discover(source)
        XCTAssertTrue(reused.failures.isEmpty) // Unknown version cannot be recommended: no watch request needed.
        XCTAssertEqual(reused.recordings.first?.durationMs, 180000); XCTAssertFalse(reused.recordings[0].available)
        let calls = await search.calls; XCTAssertEqual(calls.count, 1)
        let explicit = PlaylistMigrationSourceTrack(position: 0, title: "Song (Studio)", primaryArtist: "Artist", durationMs: 180000)
        let known = YouTubeVideo(id: YTFixture.id, title: "Artist - Song (Studio)", channel: "Uploader", duration: 180, availability: .unknown)
        let second = YTSearchStub([.success(.init(videos: [known], continuationToken: nil))])
        let restricted = try await YouTubeSearchProviderAdapter(search: second, metadata: RestrictedMetadata(), pacer: .init(interval: .zero)).discover(explicit)
        XCTAssertEqual(restricted.failure, .accessRestricted); XCTAssertFalse(restricted.pauseDiscovery)
        XCTAssertEqual(restricted.recordings.count, 1); XCTAssertEqual(restricted.recordings[0].durationMs, 180000)
    }
    func testPacingAndCancellationResumePreservesCommittedCandidates() async throws {
        let clock = ContinuousClock(), pacer = MatchingRequestPacer(interval: .milliseconds(30))
        try await pacer.wait()
        let start = clock.now
        try await pacer.wait()
        XCTAssertGreaterThanOrEqual(start.duration(to: clock.now), .milliseconds(20))
        let f = try LibraryFixture(count: 0), repo = f.storage.playlistMigrations
        let session = try await repo.createPlaylist(from: MatchingCorrectionTests.source(3), operationID: "paced-resume")
        let slow = PacedDiscovery(interval: .seconds(30))
        let worker = PlaylistMigrationMatchingService(repository: repo, providers: [slow])
        let task = Task { try await worker.run(migrationID: session.id) { _ in } }
        for _ in 0..<200 { let calls = await slow.calls; if calls.count == 2 { break }; try await Task.sleep(for: .milliseconds(10)) }
        let calls = await slow.calls; XCTAssertEqual(calls, [0, 1])
        task.cancel()
        do { try await task.value; XCTFail("Expected cancellation") } catch { XCTAssertTrue(error is CancellationError) }
        let entry = try await repo.entries(migrationID: session.id)[0]
        let before = try await repo.candidates(entryID: entry.id)
        XCTAssertEqual(before.count, 1)
        let resumed = PacedDiscovery(interval: .zero)
        try await PlaylistMigrationMatchingService(repository: repo, providers: [resumed]).run(migrationID: session.id) { _ in }
        let resumedCalls = await resumed.calls, after = try await repo.candidates(entryID: entry.id)
        XCTAssertEqual(resumedCalls, [1, 2]); XCTAssertEqual(after, before)
    }
}
