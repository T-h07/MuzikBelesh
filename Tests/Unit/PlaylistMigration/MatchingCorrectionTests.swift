import Foundation
import GRDB
import XCTest
@testable import OFFLINE

actor CorrectionDiscovery: ExternalCandidateDiscovery {
    var calls: [Int] = []
    var malformedAt: Int?
    var errorEvery: Int?
    var suspended = false
    init(malformedAt: Int? = nil, errorEvery: Int? = nil, suspended: Bool = false) {
        self.malformedAt = malformedAt; self.errorEvery = errorEvery; self.suspended = suspended
    }
    func discover(_ source: PlaylistMigrationSourceTrack) async throws -> MatchingDiscoveryResult {
        calls.append(source.position)
        if suspended { try await Task.sleep(for: .seconds(60)) }
        if let errorEvery, source.position % errorEvery == errorEvery - 1 { throw YouTubeError.metadataUnavailable }
        let title = source.position == malformedAt ? "password=do-not-persist" : source.title
        return .init(recordings: [.init(provider: "fixture", identity: String(source.position), title: title,
            artist: source.primaryArtist, album: source.album, durationMs: source.durationMs)])
    }
}
private actor RepositoryChangingDiscovery: ExternalCandidateDiscovery {
    let repository: GRDBPlaylistMigrationRepository
    init(repository: GRDBPlaylistMigrationRepository) { self.repository = repository }
    func discover(_ source: PlaylistMigrationSourceTrack) async throws -> MatchingDiscoveryResult {
        if source.position == 7 { try await repository.updateEntryStatus(entryID: source.id, to: .skipped) }
        try repository.recover()
        return .init(recordings: [.init(provider: "fixture", identity: String(source.position), title: source.title,
            artist: source.primaryArtist, album: source.album, durationMs: source.durationMs)])
    }
}

