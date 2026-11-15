import XCTest
@testable import OFFLINE

/// Records every real provider call. Individual failures, one-off restrictions and
/// a persistent provider-wide block (until healed) are configurable per position.
private actor SearchLog: ExternalCandidateDiscovery {
    var calls: [Int] = []
    var songFailures: Set<Int>
    var restrictedOnce: Set<Int>
    var blockedFrom: Int?
    init(songFailures: Set<Int> = [], restrictedOnce: Set<Int> = [], blockedFrom: Int? = nil) {
        self.songFailures = songFailures; self.restrictedOnce = restrictedOnce; self.blockedFrom = blockedFrom
    }
    func heal() { songFailures = []; restrictedOnce = []; blockedFrom = nil }
    func discover(_ source: PlaylistMigrationSourceTrack) async throws -> MatchingDiscoveryResult {
        calls.append(source.position)
        if let blockedFrom, source.position >= blockedFrom { throw YouTubeError.providerRestricted }
        if restrictedOnce.remove(source.position) != nil { throw YouTubeError.providerRestricted }
        if songFailures.contains(source.position) {
            return .init(failures: [YouTubeError.videoUnavailable.localizedDescription], failure: .videoUnavailable, searchFailed: true)
        }
        return .init(recordings: ["a", "b"].map {
            SongRecording(provider: "youtube", identity: String(format: "%010d", source.position) + $0, title: source.title,
                          artist: source.primaryArtist, durationMs: source.durationMs, channel: "Uploader")
        })
    }
}

final class MatchingIndependentSearchTests: XCTestCase {
    private func playlist(_ count: Int) -> PlaylistMigrationSourcePlaylist {
        .init(source: .exportify, name: "Independent", entries: (0..<count).map {
            .init(position: $0, title: "Track \($0 % 150)", primaryArtist: "Artist", album: "Album", durationMs: 180_000)
        })
    }
    private func service(_ repo: GRDBPlaylistMigrationRepository, _ provider: any ExternalCandidateDiscovery,
                         restriction: ProviderRestrictionPolicy = .noWait) -> PlaylistMigrationMatchingService {
        PlaylistMigrationMatchingService(repository: repo, providers: [provider], restriction: restriction)
    }

    /// Test A — song #10 fails on its own; #11–#200 are each searched.
    func testIndividualFailureAtSongTenStillSearchesEveryLaterSong() async throws {
        let f = try LibraryFixture(count: 0), repo = f.storage.playlistMigrations
        let session = try await repo.createPlaylist(from: playlist(200), operationID: "A")
        let provider = SearchLog(songFailures: [9])
        try await service(repo, provider).run(migrationID: session.id) { _ in }
        let calls = await provider.calls
        XCTAssertEqual(calls, Array(0..<200), "Songs 11–200 receive real discovery calls")
        let summary = try await repo.matchingSummary(migrationID: session.id)
        XCTAssertEqual(summary.processed, 200); XCTAssertEqual(summary.externalAttempted, 200)
        XCTAssertEqual(summary.externalSucceeded, 199); XCTAssertEqual(summary.discoveryFailedRequests, 1)
        XCTAssertEqual(summary.externalDeferred, 0, "No mass deferral"); XCTAssertFalse(summary.discoveryPaused)

        let entries = try await repo.entries(migrationID: session.id)
        let saved = try await repo.candidates(entryID: entries[150].id)
        await provider.heal()
        try await service(repo, provider).run(migrationID: session.id) { _ in }
        let retried = await provider.calls
        XCTAssertEqual(retried, Array(0..<200) + [9], "Song #10 remains retryable; nothing else is searched again")
        let kept = try await repo.candidates(entryID: entries[150].id)
        XCTAssertEqual(kept, saved)
    }

