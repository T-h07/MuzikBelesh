import XCTest
@testable import OFFLINE

/// Five plausible candidates per song; `delay` slows discovery to overlap with review.
private actor FiveCandidates: ExternalCandidateDiscovery {
    var calls: [Int] = []
    let delay: Duration
    init(delay: Duration = .zero) { self.delay = delay }
    func discover(_ source: PlaylistMigrationSourceTrack) async throws -> MatchingDiscoveryResult {
        calls.append(source.position)
        if delay > .zero { try await Task.sleep(for: delay) }
        return .init(recordings: (0..<5).map {
            SongRecording(provider: "youtube", identity: String(format: "%08d%03d", source.position, $0), title: source.title,
                          artist: source.primaryArtist, durationMs: source.durationMs, channel: "Channel \($0)")
        })
    }
}

private struct MissingCandidate: Error {}

@MainActor final class MatchingReviewQueueTests: XCTestCase {
    /// LibraryFixture deletes its database directory on deinit. Tests discarded it
    /// (`let (_, repo, id)`), so the SQLite file was unlinked while the repository was
    /// still in use ("vnode unlinked while in use" / "disk I/O error"). Keep every
    /// fixture alive until the test, including awaited background work, has finished.
    private var fixtures: [LibraryFixture] = []
    override func tearDown() async throws {
        fixtures.removeAll()
        try await super.tearDown()
    }
    private func playlist(_ count: Int) -> PlaylistMigrationSourcePlaylist {
        .init(source: .exportify, name: "Queue", entries: (0..<count).map {
            .init(position: $0, title: "Track \($0)", primaryArtist: "Artist", album: "Album", durationMs: 180_000)
        })
    }
    private func prepared(_ count: Int, only: Int? = nil) async throws -> (LibraryFixture, GRDBPlaylistMigrationRepository, UUID) {
        let f = try LibraryFixture(count: 0), repo = f.storage.playlistMigrations
        fixtures.append(f)
        let session = try await repo.createPlaylist(from: playlist(count), operationID: "queue-\(count)")
        let entries = try await repo.entries(migrationID: session.id)
        let subset = only.map { Set(entries.prefix($0).map(\.id)) }
        try await PlaylistMigrationMatchingService(repository: repo, providers: [FiveCandidates()], restriction: .noWait)
            .run(migrationID: session.id, only: subset) { _ in }
        // Deterministic discovery: every searched song has exactly five saved candidates.
        for entry in entries.filter({ subset?.contains($0.id) ?? true }) {
            let saved = try await repo.candidates(entryID: entry.id)
            XCTAssertEqual(saved.count, 5, "Song \(entry.position) persisted all discovered candidates")
            XCTAssertEqual(Set(saved.map(\.id)).count, 5, "Candidate IDs are distinct")
        }
        return (f, repo, session.id)
    }
    /// Bounds-checked candidate access, so a failed precondition reports instead of crashing.
    private func candidate(_ queue: MigrationReviewQueueModel, _ index: Int, file: StaticString = #filePath, line: UInt = #line) throws -> PlaylistMigrationCandidate {
        guard queue.pendingCandidates.indices.contains(index) else {
            XCTFail("Expected candidate \(index), found \(queue.pendingCandidates.count)", file: file, line: line)
            throw MissingCandidate()
        }
        return queue.pendingCandidates[index]
    }
    private func accepted(_ repo: GRDBPlaylistMigrationRepository, _ entry: UUID) async throws -> [UUID] {
        try await repo.candidates(entryID: entry).filter { $0.decision == .accepted }.map(\.id)
    }

    func testFirstMiddleAndLastOfFiveCandidatesPersistExactIdentity() async throws {
        let (_, repo, id) = try await prepared(3)
        let queue = MigrationReviewQueueModel(repository: repo, migrationID: id)
        await queue.load()
        XCTAssertEqual(queue.pendingCandidates.count, 5, "Every saved candidate is available, not only three")
        var expected: [UUID: UUID] = [:]
        for pick in [0, 2, 4] { // first, middle, last
            let item = try XCTUnwrap(queue.current)
            let chosen = try candidate(queue, pick)
            expected[item.id] = chosen.id
            await queue.select(chosen)
            XCTAssertNil(queue.error)
        }
        XCTAssertTrue(queue.caughtUp)
        for (entry, candidate) in expected {
            let ids = try await accepted(repo, entry)
            XCTAssertEqual(ids, [candidate], "Exactly the confirmed candidate, and only one")
        }
    }

