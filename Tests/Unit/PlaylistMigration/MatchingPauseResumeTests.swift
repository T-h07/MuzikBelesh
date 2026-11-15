import XCTest
import GRDB
@testable import OFFLINE

@MainActor private final class ExecutionMock: MatchingBackgroundExecuting {
    var begins = 0, ends = 0
    var expiration: (@MainActor () -> Void)?
    func begin(start: @escaping @MainActor () -> Void, expiration: @escaping @MainActor () -> Void) {
        begins += 1; self.expiration = expiration; start()
    }
    func update(_ progress: SongMatchingProgress) { }
    func finish(success: Bool) { ends += 1 }
}

/// Records real discovery calls. `blockAt` suspends that song's search until cancelled
/// (or `holdSeconds` elapses); `offline`/`fails` simulate connectivity loss and song failures.
private actor ScriptedDiscovery: ExternalCandidateDiscovery {
    var calls: [Int] = []
    var blockAt: Int?
    var holdSeconds: Double = 60
    var offline: Set<Int> = []
    var fails: Set<Int> = []
    var empty: Set<Int> = []
    init(blockAt: Int? = nil, holdSeconds: Double = 60, offline: Set<Int> = [], fails: Set<Int> = [], empty: Set<Int> = []) {
        self.blockAt = blockAt; self.holdSeconds = holdSeconds; self.offline = offline; self.fails = fails; self.empty = empty
    }
    func heal() { blockAt = nil; offline = []; fails = [] }
    func count() -> Int { calls.count }
    func discover(_ source: PlaylistMigrationSourceTrack) async throws -> MatchingDiscoveryResult {
        calls.append(source.position)
        if source.position == blockAt { try await Task.sleep(for: .seconds(holdSeconds)) }
        if offline.contains(source.position) { throw YouTubeError.networkUnavailable }
        if fails.contains(source.position) {
            return .init(failures: [YouTubeError.searchUnavailable.localizedDescription], failure: .searchUnavailable, searchFailed: true)
        }
        if empty.contains(source.position) { return .init() }
        return .init(recordings: ["a", "b"].map {
            SongRecording(provider: "youtube", identity: String(format: "%010d", source.position) + $0, title: source.title,
                          artist: source.primaryArtist, durationMs: source.durationMs, channel: "Artist")
        })
    }
}

@MainActor final class MatchingPauseResumeTests: XCTestCase {
    private func playlist(_ count: Int, duplicate: (Int, Int)? = nil) -> PlaylistMigrationSourcePlaylist {
        .init(source: .exportify, name: "Pause", entries: (0..<count).map { position in
            let title = duplicate.map { position == $0.1 ? "Track \($0.0)" : "Track \(position)" } ?? "Track \(position)"
            return .init(position: position, title: title, primaryArtist: "Artist", album: "Album", durationMs: 180_000)
        })
    }
    private func waitUntil(_ condition: () async -> Bool) async throws {
        for _ in 0..<500 { if await condition() { return }; try await Task.sleep(for: .milliseconds(10)) }
        XCTFail("Timed out waiting for condition")
    }
    private func model(_ repo: GRDBPlaylistMigrationRepository, _ provider: ScriptedDiscovery, _ execution: ExecutionMock) -> PlaylistMatchingViewModel {
        PlaylistMatchingViewModel(service: .init(repository: repo, providers: [provider], restriction: .noWait), repository: repo, execution: execution)
    }
    private func candidateIDs(_ repo: GRDBPlaylistMigrationRepository, _ entries: ArraySlice<PlaylistMigrationEntry>) async throws -> [UUID: [UUID]] {
        var result: [UUID: [UUID]] = [:]
        for entry in entries { result[entry.id] = try await repo.candidates(entryID: entry.id).map(\.id) }
        return result
    }

    // MARK: A — Pause / Resume