    /// Test B — genuine provider-wide verification from song #10 onward.
    func testProviderWideVerificationIsRespectedReportedHonestlyAndResumedAfterRestart() async throws {
        let f = try LibraryFixture(count: 0), repo = f.storage.playlistMigrations, input = playlist(200)
        let session = try await repo.createPlaylist(from: input, operationID: "B")
        let provider = SearchLog(blockedFrom: 9)
        try await service(repo, provider).run(migrationID: session.id) { _ in }

        // #10 is restricted; #11 and #12 each get one fresh probe after a cooldown; then no more requests.
        let calls = await provider.calls
        XCTAssertEqual(calls, Array(0...11))
        let summary = try await repo.matchingSummary(migrationID: session.id)
        XCTAssertEqual(summary.processed, 200, "Every entry is visited for local matching")
        XCTAssertEqual(summary.externalAttempted, 12, "Unsearched entries are not counted as searched")
        XCTAssertEqual(summary.externalSucceeded, 9); XCTAssertEqual(summary.discoveryFailedRequests, 3)
        XCTAssertEqual(summary.externalDeferred, 188); XCTAssertEqual(summary.noMatch, 0); XCTAssertTrue(summary.discoveryPaused)
        let overview = try await repo.resolutionOverview(migrationID: session.id)
        XCTAssertEqual(overview.items.filter { $0.category == .discoveryDeferred }.map(\.entry.position), Array(12..<200))

        // A user decision made before restart survives.
        let entries = try await repo.entries(migrationID: session.id)
        let candidate = try await repo.candidates(entryID: entries[0].id)[0]
        try await repo.selectCandidate(for: entries[0], candidateID: candidate.id)

        let reopened = try StorageCoordinator(paths: f.paths).playlistMigrations
        try reopened.recover()
        await provider.heal()
        try await service(reopened, provider).run(migrationID: session.id) { _ in }
        let resumed = await provider.calls
        XCTAssertEqual(resumed, Array(0...11) + Array(9..<200), "Resume starts at the earliest unfinished entry; 1–9 are not searched again")
        let finished = try await reopened.matchingSummary(migrationID: session.id)
        XCTAssertEqual(finished.externalDeferred, 0); XCTAssertEqual(finished.discoveryFailed, 0); XCTAssertEqual(finished.selected, 1)
        let after = try await reopened.entries(migrationID: session.id)
        XCTAssertEqual(after.map(\.source), input.entries); XCTAssertEqual(after.map(\.id), entries.map(\.id))
        let accepted = try await reopened.candidates(entryID: entries[0].id).filter { $0.decision == .accepted }
        XCTAssertEqual(accepted.map(\.id), [candidate.id])
    }

    /// Test C — a transient timeout on song #10 exhausts its bounded retries; song #11 is still searched.
    func testTransientTimeoutOnSongTenThenSongElevenGetsARealRequest() async throws {
        let f = try LibraryFixture(count: 0), repo = f.storage.playlistMigrations
        let source = MatchingCorrectionTests.source(12)
        let session = try await repo.createPlaylist(from: source, operationID: "C")
        func page(_ index: Int) -> Result<YouTubeSearchPage, YouTubeError> {
            .success(.init(videos: [YouTubeVideo(id: String(format: "%011d", index), title: "Artist - " + source.entries[index].title,
                channel: "Uploader", duration: 180, availability: .available)], continuationToken: nil))
        }
        let search = YTSearchStub((0..<9).map(page) + Array(repeating: .failure(.requestTimeout), count: 3) + [page(10), page(11)])
        let adapter = YouTubeSearchProviderAdapter(search: search, pacer: .init(interval: .zero), retryDelay: { _ in .zero })
        try await service(repo, adapter).run(migrationID: session.id) { _ in }
        let queries = await search.calls
        XCTAssertEqual(queries.count, 9 + 3 + 2)
        XCTAssertTrue(queries[12].contains("Song 10"), "Song #11 receives its own search request")
        let entries = try await repo.entries(migrationID: session.id)
        XCTAssertEqual(entries[9].status, .failed); XCTAssertEqual(entries[10].status, .needsReview); XCTAssertEqual(entries[11].status, .needsReview)
        let summary = try await repo.matchingSummary(migrationID: session.id)
        XCTAssertEqual(summary.discoveryFailed, 1); XCTAssertEqual(summary.externalDeferred, 0); XCTAssertFalse(summary.discoveryPaused)
    }

