import XCTest
@testable import OFFLINE

/// Two plausible YouTube candidates per occurrence; optional individual failure
/// and optional provider-wide verification at a fixed position.
private actor CompletionDiscovery: ExternalCandidateDiscovery {
    var calls: [Int] = []
    var failAt: Set<Int>
    var verifyAt: Int?
    init(failAt: Set<Int> = [], verifyAt: Int? = nil) { self.failAt = failAt; self.verifyAt = verifyAt }
    func heal() { verifyAt = nil; failAt = [] }
    static func id(_ position: Int, _ suffix: String) -> String { String(format: "%010d", position) + suffix }
    func discover(_ source: PlaylistMigrationSourceTrack) async throws -> MatchingDiscoveryResult {
        calls.append(source.position)
        if source.position == verifyAt { throw YouTubeError.providerRestricted }
        if failAt.contains(source.position) {
            return .init(failures: [YouTubeError.searchUnavailable.localizedDescription], failure: .searchUnavailable, searchFailed: true)
        }
        return .init(recordings: ["a", "b"].map {
            SongRecording(provider: "youtube", identity: Self.id(source.position, $0), title: source.title, artist: source.primaryArtist,
                          durationMs: source.durationMs, fullTitle: "Artist - " + source.title + ($0 == "b" ? " (Live)" : ""), channel: "Uploader",
                          thumbnailURL: URL(string: "https://i.ytimg.com/vi/\(Self.id(source.position, $0))/hqdefault.jpg"))
        })
    }
}

final class MatchingCompletionTests: XCTestCase {
    private func source(_ count: Int, duplicateAt: Int? = nil) -> PlaylistMigrationSourcePlaylist {
        .init(source: .exportify, name: "Completion", entries: (0..<count).map { position in
            let title = position == 120 ? "Song 1" : position == duplicateAt ? "Track 0" : "Track \(position)"
            return .init(position: position, title: title, primaryArtist: "Artist", album: "Album", durationMs: 180_000)
        })
    }
    private func run(_ repo: GRDBPlaylistMigrationRepository, _ id: UUID, _ provider: CompletionDiscovery, only: Set<UUID>? = nil) async throws {
        try await PlaylistMigrationMatchingService(repository: repo, providers: [provider]).run(migrationID: id, only: only) { _ in }
    }

    func testIndividualFailureAtSongTenDoesNotStopSongsElevenThroughTwoHundred() async throws {
        let f = try LibraryFixture(count: 0), repo = f.storage.playlistMigrations
        let session = try await repo.createPlaylist(from: source(200), operationID: "fail-10")
        let provider = CompletionDiscovery(failAt: [10])
        try await run(repo, session.id, provider)
        let calls = await provider.calls, summary = try await repo.matchingSummary(migrationID: session.id)
        XCTAssertEqual(calls, Array(0..<200))
        XCTAssertEqual(summary.processed, 200); XCTAssertEqual(summary.discoveryFailed, 1)
        XCTAssertEqual(summary.externalDeferred, 0); XCTAssertEqual(summary.noMatch, 0); XCTAssertFalse(summary.discoveryPaused)
        let overview = try await repo.resolutionOverview(migrationID: session.id)
        XCTAssertEqual(overview.items.first { $0.entry.position == 10 }?.category, .discoveryFailed)
        XCTAssertNotNil(overview.items.first { $0.entry.position == 10 }?.reason)
        XCTAssertEqual(overview.count(.needsReview), 199)
    }