final class MatchingCorrectionTests: XCTestCase {
    static func source(_ count: Int) -> PlaylistMigrationSourcePlaylist {
        .init(source: .exportify, name: "Correction", entries: (0..<count).map {
            .init(position: $0, title: $0 == 5 ? "Secret (Studio)" : "Song \($0) (Studio)", primaryArtist: "Artist", album: "Album", durationMs: 180000)
        })
    }
    func testReproducesLegacyMetadataAbortWithoutWeakeningCredentialProtection() {
        for title in ["Song One", "Song Two", "Song Three"] { XCTAssertNoThrow(try MigrationPersistentText.validate([title])) }
        XCTAssertThrowsError(try MigrationPersistentText.validate(["Secret (Studio)"])) { error in
            XCTAssertEqual(error as? PlaylistMigrationStorageError, .unsafeDiagnostics)
        }
        XCTAssertEqual(MatchingSafeText.metadata("Secret (Studio)"), "Secret (Studio)")
        XCTAssertNotEqual(MatchingSafeText.metadata("password=private"), "password=private")
        XCTAssertNotEqual(MatchingSafeText.metadata("https://example.com/file?sig=private"), "https://example.com/file?sig=private")
    }
    func testFortyEightSongsContinueAfterMalformedCandidateAndRetrySkipsCommittedProposals() async throws {
        let f = try LibraryFixture(count: 0), repo = f.storage.playlistMigrations, input = Self.source(48)
        let session = try await repo.createPlaylist(from: input, operationID: "48")
        let provider = CorrectionDiscovery(malformedAt: 7)
        let service = PlaylistMigrationMatchingService(repository: repo, providers: [provider])
        try await service.run(migrationID: session.id) { _ in }
        let entries = try await repo.entries(migrationID: session.id), calls = await provider.calls
        XCTAssertEqual(calls, Array(0..<48)); XCTAssertEqual(entries.map(\.source), input.entries)
        XCTAssertEqual(entries[7].status, .failed); XCTAssertEqual(entries[47].status, .needsReview)
        let secret = try await repo.candidates(entryID: entries[5].id)
        XCTAssertEqual(secret.first?.title, "Secret (Studio)")
        let issues = try await repo.issues(migrationID: session.id)
        XCTAssertTrue(issues.contains { $0.entryID == entries[7].id && $0.technicalDetails == "Category: metadata" })
        try await service.run(migrationID: session.id) { _ in }
        let retried = await provider.calls
        XCTAssertEqual(retried, Array(0..<48) + [7])
        let count = try await f.storage.database.dbQueue.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM migration_candidates") }
        XCTAssertEqual(count, 47)
    }
    func testTwoHundredEntriesIsolateIntermittentProviderFailures() async throws {
        let f = try LibraryFixture(count: 0), repo = f.storage.playlistMigrations
        let session = try await repo.createPlaylist(from: Self.source(200), operationID: "200")
        let provider = CorrectionDiscovery(errorEvery: 19)
        try await PlaylistMigrationMatchingService(repository: repo, providers: [provider]).run(migrationID: session.id) { _ in }
        let calls = await provider.calls, entries = try await repo.entries(migrationID: session.id)
        XCTAssertEqual(calls.count, 200); XCTAssertEqual(entries.last?.status, .needsReview)
        XCTAssertTrue(entries.allSatisfy { $0.status != .matching })
    }
    func testConcurrentUserSkipAfterSuccessfulEntriesDoesNotAbortLaterSongs() async throws {
        let f = try LibraryFixture(count: 0), repo = f.storage.playlistMigrations
        let input = Self.source(48), session = try await repo.createPlaylist(from: input, operationID: "concurrent")
        let service = PlaylistMigrationMatchingService(repository: repo, providers: [RepositoryChangingDiscovery(repository: repo)])
        try await service.run(migrationID: session.id) { _ in }
        let entries = try await repo.entries(migrationID: session.id)
        XCTAssertEqual(entries[7].status, .skipped)
        XCTAssertEqual(entries[6].status, .needsReview); XCTAssertEqual(entries[47].status, .needsReview)
        XCTAssertEqual(entries.map(\.source), input.entries)
    }
    func testObservationAndRecoveryDoNotInvalidateLeasesButUserChangesDo() async throws {
        let f = try LibraryFixture(count: 0), repo = f.storage.playlistMigrations
        let session = try await repo.createPlaylist(from: Self.source(1), operationID: "lease")
        let owner = try await repo.beginMatching(migrationID: session.id), entry = try await repo.entries(migrationID: session.id)[0]
        let claimed = try await repo.claimMatchingEntry(entry, session: owner), lease = try XCTUnwrap(claimed)
        try repo.recover()
        _ = try await f.storage.database.dbQueue.read { try LibraryRepository.observedSnapshot($0, paths: f.paths) }
        try await repo.commitMatching(lease, decision: MatchDecisionPolicy().decide([]))
        let current = try await repo.entries(migrationID: session.id)[0]
        XCTAssertEqual(current.status, .unavailable)
    }
    func testFatalDatabaseFailurePropagatesInsteadOfContinuing() async throws {
        let f = try LibraryFixture(count: 0), repo = f.storage.playlistMigrations
        let session = try await repo.createPlaylist(from: Self.source(48), operationID: "fatal")
        try await f.storage.database.dbQueue.write { db in
            try db.execute(sql: "CREATE TRIGGER fail_matching BEFORE INSERT ON migration_candidates BEGIN SELECT RAISE(ABORT, 'synthetic persistence failure'); END")
        }
        let provider = CorrectionDiscovery()
        do { try await PlaylistMigrationMatchingService(repository: repo, providers: [provider]).run(migrationID: session.id) { _ in }; XCTFail("Fatal persistence failure hidden") }
        catch { XCTAssertEqual(MatchingFailureCategory.classify(error), .storageFatal) }
        let calls = await provider.calls
        XCTAssertEqual(calls.count, 1)
    }
}