    func testPauseAfterSongFiftyPersistsStopsSearchingSurvivesRestartAndResumesAtNextSong() async throws {
        let f = try LibraryFixture(count: 0), repo = f.storage.playlistMigrations, input = playlist(200)
        let session = try await repo.createPlaylist(from: input, operationID: "pause-50")
        let provider = ScriptedDiscovery(blockAt: 50), execution = ExecutionMock()
        let vm = model(repo, provider, execution)
        vm.start(session.id)
        try await waitUntil { await provider.count() == 51 } // Song 51 (index 50) in flight.
        vm.pause()
        await vm.waitForCompletion()
        try await Task.sleep(for: .milliseconds(50))
        let afterPause = await provider.calls
        XCTAssertEqual(afterPause, Array(0...50), "No new searches start after pause")
        let intent = try await repo.matchingIntent(session.id)
        XCTAssertEqual(intent, "userPaused"); XCTAssertEqual(vm.message, MatchingFailureCategory.userPaused.message)
        var entries = try await repo.entries(migrationID: session.id)
        XCTAssertTrue(entries[..<50].allSatisfy { $0.status == .needsReview }, "Committed work is saved")
        XCTAssertEqual(entries[50].status, .pending, "The interrupted song is unfinished, not reviewed")
        XCTAssertTrue(entries[51...].allSatisfy { $0.status == .pending })
        XCTAssertEqual(execution.begins, execution.ends, "Background execution is released")
        let saved = try await candidateIDs(repo, entries[..<50])

        // Foreground activation never overrides a user pause.
        vm.setForeground(false); vm.setForeground(true); await vm.restoreIfNeeded()
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertFalse(vm.busy); XCTAssertEqual(execution.begins, 1)

        // Survives app restart: a relaunched app does not auto-resume.
        let reopened = try StorageCoordinator(paths: f.paths).playlistMigrations
        try reopened.recover()
        await provider.heal()
        let relaunchExecution = ExecutionMock(), relaunched = model(reopened, provider, relaunchExecution)
        await relaunched.restoreIfNeeded()
        XCTAssertEqual(relaunchExecution.begins, 0)
        let summary = try await reopened.matchingSummary(migrationID: session.id)
        XCTAssertEqual(summary.processed, 50); XCTAssertEqual(summary.remaining, 150)

        // Resume continues at the next eligible unfinished song.
        relaunched.resume(session.id); await relaunched.waitForCompletion()
        let calls = await provider.calls
        XCTAssertEqual(calls, Array(0...50) + Array(50..<200))
        entries = try await reopened.entries(migrationID: session.id)
        XCTAssertEqual(entries.map(\.source), input.entries)
        let kept = try await candidateIDs(reopened, entries[..<50])
        XCTAssertEqual(kept, saved)
        let finalIntent = try await reopened.matchingIntent(session.id)
        XCTAssertEqual(finalIntent, "completed")
    }

    // MARK: B — Background regression

    func testInterruptionDuringSong101ResumesWithoutRepeatingAndProgressNeverRegresses() async throws {
        let f = try LibraryFixture(count: 0), repo = f.storage.playlistMigrations
        let session = try await repo.createPlaylist(from: playlist(200), operationID: "bg-101")
        let provider = ScriptedDiscovery(blockAt: 100), execution = ExecutionMock()
        let vm = model(repo, provider, execution)
        vm.start(session.id)
        try await waitUntil { await provider.count() == 101 }
        vm.setForeground(false); execution.expiration?() // OS expiration while locked.
        await vm.waitForCompletion()
        let intent = try await repo.matchingIntent(session.id)
        XCTAssertEqual(intent, "systemPaused")
        let entries = try await repo.entries(migrationID: session.id)
        let saved = try await candidateIDs(repo, entries[..<100])

        // Reconstruct repository, view model and worker (relaunch after suspension).
        let reopened = try StorageCoordinator(paths: f.paths).playlistMigrations
        try reopened.recover()
        await provider.heal()
        let next = ExecutionMock(), relaunched = model(reopened, provider, next)
        await relaunched.restoreIfNeeded()
        try await waitUntil { relaunched.progress.total > 0 }
        XCTAssertGreaterThanOrEqual(relaunched.progress.processed, 100, "Progress starts from persisted state, not zero")
        await relaunched.waitForCompletion()
        let calls = await provider.calls
        XCTAssertEqual(calls, Array(0...100) + Array(100..<200), "Songs 1–100 are never searched again")
        XCTAssertEqual(next.begins, 1)
        let kept = try await candidateIDs(reopened, entries[..<100])
        XCTAssertEqual(kept, saved)
        let summary = try await reopened.matchingSummary(migrationID: session.id)
        XCTAssertEqual(summary.processed, 200); XCTAssertEqual(relaunched.progress.processed, 200)
    }