    func testVerificationAtEntryThirtyEightSuspendsProviderButVisitsAllAndResumesWithoutDuplicates() async throws {
        let f = try LibraryFixture(count: 2), repo = f.storage.playlistMigrations, input = source(200)
        let tracksBefore = try await f.storage.database.dbQueue.read { try StoredTrack.fetchCount($0) }
        let session = try await repo.createPlaylist(from: input, operationID: "verify-38")
        let provider = CompletionDiscovery(verifyAt: 38)
        try await run(repo, session.id, provider)

        let firstCalls = await provider.calls
        XCTAssertEqual(firstCalls, Array(0...38), "No requests to a suspended provider")
        let summary = try await repo.matchingSummary(migrationID: session.id)
        XCTAssertEqual(summary.processed, 200); XCTAssertEqual(summary.deferred, 0)
        XCTAssertEqual(summary.externalAttempted, 39); XCTAssertEqual(summary.externalDeferred, 161)
        XCTAssertEqual(summary.discoveryFailed, 1); XCTAssertEqual(summary.noMatch, 0); XCTAssertTrue(summary.discoveryPaused)

        // Local matching still ran after suspension.
        var entries = try await repo.entries(migrationID: session.id)
        let local = try await repo.candidates(entryID: entries[120].id)
        XCTAssertTrue(entries[120].status == .ready || local.contains { $0.provider == "local" })

        // Every deferred occurrence is individually identifiable and retryable.
        let overview = try await repo.resolutionOverview(migrationID: session.id)
        let deferred = overview.items.filter { $0.category == .discoveryDeferred }
        XCTAssertEqual(deferred.map(\.entry.position), Array(39..<200))
        XCTAssertEqual(Set(deferred.map(\.id)).count, 161)
        XCTAssertTrue(deferred.allSatisfy { $0.reason?.hasPrefix("External discovery deferred.") == true })

        // Saved candidates survive restart; resume searches only unfinished entries.
        let saved = try await repo.candidates(entryID: entries[5].id)
        let reopened = try StorageCoordinator(paths: f.paths).playlistMigrations
        try reopened.recover()
        let restored = try await reopened.candidates(entryID: entries[5].id)
        XCTAssertEqual(restored, saved); XCTAssertEqual(saved.count, 2)
        await provider.heal()
        try await run(reopened, session.id, provider)
        let calls = await provider.calls
        XCTAssertEqual(calls, Array(0...38) + Array(38..<200), "Completed searches are never repeated")
        let finished = try await reopened.matchingSummary(migrationID: session.id)
        XCTAssertEqual(finished.externalDeferred, 0); XCTAssertEqual(finished.discoveryFailed, 0)
        let kept = try await reopened.candidates(entryID: entries[5].id)
        XCTAssertEqual(kept, saved)
        entries = try await reopened.entries(migrationID: session.id)
        XCTAssertEqual(entries.map(\.source), input.entries)
        let tracksAfter = try await f.storage.database.dbQueue.read { try StoredTrack.fetchCount($0) }
        XCTAssertEqual(tracksAfter, tracksBefore)
    }

