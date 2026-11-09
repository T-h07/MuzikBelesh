import Foundation
import GRDB
import XCTest
@testable import OFFLINE

private actor MatchingMockProvider: ExternalCandidateDiscovery {
    var calls = 0
    let values: [SongRecording]
    let fails: Bool
    init(values: [SongRecording] = [], fails: Bool = false) { self.values = values; self.fails = fails }
    func discover(_ source: PlaylistMigrationSourceTrack) async throws -> MatchingDiscoveryResult {
        calls += 1
        if fails { throw YouTubeError.networkUnavailable }
        return MatchingDiscoveryResult(recordings: values)
    }
}
private actor MatchingSuspendedProvider: ExternalCandidateDiscovery {
    var started = false
    func discover(_ source: PlaylistMigrationSourceTrack) async throws -> MatchingDiscoveryResult {
        started = true
        try await Task.sleep(for: .seconds(30))
        return MatchingDiscoveryResult()
    }
}

final class PlaylistMatchingIntegrationTests: XCTestCase {
    private func localFixture() throws -> LibraryFixture {
        let fixture = try LibraryFixture(count: 1)
        try fixture.storage.database.dbQueue.write { db in
            let now = Date()
            try StoredArtist(id: "artist", name: "Artist A", normalizedName: "artist a", artworkRelativePath: nil, dateAdded: now, dateModified: now).insert(db)
            try StoredAlbum(id: "album", title: "Album", normalizedTitle: "album", artistID: "artist", artworkRelativePath: nil, dateAdded: now, dateModified: now).insert(db)
            var track = try XCTUnwrap(StoredTrack.fetchOne(db, key: fixture.ids[0]))
            track.title = "Song (Studio)"; track.artistID = "artist"; track.albumID = "album"; try track.update(db)
        }
        return fixture
    }
    private func source(_ titles: [String]) -> PlaylistMigrationSourcePlaylist {
        .init(source: .exportify, name: "Matching fixture", entries: titles.enumerated().map {
            .init(position: $0.offset, title: $0.element, primaryArtist: "Artist A", album: "Album", durationMs: 2000, sourceTrackID: $0.element)
        })
    }
    private func create(_ input: PlaylistMigrationSourcePlaylist, _ fixture: LibraryFixture) async throws -> PlaylistMigrationSession {
        try await fixture.storage.playlistMigrations.createPlaylist(from: input, operationID: UUID().uuidString)
    }
    private func count(_ table: String, _ fixture: LibraryFixture) throws -> Int {
        try fixture.storage.database.dbQueue.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM \(table)")! }
    }
    func testVerifiedLocalReuseRepeatedOccurrencesAndPlaybackIsolation() async throws {
        let fixture = try localFixture(), repo = fixture.storage.playlistMigrations
        let input = source(["Song (Studio)", "Other", "Song (Studio)", "Third", "Song (Studio)"])
        let session = try await create(input, fixture), provider = MatchingMockProvider()
        let beforeFiles = try FileManager.default.contentsOfDirectory(atPath: fixture.paths.music.path)
        let service = PlaylistMigrationMatchingService(repository: repo, providers: [provider])
        try await service.run(migrationID: session.id) { _ in }
        let entries = try await repo.entries(migrationID: session.id)
        XCTAssertEqual(entries.map(\.source), input.entries)
        XCTAssertEqual(entries.filter { $0.status == .ready }.map(\.position), [0, 2, 4])
        XCTAssertEqual(Set(entries.compactMap(\.localTrackID)), [fixture.ids[0]])
        let calls = await provider.calls; XCTAssertEqual(calls, 2)
        XCTAssertEqual(try count("tracks", fixture), 1)
        XCTAssertEqual(try count("download_jobs", fixture), 0)
        XCTAssertEqual(try count("playback_queue_entries", fixture), 0)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: fixture.paths.music.path), beforeFiles)
        let candidate = try await repo.candidates(entryID: entries[0].id)
        XCTAssertEqual(candidate.first?.decision, .accepted)
        XCTAssertEqual(candidate.first?.evidence["acceptance"], "Automatic verified local association")
        let reopened = try DatabaseManager(url: fixture.paths.database)
        let again = GRDBPlaylistMigrationRepository(db: reopened.dbQueue, paths: fixture.paths)
        let restored = try await again.entries(migrationID: session.id)
        let restoredCandidates = try await again.candidates(entryID: entries[0].id)
        XCTAssertEqual(restored, entries); XCTAssertEqual(restoredCandidates, candidate)
        XCTAssertEqual(try fixture.foreignKeys(), 0)
    }
    func testCorruptLocalFileNeverSelectsRunnerUp() async throws {
        let fixture = try localFixture(), repo = fixture.storage.playlistMigrations
        var data = try Data(contentsOf: fixture.file(0)); data[data.count - 1] ^= 1
        try data.write(to: fixture.file(0))
        let session = try await create(source(["Song (Studio)"]), fixture), provider = MatchingMockProvider()
        try await PlaylistMigrationMatchingService(repository: repo, providers: [provider]).run(migrationID: session.id) { _ in }
        let entries = try await repo.entries(migrationID: session.id)
        XCTAssertEqual(entries[0].status, .needsReview); XCTAssertNil(entries[0].localTrackID)
        let calls = await provider.calls; XCTAssertEqual(calls, 0)
        let candidates = try await repo.candidates(entryID: entries[0].id)
        XCTAssertTrue(candidates.allSatisfy { $0.decision == .pending })
    }
    func testMissingLocalFileExcludedAndNetworkFailureDoesNotLoseLocalMatches() async throws {
        let fixture = try localFixture(), repo = fixture.storage.playlistMigrations
        let session = try await create(source(["Song (Studio)", "Other", "Another", "Song (Studio)"]), fixture)
        let provider = MatchingMockProvider(fails: true)
        try await PlaylistMigrationMatchingService(repository: repo, providers: [provider]).run(migrationID: session.id) { _ in }
        let entries = try await repo.entries(migrationID: session.id)
        XCTAssertEqual(entries.filter { $0.status == .ready }.count, 2)
        let calls = await provider.calls; XCTAssertEqual(calls, 1)
        try FileManager.default.removeItem(at: fixture.file(0))
        let missing = try await create(source(["Song (Studio)"]), fixture)
        try await PlaylistMigrationMatchingService(repository: repo, providers: []).run(migrationID: missing.id) { _ in }
        let missingEntries = try await repo.entries(migrationID: missing.id)
        XCTAssertNil(missingEntries[0].localTrackID)
    }
    func testExternalRecommendationIdempotentRetryAndExplicitRejection() async throws {
        let fixture = try LibraryFixture(count: 0), repo = fixture.storage.playlistMigrations
        let session = try await create(source(["Song (Studio)"]), fixture)
        let recording = SongRecording(provider: "mock", identity: "recording", title: "Song (Studio)", artist: "Artist A", album: "Album", durationMs: 2000)
        let provider = MatchingMockProvider(values: [recording, recording])
        let service = PlaylistMigrationMatchingService(repository: repo, providers: [provider])
        try await service.run(migrationID: session.id) { _ in }
        let entry = try await repo.entries(migrationID: session.id)[0]
        let first = try await repo.candidates(entryID: entry.id)
        XCTAssertEqual(first.count, 1); XCTAssertEqual(first[0].evidence["outcome"], "recommended")
        XCTAssertNil(entry.localTrackID); XCTAssertEqual(entry.status, .needsReview)
        try await service.run(migrationID: session.id) { _ in }
        let second = try await repo.candidates(entryID: entry.id)
        XCTAssertEqual(second.map(\.id), first.map(\.id))
        try await repo.updateCandidate(id: first[0].id, decision: .rejected)
        try await service.run(migrationID: session.id) { _ in }
        let rejected = try await repo.candidates(entryID: entry.id)
        XCTAssertEqual(rejected.count, 1); XCTAssertEqual(rejected[0].decision, .rejected)
        XCTAssertEqual(try count("tracks", fixture), 0); XCTAssertEqual(try count("download_jobs", fixture), 0)
    }
    func testStaleSessionEntryAndCandidateDecisionCannotCommit() async throws {
        let fixture = try LibraryFixture(count: 0), repo = fixture.storage.playlistMigrations
        let session = try await create(source(["Song (Studio)"]), fixture)
        let owner = try await repo.beginMatching(migrationID: session.id)
        let entry = try await repo.entries(migrationID: session.id)[0]
        let claimed = try await repo.claimMatchingEntry(entry, session: owner)
        let lease = try XCTUnwrap(claimed)
        let decision = MatchDecisionPolicy().decide([])
        _ = try await repo.beginMatching(migrationID: session.id)
        do { try await repo.commitMatching(lease, decision: decision); XCTFail("Stale session committed") }
        catch { XCTAssertTrue(error is SongMatchingError) }
        let owner2 = try await repo.beginMatching(migrationID: session.id)
        let current = try await repo.entries(migrationID: session.id)[0]
        let claimed2 = try await repo.claimMatchingEntry(current, session: owner2)
        let lease2 = try XCTUnwrap(claimed2)
        try await repo.updateEntryStatus(entryID: entry.id, to: .skipped)
        do { try await repo.commitMatching(lease2, decision: decision); XCTFail("User skip overwritten") }
        catch { XCTAssertTrue(error is SongMatchingError) }
        let final = try await repo.entries(migrationID: session.id)[0]
        XCTAssertEqual(final.status, .skipped)
    }
    func testCancellationKeepsCommittedLocalAndResetsActiveEntry() async throws {
        let fixture = try localFixture(), repo = fixture.storage.playlistMigrations
        let session = try await create(source(["Song (Studio)", "Other"]), fixture)
        let provider = MatchingSuspendedProvider()
        let service = PlaylistMigrationMatchingService(repository: repo, providers: [provider])
        let task = Task { try await service.run(migrationID: session.id) { _ in } }
        for _ in 0..<300 {
            let isStarted = await provider.started
            if isStarted { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let started = await provider.started; XCTAssertTrue(started)
        task.cancel()
        do { try await task.value; XCTFail("Expected cancellation") } catch { XCTAssertTrue(error is CancellationError) }
        let entries = try await repo.entries(migrationID: session.id)
        let state = try await repo.session(id: session.id)
        XCTAssertEqual(entries[0].status, .ready); XCTAssertEqual(entries[1].status, .needsReview)
        XCTAssertEqual(state?.status, .paused)
    }
    func testCandidateRejectionAndNewLibraryCompetitorInvalidateAttempt() async throws {
        let fixture = try localFixture(), repo = fixture.storage.playlistMigrations
        let session = try await create(source(["Song (Studio)"]), fixture)
        let owner = try await repo.beginMatching(migrationID: session.id)
        let entry = try await repo.entries(migrationID: session.id)[0]
        let candidate = PlaylistMigrationCandidate(id: UUID(), entryID: entry.id, provider: "local", providerTrackID: fixture.ids[0],
            title: "Song (Studio)", artist: "Artist A", durationMs: 2000, confidence: 1, evidence: [:], decision: .pending)
        try await repo.saveCandidate(candidate)
        let claimed = try await repo.claimMatchingEntry(entry, session: owner), lease = try XCTUnwrap(claimed)
        let index = try await repo.matchingLibrary(), local = try XCTUnwrap(index.recordings[fixture.ids[0]])
        let decision = MatchDecisionPolicy().decide([CandidateScoringEngine().score(source: entry.source, candidate: local.recording)])
        try await repo.updateCandidate(id: candidate.id, decision: .rejected)
        do {
            try await repo.commitMatching(lease, decision: decision, local: local, librarySnapshot: index.snapshot)
            XCTFail("Rejected candidate overwritten")
        } catch { XCTAssertTrue(error is SongMatchingError) }
        let candidates = try await repo.candidates(entryID: entry.id)
        XCTAssertEqual(candidates[0].decision, .rejected)

        let second = try await create(source(["Song (Studio)"]), fixture)
        let owner2 = try await repo.beginMatching(migrationID: second.id)
        let entry2 = try await repo.entries(migrationID: second.id)[0]
        let claim2 = try await repo.claimMatchingEntry(entry2, session: owner2), lease2 = try XCTUnwrap(claim2)
        try fixture.storage.database.dbQueue.write { db in
            var competitor = local.track; competitor.id = "competitor"; competitor.fileRelativePath = "competitor.wav"
            competitor.contentSHA256 = "another-hash"
            try competitor.insert(db)
        }
        do {
            try await repo.commitMatching(lease2, decision: decision, local: local, librarySnapshot: index.snapshot)
            XCTFail("Stale uniqueness accepted")
        } catch { XCTAssertTrue(error is SongMatchingError) }
        let unchanged = try await repo.entries(migrationID: second.id)[0]
        let saved = try await repo.candidates(entryID: entry2.id)
        XCTAssertNil(unchanged.localTrackID); XCTAssertTrue(saved.isEmpty)
    }
    func testUnsafeEvidenceRollsBackCandidateAndEntryTogether() async throws {
        let fixture = try LibraryFixture(count: 0), repo = fixture.storage.playlistMigrations
        let input = source(["Song (Studio)"]), session = try await create(input, fixture)
        let owner = try await repo.beginMatching(migrationID: session.id)
        let entry = try await repo.entries(migrationID: session.id)[0]
        let claim = try await repo.claimMatchingEntry(entry, session: owner), lease = try XCTUnwrap(claim)
        let record = SongRecording(provider: "mock", identity: "one", title: "Song (Studio)", artist: "Artist A")
        let score = SongMatchScore(recording: record, score: 95, gates: [], evidence: ["unsafe": "https://example.com/file?signature=do-not-store"])
        do {
            try await repo.commitMatching(lease, decision: .init(outcome: .recommended, ranked: [score], explanation: "Proposal", margin: 95))
            XCTFail("Unsafe evidence persisted")
        } catch { XCTAssertEqual(error as? PlaylistMigrationStorageError, .unsafeDiagnostics) }
        let unchanged = try await repo.entries(migrationID: session.id)[0], saved = try await repo.candidates(entryID: entry.id)
        XCTAssertEqual(unchanged, lease.entry); XCTAssertTrue(saved.isEmpty)
        XCTAssertEqual(unchanged.source, input.entries[0])
    }
    func testZeroOneFiveHundredAndThousandOccurrencesHaveBoundedCallsAndNoAcquisition() async throws {
        for size in [0, 1, 500, 1000] {
            let fixture = try LibraryFixture(count: 0), repo = fixture.storage.playlistMigrations
            let input = source(Array(repeating: "Song", count: size)), session = try await create(input, fixture)
            let provider = MatchingMockProvider(fails: true)
            try await PlaylistMigrationMatchingService(repository: repo, providers: [provider]).run(migrationID: session.id) { _ in }
            let entries = try await repo.entries(migrationID: session.id)
            let calls = await provider.calls
            XCTAssertEqual(calls, size == 0 ? 0 : 1); XCTAssertEqual(entries.map(\.source), input.entries)
            XCTAssertEqual(try count("tracks", fixture), 0); XCTAssertEqual(try count("download_jobs", fixture), 0)
        }
    }
}