    /// Root cause reproduction: connectivity lost while locked used to mark a long run of
    /// songs "failed" (retryable), and every ordinary resume searched them again.
    func testConnectivityLossStopsEarlyAndOrdinaryResumeNeverRepeatsCompletedOrFailedSongs() async throws {
        let f = try LibraryFixture(count: 0), repo = f.storage.playlistMigrations
        let session = try await repo.createPlaylist(from: playlist(200), operationID: "offline")
        let provider = ScriptedDiscovery(offline: Set(31..<100), fails: [5])
        let service = PlaylistMigrationMatchingService(repository: repo, providers: [provider], restriction: .noWait)
        try await service.run(migrationID: session.id, retryFailed: false) { _ in }
        let first = await provider.calls
        XCTAssertEqual(first, Array(0...33), "Three consecutive connectivity failures stop the run")
        let report = await service.lastReport
        XCTAssertTrue(report.waitingForConnection)
        var summary = try await repo.matchingSummary(migrationID: session.id)
        XCTAssertEqual(summary.externalDeferred, 3); XCTAssertEqual(summary.discoveryFailed, 1)
        XCTAssertEqual(summary.remaining, 169, "Unsearched songs stay unfinished")

        await provider.heal()
        try await service.run(migrationID: session.id, retryFailed: false) { _ in }
        let resumed = await provider.calls
        XCTAssertEqual(resumed, Array(0...33) + Array(31..<200), "Resume starts at song 32; no repeats of 1–31")
        try await service.run(migrationID: session.id, retryFailed: true) { _ in }
        let retried = await provider.calls
        XCTAssertEqual(retried, Array(0...33) + Array(31..<200) + [5], "A failed song is retried only on explicit request")
        summary = try await repo.matchingSummary(migrationID: session.id)
        XCTAssertEqual(summary.processed, 200); XCTAssertEqual(summary.remaining, 0); XCTAssertEqual(summary.discoveryFailed, 0)
    }

    // MARK: C — Lifecycle

    func testNoDuplicateWorkersAndForceQuitRecoveryResumesInFlightSongOnce() async throws {
        let f = try LibraryFixture(count: 0), repo = f.storage.playlistMigrations
        let session = try await repo.createPlaylist(from: playlist(10), operationID: "force-quit")
        let provider = ScriptedDiscovery(blockAt: 3), execution = ExecutionMock()
        let vm = model(repo, provider, execution)
        vm.start(session.id); vm.start(session.id)
        try await waitUntil { await provider.count() == 4 }
        await vm.restoreIfNeeded(); vm.setForeground(true)
        XCTAssertEqual(execution.begins, 1, "One authoritative worker")
        vm.cancel(); await vm.waitForCompletion()
        let stopped = await provider.calls
        XCTAssertEqual(stopped, [0, 1, 2, 3], "Cancellation during an in-flight request starts nothing new")

        // Force quit: process dies mid-search; no cleanup runs. Simulate by claiming without finishing.
        try await repo.setMatchingIntent(session.id, intent: "running")
        let lease = try await repo.beginMatching(migrationID: session.id)
        var entries = try await repo.entries(migrationID: session.id)
        _ = try await repo.claimMatchingEntry(entries[3], session: lease, retryFailed: false)
        entries = try await repo.entries(migrationID: session.id)
        XCTAssertEqual(entries[3].status, .matching)

        let reopened = try StorageCoordinator(paths: f.paths).playlistMigrations
        try reopened.recover()
        await provider.heal()
        let before = await provider.count()
        let relaunched = model(reopened, provider, ExecutionMock())
        await relaunched.restoreIfNeeded(); await relaunched.waitForCompletion()
        let calls = await provider.calls
        XCTAssertEqual(Array(calls[before...]), Array(3..<10), "In-flight song resumes once; finished songs are untouched")
    }