    func testDoubleSubmissionSavesOnceAndAdvancesOnce() async throws {
        let (_, repo, id) = try await prepared(3)
        let queue = MigrationReviewQueueModel(repository: repo, migrationID: id)
        await queue.load()
        let entry = try XCTUnwrap(queue.current).id
        let first = try candidate(queue, 0), second = try candidate(queue, 3)
        async let a: Void = queue.select(first)
        async let b: Void = queue.select(second)
        _ = await (a, b)
        let ids = try await accepted(repo, entry)
        XCTAssertEqual(ids.count, 1); XCTAssertTrue([first.id, second.id].contains(ids[0]))
        XCTAssertEqual(queue.position, 2, "Advanced exactly once"); XCTAssertFalse(queue.saving)
    }

    func testFailedSaveStaysOnSameSongWithConciseError() async throws {
        let (_, repo, id) = try await prepared(2)
        let queue = MigrationReviewQueueModel(repository: repo, migrationID: id)
        await queue.load()
        let item = try XCTUnwrap(queue.current), chosen = try candidate(queue, 1)
        try await repo.updateEntryStatus(entryID: item.id, to: .skipped) // Changed elsewhere meanwhile.
        await queue.select(chosen)
        XCTAssertEqual(queue.position, 1, "Stays on the same song"); XCTAssertNotNil(queue.error); XCTAssertFalse(queue.saving)
        let ids = try await accepted(repo, item.id)
        XCTAssertTrue(ids.isEmpty)
    }

    func testReviewWhileBackgroundDiscoveryKeepsSearchingLaterSongs() async throws {
        let (_, repo, id) = try await prepared(8, only: 3)
        let slow = FiveCandidates(delay: .milliseconds(80))
        let worker = PlaylistMigrationMatchingService(repository: repo, providers: [slow], restriction: .noWait)
        let background = Task { try await worker.run(migrationID: id, retryFailed: false) { _ in } }
        let queue = MigrationReviewQueueModel(repository: repo, migrationID: id)
        await queue.load()
        XCTAssertEqual(queue.items.map(\.entry.position), [0, 1, 2])
        for pick in [4, 0] {
            let entry = try XCTUnwrap(queue.current).id, chosen = try candidate(queue, pick)
            await queue.select(chosen)
            XCTAssertNil(queue.error, "Selection works while matching updates other songs")
            let ids = try await accepted(repo, entry)
            XCTAssertEqual(ids, [chosen.id])
        }
        try await background.value
        let calls = await slow.calls
        XCTAssertEqual(calls, Array(3..<8), "Background discovery searched only unfinished songs")
        let refreshed = MigrationReviewQueueModel(repository: repo, migrationID: id)
        await refreshed.load()
        XCTAssertEqual(refreshed.items.map(\.entry.position), [2, 3, 4, 5, 6, 7], "Newly discovered songs join the queue; confirmed ones leave")
    }

    func testManualLinkSaveDoesNotAdvanceUntilAskedAndNavigationNeverSelects() async throws {
        let (_, repo, id) = try await prepared(3)
        let queue = MigrationReviewQueueModel(repository: repo, migrationID: id)
        var opened = 0
        queue.openURL = { _ in opened += 1 }
        await queue.load()
        await queue.next(); await queue.previous(); await queue.skip(); await queue.previous()
        for item in queue.items {
            let ids = try await accepted(repo, item.id)
            XCTAssertTrue(ids.isEmpty, "Navigation never confirms")
        }
        let video = YouTubeVideo(id: "dQw4w9WgXcQ", title: "Artist - Track 0", channel: "Artist", duration: 180)
        try await queue.saveManual(YouTubeManualLookupResult(video: video, metadataVerified: true))
        XCTAssertEqual(queue.position, 1, "The view dismisses the keyboard before advancing")
        await queue.advanceAfterResolve()
        XCTAssertEqual(queue.position, 2); XCTAssertEqual(opened, 0)
        let first = try XCTUnwrap(queue.items.first)
        let ids = try await accepted(repo, first.id)
        XCTAssertEqual(ids.count, 1)
    }
}
