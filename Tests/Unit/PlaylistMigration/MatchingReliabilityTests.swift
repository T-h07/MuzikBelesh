import XCTest
@testable import OFFLINE

private actor MidwayDiscovery: ExternalCandidateDiscovery {
    var calls: [Int] = []
    private var failed = false
    let partial: Bool
    init(partial: Bool) { self.partial = partial }
    func discover(_ source: PlaylistMigrationSourceTrack) async throws -> MatchingDiscoveryResult {
        calls.append(source.position)
        let recording = SongRecording(provider: "youtube", identity: String(format: "%011d", source.position),
            title: source.title, artist: source.primaryArtist, durationMs: source.durationMs,
            fullTitle: "Artist - " + source.title, channel: "Uploader")
        if source.position == 100 && !failed {
            failed = true
            return .init(recordings: partial ? [recording] : [], failures: [YouTubeError.searchUnavailable.localizedDescription],
                         failure: .searchUnavailable, pauseDiscovery: true)
        }
        return .init(recordings: [recording])
    }
}

final class MatchingReliabilityTests: XCTestCase {
    func testProviderFailureHalfwayPreservesCandidatesAndResumesOnlyUnfinishedEntries() async throws {
        for partial in [false, true] {
            let f = try LibraryFixture(count: 0), repo = f.storage.playlistMigrations
            let input = MatchingCorrectionTests.source(200)
            let session = try await repo.createPlaylist(from: input, operationID: "provider-stop")
            let provider = MidwayDiscovery(partial: partial)
            let worker = PlaylistMigrationMatchingService(repository: repo, providers: [provider])
            try await worker.run(migrationID: session.id) { _ in }
            let stopped = try await repo.matchingSummary(migrationID: session.id)
            XCTAssertEqual(stopped.processed, 101); XCTAssertEqual(stopped.deferred, 99)
            XCTAssertEqual(stopped.discoveryFailed, 1); XCTAssertEqual(stopped.noMatch, 0)
            XCTAssertTrue(stopped.discoveryPaused)
            let firstCalls = await provider.calls
            XCTAssertEqual(firstCalls, Array(0...100))
            let entries = try await repo.entries(migrationID: session.id)
            XCTAssertEqual(entries[100].status, partial ? .needsReview : .failed)
            XCTAssertEqual(entries[101].status, .pending)
            let originalCandidates = try await repo.candidates(entryID: entries[0].id)
            // Restart storage before retry; the UI can still inspect title/channel/artwork/link.
            let database = try DatabaseManager(url: f.paths.database)
            let reopened = GRDBPlaylistMigrationRepository(db: database.dbQueue, paths: f.paths)
            let saved = try await reopened.candidates(entryID: entries[0].id)
            XCTAssertEqual(saved, originalCandidates)
            let candidate = try XCTUnwrap(saved.first)
            XCTAssertEqual(candidate.title, "Artist - " + input.entries[0].title)
            XCTAssertEqual(candidate.evidence["channel"], "Uploader")
            XCTAssertNotNil(candidate.durationMs); XCTAssertNotNil(candidate.confidence)
            XCTAssertNotNil(MatchingCandidateArtwork.thumbnail(candidate))
            XCTAssertEqual(MatchingCandidateArtwork.watchURL(candidate)?.absoluteString, "https://www.youtube.com/watch?v=00000000000")
            try await PlaylistMigrationMatchingService(repository: reopened, providers: [provider]).run(migrationID: session.id) { _ in }
            let calls = await provider.calls, finished = try await reopened.matchingSummary(migrationID: session.id)
            XCTAssertEqual(calls, Array(0...100) + Array(100..<200))
            XCTAssertEqual(finished.candidates, 200); XCTAssertEqual(finished.discoveryFailed, 0)
            XCTAssertEqual(finished.deferred, 0); XCTAssertEqual(finished.noMatch, 0)
            let retained = try await reopened.candidates(entryID: entries[0].id)
            XCTAssertEqual(retained, originalCandidates)
        }
    }
    func testFirstPageDoesNotRequirePaginationConfigurationAndErrorMessagesAreNotEmptyResults() async throws {
        let html = "var ytInitialData = \(try YTFixture.json(YTFixture.initial([YTFixture.renderer()])));"
        let transport = YTTransportStub([YTTransportStub.response(html)])
        let result = try await YouTubeWebProvider(transport: transport).search(query: "Song", continuationToken: nil)
        XCTAssertEqual(result.videos.count, 1); XCTAssertNil(result.continuationToken)
        XCTAssertThrowsError(try YouTubeWebParser.search(YTFixture.initial([["messageRenderer": ["text": ["simpleText": "Sign in to continue"]]]])))
        XCTAssertTrue(try YouTubeWebParser.search(YTFixture.initial([["messageRenderer": ["text": ["simpleText": "No results found"]]]])).videos.isEmpty)
    }
    func testRestrictionsAndSchemaFailuresAreNotRetriedAutomatically() async throws {
        for error in [YouTubeError.accessRestricted, .rateLimited, .searchUnavailable] {
            let search = YTSearchStub([.failure(error)])
            let result = try await YouTubeSearchProviderAdapter(search: search).discover(MatchingCorrectionTests.source(1).entries[0])
            let calls = await search.calls
            XCTAssertEqual(calls.count, 1); XCTAssertEqual(result.failure, error)
            XCTAssertTrue(result.pauseDiscovery); XCTAssertTrue(result.recordings.isEmpty)
        }
    }
    func testTransientSearchFailureGetsOneBoundedRetry() async throws {
        let source = MatchingCorrectionTests.source(1).entries[0]
        let video = YouTubeVideo(id: YTFixture.id, title: "Artist - " + source.title, channel: "Uploader", duration: 180, availability: .available)
        let search = YTSearchStub([.failure(.requestTimeout), .success(.init(videos: [video], continuationToken: nil))])
        let result = try await YouTubeSearchProviderAdapter(search: search).discover(source)
        let calls = await search.calls
        XCTAssertEqual(calls.count, 2); XCTAssertEqual(result.recordings.count, 1)
        XCTAssertFalse(result.pauseDiscovery); XCTAssertTrue(result.failures.isEmpty)
    }
    func testFeaturedCreditsTrackNumbersAndAlternateSeparatorsKeepVersionGates() async throws {
        let source = PlaylistMigrationSourceTrack(position: 0, title: "Song (feat. Guest) (Studio)", primaryArtist: "Artist", durationMs: 180000)
        let video = YouTubeVideo(id: YTFixture.id, title: "01. Artist ft. Guest — Song (Studio) (Official Audio)", channel: "Uploader", duration: 180, availability: .available)
        let search = YTSearchStub([.success(.init(videos: [video], continuationToken: nil))])
        let found = try await YouTubeSearchProviderAdapter(search: search).discover(source)
        let recording = try XCTUnwrap(found.recordings.first)
        let score = CandidateScoringEngine().score(source: source, candidate: recording)
        XCTAssertEqual(score.evidence["featuredArtistAgreement"], "Compatible credits")
        XCTAssertFalse(score.gates.contains("Title identity is not exact"))
        XCTAssertEqual(SongMetadataNormalizer.cleanTitle("1979"), "1979")
        let remix = SongRecording(provider: "youtube", identity: "different", title: "Song (Remix)", artist: "Artist", durationMs: 180000)
        XCTAssertEqual(MatchDecisionPolicy().decide([CandidateScoringEngine().score(source: source, candidate: remix)]).outcome, .review)
        let uncertain = SongRecording(provider: "youtube", identity: "unknown", title: source.title, artist: nil, performerEstablished: false)
        let decision = MatchDecisionPolicy().decide([CandidateScoringEngine().score(source: source, candidate: uncertain)])
        XCTAssertLessThan(decision.ranked[0].score, 65); XCTAssertEqual(decision.outcome, .review)
    }
}