    func testStaleWorkerCannotOverwriteNewerResults() async throws {
        let f = try LibraryFixture(count: 0), repo = f.storage.playlistMigrations
        let session = try await repo.createPlaylist(from: playlist(5), operationID: "stale")
        let slow = ScriptedDiscovery(blockAt: 2, holdSeconds: 0.5), fast = ScriptedDiscovery(empty: [2])
        let old = PlaylistMigrationMatchingService(repository: repo, providers: [slow], restriction: .noWait)
        let task = Task { try await old.run(migrationID: session.id) { _ in } }
        for _ in 0..<300 { if await slow.count() == 3 { break }; try await Task.sleep(for: .milliseconds(5)) }
        try await PlaylistMigrationMatchingService(repository: repo, providers: [fast], restriction: .noWait).run(migrationID: session.id) { _ in }
        _ = try? await task.value
        let entries = try await repo.entries(migrationID: session.id)
        let saved = try await repo.candidates(entryID: entries[2].id)
        XCTAssertTrue(saved.isEmpty, "The stale worker's late result was discarded")
        XCTAssertEqual(entries[2].status, .unavailable)
    }

    // MARK: D — Review queue

    func testReviewQueueSelectsAdvancesSkipsGoesBackAndCompletes() async throws {
        let f = try LibraryFixture(count: 0), repo = f.storage.playlistMigrations
        let session = try await repo.createPlaylist(from: playlist(5, duplicate: (1, 4)), operationID: "queue")
        try await PlaylistMigrationMatchingService(repository: repo, providers: [ScriptedDiscovery()], restriction: .noWait).run(migrationID: session.id) { _ in }
        let queue = MigrationReviewQueueModel(repository: repo, migrationID: session.id)
        var opened: [URL] = []
        queue.openURL = { opened.append($0) }
        await queue.load()
        XCTAssertEqual(queue.items.map(\.entry.position), [0, 1, 2, 3, 4], "Original Spotify order")
        XCTAssertEqual(queue.position, 1); XCTAssertEqual(queue.remaining, 5)

        let chosen = try XCTUnwrap(queue.pendingCandidates.first)
        await queue.select(chosen)
        XCTAssertEqual(queue.position, 2, "Advances automatically"); XCTAssertEqual(queue.remaining, 4)
        await queue.skip()
        XCTAssertEqual(queue.position, 3, "Skip moves on without confirming"); XCTAssertEqual(queue.remaining, 4)
        await queue.previous(); await queue.previous()
        XCTAssertEqual(queue.position, 1); XCTAssertEqual(queue.accepted?.id, chosen.id, "Going back keeps the decision")

        // Duplicate occurrences (positions 1 and 4) stay independent.
        await queue.show(4)
        await queue.select(try XCTUnwrap(queue.pendingCandidates.first))
        let duplicate = try await repo.candidates(entryID: queue.items[1].id)
        XCTAssertTrue(duplicate.allSatisfy { $0.decision == .pending })

        while !queue.caughtUp, let candidate = queue.pendingCandidates.first { await queue.select(candidate) }
        XCTAssertTrue(queue.caughtUp); XCTAssertEqual(queue.remaining, 0)
        XCTAssertTrue(opened.isEmpty, "Selecting never opens an external URL")
        let entries = try await repo.entries(migrationID: session.id)
        for entry in entries {
            let accepted = try await repo.candidates(entryID: entry.id).filter { $0.decision == .accepted }
            XCTAssertEqual(accepted.count, 1); XCTAssertEqual(entry.status, .matched)
        }
        queue.preview(chosen)
        XCTAssertEqual(opened.count, 1, "Only the explicit preview opens YouTube")
    }

    // MARK: E — Manual YouTube links