    func testSelectingSavedCandidateRejectReplaceAndSingleAcceptance() async throws {
        let f = try LibraryFixture(count: 0), repo = f.storage.playlistMigrations
        let session = try await repo.createPlaylist(from: source(3), operationID: "select")
        try await run(repo, session.id, CompletionDiscovery())
        var entry = try await repo.entries(migrationID: session.id)[1]
        XCTAssertEqual(entry.status, .needsReview)
        let saved = try await repo.candidates(entryID: entry.id)
        let first = try XCTUnwrap(saved.first { $0.providerTrackID == CompletionDiscovery.id(1, "a") })
        let second = try XCTUnwrap(saved.first { $0.providerTrackID == CompletionDiscovery.id(1, "b") })

        let accepted = try await repo.selectCandidate(for: entry, candidateID: first.id)
        XCTAssertEqual(accepted.id, first.id); XCTAssertEqual(accepted.decision, .accepted)
        XCTAssertEqual(accepted.evidence["selectionMethod"], "reviewed-candidate")
        entry = try await repo.entries(migrationID: session.id)[1]
        XCTAssertEqual(entry.status, .matched); XCTAssertNil(entry.localTrackID)

        // A second acceptance is impossible while one exists.
        do { try await repo.selectCandidate(for: entry, candidateID: second.id); XCTFail("Second acceptance allowed") }
        catch { XCTAssertNotNil(error as? SongMatchingError) }
        var rows = try await repo.candidates(entryID: entry.id)
        XCTAssertEqual(rows.filter { $0.decision == .accepted }.map(\.id), [first.id])

        // Handoff exposes exactly one awaiting-acquisition selection.
        let handoff = try await repo.acquisitionHandoff(migrationID: session.id)
        XCTAssertEqual(handoff.map(\.occurrenceID), [entry.id])
        XCTAssertEqual(handoff.first?.acquisitionStatus, .awaitingAcquisition); XCTAssertEqual(handoff.first?.userConfirmed, true)
        XCTAssertEqual(handoff.first?.canonicalURL?.absoluteString, "https://www.youtube.com/watch?v=" + CompletionDiscovery.id(1, "a"))
        XCTAssertEqual(handoff.first?.source, entry.source); XCTAssertNil(handoff.first?.localTrackID)

        // Reject and replace.
        try await repo.rejectCandidate(entryID: entry.id, candidateID: first.id)
        entry = try await repo.entries(migrationID: session.id)[1]
        XCTAssertEqual(entry.status, .needsReview)
        try await repo.selectCandidate(for: entry, candidateID: second.id)
        rows = try await repo.candidates(entryID: entry.id)
        XCTAssertEqual(rows.first { $0.id == first.id }?.decision, .rejected)
        XCTAssertEqual(rows.filter { $0.decision == .accepted }.map(\.id), [second.id])

        // Rediscovery never re-proposes or reopens decisions.
        let reopened = try await repo.entries(migrationID: session.id)[0]
        try await repo.rejectCandidate(entryID: reopened.id, candidateID: try await repo.candidates(entryID: reopened.id)[0].id)
        let rejected = try await repo.candidates(entryID: reopened.id).filter { $0.decision == .rejected }.count
        XCTAssertEqual(rejected, 1)
    }

    func testDuplicateOccurrencesResolveIndependentlyAndCountsAreAccurate() async throws {
        let f = try LibraryFixture(count: 0), repo = f.storage.playlistMigrations
        let session = try await repo.createPlaylist(from: source(4, duplicateAt: 3), operationID: "dupes")
        try await run(repo, session.id, CompletionDiscovery(failAt: [2]))
        let entries = try await repo.entries(migrationID: session.id)
        XCTAssertEqual(entries[0].source.title, entries[3].source.title); XCTAssertNotEqual(entries[0].id, entries[3].id)
        let candidate = try await repo.candidates(entryID: entries[0].id)[0]
        try await repo.selectCandidate(for: entries[0], candidateID: candidate.id)
        let duplicate = try await repo.candidates(entryID: entries[3].id)
        XCTAssertTrue(duplicate.allSatisfy { $0.decision == .pending })
        let overview = try await repo.resolutionOverview(migrationID: session.id)
        XCTAssertEqual(overview.summary, "Resolved 1/4 — 2 Need Review — 1 Unresolved")
        let progress = try await repo.matchingSummary(migrationID: session.id)
        XCTAssertEqual(progress.resolved, 1); XCTAssertEqual(progress.selected, 1)
        XCTAssertEqual(progress.alreadyLocal + progress.localMatches, 0)
    }

    func testRetryThisSongRetriesOnlyThatOccurrence() async throws {
        let f = try LibraryFixture(count: 0), repo = f.storage.playlistMigrations
        let session = try await repo.createPlaylist(from: source(20), operationID: "retry-one")
        let provider = CompletionDiscovery(failAt: [4, 9])
        try await run(repo, session.id, provider)
        await provider.heal()
        let entries = try await repo.entries(migrationID: session.id)
        let before = try await repo.candidates(entryID: entries[0].id)
        try await repo.markRetryable(entryID: entries[9].id)
        try await run(repo, session.id, provider, only: [entries[9].id])
        let calls = await provider.calls
        XCTAssertEqual(calls, Array(0..<20) + [9])
        let after = try await repo.entries(migrationID: session.id)
        XCTAssertEqual(after[9].status, .needsReview); XCTAssertEqual(after[4].status, .failed)
        let kept = try await repo.candidates(entryID: entries[0].id)
        XCTAssertEqual(kept, before)
    }
}