    /// Test D — traversal, real requests, failures, deferrals and candidates are separate counters.
    func testMetricsAreSeparateAndAccurate() async throws {
        let f = try LibraryFixture(count: 2), repo = f.storage.playlistMigrations
        let tracksBefore = try await f.storage.database.dbQueue.read { try StoredTrack.fetchCount($0) }
        let session = try await repo.createPlaylist(from: playlist(20), operationID: "D")
        let provider = SearchLog(songFailures: [3], restrictedOnce: [7])
        var reports: [SongMatchingProgress] = []
        let collector = ProgressCollector()
        try await service(repo, provider).run(migrationID: session.id) { await collector.add($0) }
        reports = await collector.values
        let summary = try await repo.matchingSummary(migrationID: session.id)
        XCTAssertEqual(summary.total, 20); XCTAssertEqual(summary.processed, 20)
        XCTAssertEqual(summary.externalAttempted, 20); XCTAssertEqual(summary.externalSucceeded, 18)
        XCTAssertEqual(summary.discoveryFailedRequests, 2); XCTAssertEqual(summary.externalDeferred, 0)
        XCTAssertEqual(summary.candidates, 36); XCTAssertEqual(summary.recommended + summary.review, 18)
        XCTAssertEqual(summary.selected, 0); XCTAssertEqual(summary.resolved, 0)
        let live = try XCTUnwrap(reports.last { $0.processed == 20 && $0.externalAttempted > 0 })
        XCTAssertEqual(live.externalAttempted, 20); XCTAssertEqual(live.externalSucceeded, 18); XCTAssertEqual(live.discoveryFailedRequests, 2)
        XCTAssertEqual(live.externalDeferred, 0)
        let tracksAfter = try await f.storage.database.dbQueue.read { try StoredTrack.fetchCount($0) }
        XCTAssertEqual(tracksAfter, tracksBefore, "Local library is untouched")
    }

    func testDuplicateOccurrencesAreSearchedIndependently() async throws {
        let f = try LibraryFixture(count: 0), repo = f.storage.playlistMigrations
        let session = try await repo.createPlaylist(from: playlist(160), operationID: "dupes") // 150–159 repeat 0–9
        let provider = SearchLog(songFailures: [2])
        try await service(repo, provider).run(migrationID: session.id) { _ in }
        let calls = await provider.calls, entries = try await repo.entries(migrationID: session.id)
        XCTAssertEqual(calls, Array(0..<160))
        XCTAssertEqual(entries[2].source.title, entries[152].source.title)
        XCTAssertEqual(entries[2].status, .failed); XCTAssertEqual(entries[152].status, .needsReview)
    }

    func testCancellationDuringCooldownPreservesProgressAndResumes() async throws {
        let f = try LibraryFixture(count: 0), repo = f.storage.playlistMigrations
        let session = try await repo.createPlaylist(from: playlist(10), operationID: "cancel")
        let provider = SearchLog(restrictedOnce: [2])
        let waiting = ProviderRestrictionPolicy(cooldowns: [.seconds(60)], sleep: { try await Task.sleep(for: $0) })
        let worker = service(repo, provider, restriction: waiting)
        let task = Task { try await worker.run(migrationID: session.id) { _ in } }
        for _ in 0..<300 { if await provider.calls.count == 3 { break }; try await Task.sleep(for: .milliseconds(10)) }
        try await Task.sleep(for: .milliseconds(50))
        task.cancel()
        do { try await task.value; XCTFail("Cancellation hidden") } catch { XCTAssertTrue(error is CancellationError) }
        let cancelledCalls = await provider.calls
        XCTAssertEqual(cancelledCalls, [0, 1, 2], "No request is made while waiting out a restriction")
        var entries = try await repo.entries(migrationID: session.id)
        XCTAssertTrue(entries.allSatisfy { $0.status != .matching })
        let saved = try await repo.candidates(entryID: entries[0].id)
        XCTAssertEqual(saved.count, 2)
        try await service(repo, provider).run(migrationID: session.id) { _ in }
        let calls = await provider.calls
        XCTAssertEqual(calls, [0, 1, 2] + Array(2..<10))
        entries = try await repo.entries(migrationID: session.id)
        XCTAssertTrue(entries.allSatisfy { $0.status == .needsReview })
        let kept = try await repo.candidates(entryID: entries[0].id)
        XCTAssertEqual(kept, saved)
    }
}

private actor ProgressCollector {
    var values: [SongMatchingProgress] = []
    func add(_ value: SongMatchingProgress) { values.append(value) }
}
