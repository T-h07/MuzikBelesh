import XCTest
@testable import OFFLINE

private actor IsolatedDiscovery: ExternalCandidateDiscovery {
    var calls: [Int] = []
    var failures: Set<Int>
    let failure: YouTubeError
    init(_ failures: Set<Int>, failure: YouTubeError = .searchUnavailable) { self.failures = failures; self.failure = failure }
    func discover(_ source: PlaylistMigrationSourceTrack) async throws -> MatchingDiscoveryResult {
        calls.append(source.position)
        if failures.remove(source.position) != nil {
            return .init(failures: [failure.localizedDescription], failure: failure,
                         pauseDiscovery: MatchingDiscoveryFailurePolicy.immediate(failure), searchFailed: true)
        }
        return .init(recordings: [.init(provider: "fixture", identity: String(source.position), title: source.title,
                                       artist: source.primaryArtist, durationMs: source.durationMs)])
    }
}
final class MatchingFailureIsolationTests: XCTestCase {
    func testConsecutiveSearchFailuresRecoverWithoutLosingAnyOfTwoHundredEntries() async throws {
        let f = try LibraryFixture(count: 0), repo = f.storage.playlistMigrations
        let source = MatchingCorrectionTests.source(200)
        let session = try await repo.createPlaylist(from: source, operationID: "consecutive-recovery")
        let provider = IsolatedDiscovery([0, 1, 2])
        let worker = PlaylistMigrationMatchingService(repository: repo, providers: [provider])
        try await worker.run(migrationID: session.id) { _ in }
        let paused = try await repo.matchingSummary(migrationID: session.id)
        XCTAssertTrue(paused.discoveryPaused); XCTAssertEqual(paused.deferred, 197)
        try await worker.run(migrationID: session.id) { _ in }
        let calls = await provider.calls, entries = try await repo.entries(migrationID: session.id)
        let finished = try await repo.matchingSummary(migrationID: session.id)
        XCTAssertEqual(calls, [0, 1, 2] + Array(0..<200))
        XCTAssertEqual(entries.map(\.source), source.entries)
        XCTAssertEqual(Set(entries.map(\.id)).count, 200)
        XCTAssertEqual(finished.candidates, 200); XCTAssertEqual(finished.discoveryFailed, 0)
        XCTAssertEqual(finished.deferred, 0); XCTAssertFalse(finished.discoveryPaused)
    }
    func testOneFailureAtEntrySevenContinuesAllTwoHundredAndRetryPreservesCandidates() async throws {
        let f = try LibraryFixture(count: 0), repo = f.storage.playlistMigrations
        let session = try await repo.createPlaylist(from: MatchingCorrectionTests.source(200), operationID: "isolation")
        let provider = IsolatedDiscovery([6])
        let worker = PlaylistMigrationMatchingService(repository: repo, providers: [provider])
        try await worker.run(migrationID: session.id) { _ in }
        let entries = try await repo.entries(migrationID: session.id)
        let saved = try await repo.candidates(entryID: entries[0].id)
        let summary = try await repo.matchingSummary(migrationID: session.id)
        let calls = await provider.calls
        XCTAssertEqual(calls, Array(0..<200)); XCTAssertEqual(entries[6].status, .failed)
        XCTAssertEqual(summary.discoveryFailed, 1); XCTAssertEqual(summary.noMatch, 0)
        XCTAssertEqual(summary.candidates, 199); XCTAssertFalse(summary.discoveryPaused)
        try await worker.run(migrationID: session.id) { _ in }
        let retried = await provider.calls, retained = try await repo.candidates(entryID: entries[0].id)
        XCTAssertEqual(retried, Array(0..<200) + [6]); XCTAssertEqual(retained, saved)
    }
    func testRepeatedFailuresPauseAfterThreeEntriesBut429PausesImmediately() async throws {
        for rateLimited in [false, true] {
            let f = try LibraryFixture(count: 0), repo = f.storage.playlistMigrations
            let session = try await repo.createPlaylist(from: MatchingCorrectionTests.source(10), operationID: "threshold")
            let provider = IsolatedDiscovery(Set(0..<10), failure: rateLimited ? .rateLimited : .searchUnavailable)
            try await PlaylistMigrationMatchingService(repository: repo, providers: [provider]).run(migrationID: session.id) { _ in }
            let calls = await provider.calls, summary = try await repo.matchingSummary(migrationID: session.id)
            let expected = rateLimited ? 1 : 3
            XCTAssertEqual(calls.count, expected); XCTAssertEqual(summary.discoveryFailed, expected)
            XCTAssertEqual(summary.deferred, 10 - expected); XCTAssertEqual(summary.noMatch, 0)
            XCTAssertTrue(summary.discoveryPaused)
        }
    }
    func testSuccessResetsStreakAndSameEntryRetriesAreNotIndependent() {
        var policy = MatchingDiscoveryFailurePolicy()
        let id = UUID()
        for _ in 0..<5 { XCTAssertFalse(policy.observe(provider: 0, entry: id, searchFailed: true, restricted: false)) }
        XCTAssertFalse(policy.observe(provider: 0, entry: UUID(), searchFailed: true, restricted: false))
        XCTAssertFalse(policy.observe(provider: 0, entry: UUID(), searchFailed: false, restricted: false))
        XCTAssertFalse(policy.observe(provider: 0, entry: UUID(), searchFailed: true, restricted: false))
    }
    func testAmbiguousSearchRetriesOnceWithoutImmediatePauseAndSafeDiagnosticFields() async throws {
        let search = YTSearchStub([.failure(.searchUnavailable), .failure(.searchUnavailable)])
        let result = try await YouTubeSearchProviderAdapter(search: search, pacer: .init(interval: .zero))
            .discover(MatchingCorrectionTests.source(1).entries[0])
        let calls = await search.calls
        XCTAssertEqual(calls.count, 2); XCTAssertTrue(result.searchFailed); XCTAssertFalse(result.pauseDiscovery)
        let diagnostic = YouTubeDiscoveryDiagnostic(stage: .http, category: .rateLimited, status: 429, responseType: .html)
        XCTAssertEqual(diagnostic.developerSummary, "Category: rateLimited\nOperation: search\nStage: http\nHTTP: 429\nResponse: html")
    }
}