    func testManualLinkConfirmationStaysInAppAdvancesAndRemainsPendingAcquisition() async throws {
        let f = try LibraryFixture(count: 0), repo = f.storage.playlistMigrations
        let session = try await repo.createPlaylist(from: playlist(3), operationID: "manual-queue")
        try await PlaylistMigrationMatchingService(repository: repo, providers: [ScriptedDiscovery(empty: [0])], restriction: .noWait)
            .run(migrationID: session.id) { _ in }
        let queue = MigrationReviewQueueModel(repository: repo, migrationID: session.id)
        var opened: [URL] = []
        queue.openURL = { opened.append($0) }
        await queue.load()
        XCTAssertEqual(queue.current?.entry.position, 0); XCTAssertTrue(queue.pendingCandidates.isEmpty)

        let video = YouTubeVideo(id: "dQw4w9WgXcQ", title: "Artist - Track 0", channel: "Artist",
                                 thumbnailURL: URL(string: "https://i.ytimg.com/vi/dQw4w9WgXcQ/hqdefault.jpg"), duration: 180)
        let lookup = YouTubeManualLookup(metadata: StubMetadata(video: video), transport: YTTransportStub([]))
        let result = try await lookup.lookup("https://www.youtube.com/watch?v=dQw4w9WgXcQ")
        XCTAssertEqual(result.video.title, "Artist - Track 0"); XCTAssertTrue(result.metadataVerified)
        try await queue.confirmManual(result)

        XCTAssertTrue(opened.isEmpty, "Use This Video never opens YouTube or Safari")
        XCTAssertEqual(queue.current?.entry.position, 1, "The next review item appears")
        let entry = try await repo.entry(id: queue.items[0].id)
        XCTAssertEqual(entry.status, .matched); XCTAssertNil(entry.localTrackID)
        XCTAssertEqual(entry.source, playlist(3).entries[0], "Spotify metadata is unchanged")
        let accepted = try await repo.candidates(entryID: entry.id).filter { $0.decision == .accepted }
        XCTAssertEqual(accepted.map(\.providerTrackID), ["dQw4w9WgXcQ"])
        let handoff = try await repo.acquisitionHandoff(migrationID: session.id)
        XCTAssertEqual(handoff.first { $0.occurrenceID == entry.id }?.acquisitionStatus, .awaitingAcquisition)
        let jobs = try await f.storage.database.dbQueue.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM download_jobs") ?? 0 }
        let tracks = try await f.storage.database.dbQueue.read { try StoredTrack.fetchCount($0) }
        XCTAssertEqual(jobs, 0); XCTAssertEqual(tracks, 0)
    }

    // MARK: F — Presentation

    func testConsumerMessagesAreConciseAndFreeOfInternals() {
        let technical = ["invidious: rate limited (HTTP 429) Discovery incomplete; saved candidates are preserved. Retry later.",
                         "External discovery deferred. YouTube requires consent, sign-in or verification. Automatic discovery is paused.",
                         "External discovery deferred. Waiting for an internet connection.",
                         "No suitable recording found. Retry is available.", "searxng: SearXNG returned an unexpected response (HTTP 502)."]
        for message in technical {
            let friendly = try? XCTUnwrap(MatchingUserText.reason(message))
            XCTAssertNotNil(friendly)
            for word in ["HTTP", "invidious", "searxng", "429", "502", "Discovery incomplete"] {
                XCTAssertFalse(friendly?.contains(word) ?? true, "\(word) leaked into: \(friendly ?? "")")
            }
        }
        XCTAssertEqual(MatchingUserText.reason(technical[1]), "Search temporarily unavailable. You can retry later.")
        XCTAssertEqual(MatchingUserText.reason(technical[2]), "Waiting for an internet connection.")
        for category in [MatchingFailureCategory.provider, .interrupted, .userPaused, .offline, .cancelled] {
            XCTAssertFalse(category.message.contains("YouTube discovery") || category.message.contains("HTTP"))
        }
        XCTAssertEqual(MatchingFailureCategory.userPaused.message, "Progress saved. Continue whenever you're ready.")
    }
}

private struct StubMetadata: YouTubeMetadataProvider {
    let video: YouTubeVideo
    func metadata(videoID: String) async throws -> YouTubeVideo { video }
}
