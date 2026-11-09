import XCTest
import GRDB
@testable import OFFLINE

final class PlaylistImportPresentationTests: XCTestCase {
    @MainActor func testMalformedReviewAndPreparationCancellationNeverCommit() async throws {
        let f = try LibraryFixture(count: 0)
        let malformed = f.paths.documents.appendingPathComponent("Malformed.csv")
        try Data("Track Name\n\"unterminated".utf8).write(to: malformed)
        let model = PlaylistImportViewModel(storage: f.storage)
        model.presentationOpened(); model.load(malformed)
        await libraryEventually { !model.busy }
        let candidate = try XCTUnwrap(model.report?.candidates.first)
        XCTAssertNil(candidate.source); XCTAssertFalse(candidate.diagnostics.isEmpty)
        XCTAssertFalse(model.canCommit); XCTAssertTrue(model.results.isEmpty)
        let valid = f.paths.documents.appendingPathComponent("Valid.csv")
        try PlaylistImportFixtures.csv(1000).write(to: valid)
        model.load(valid); model.cancel()
        await libraryEventually { !model.busy }
        XCTAssertTrue(model.error?.contains("Reading cancelled") == true)
        XCTAssertNil(model.report); XCTAssertTrue(model.results.isEmpty)
        let sessions = try await f.storage.playlistMigrations.importSessions()
        XCTAssertTrue(sessions.isEmpty)
    }

    @MainActor func testReviewSelectionValidationNamesDuplicatesAndBufferCleanup() async throws {
        let f = try LibraryFixture(count: 0)
        let url = f.paths.documents.appendingPathComponent("Review.json")
        try PlaylistImportFixtures.json([
            PlaylistImportFixtures.playlist(3, name: "First"),
            PlaylistImportFixtures.playlist(0, name: "Empty"),
            ["name": "Invalid", "items": [["episode": ["name": "Unsupported"]]]]
        ]).write(to: url)
        let model = PlaylistImportViewModel(storage: f.storage)
        model.presentationOpened(); model.load(url)
        await libraryEventually { !model.busy }
        let report = try XCTUnwrap(model.report)
        XCTAssertEqual(report.validCount, 2); XCTAssertEqual(report.candidates.count, 3)
        XCTAssertEqual(model.selected.count, 2)
        model.selectAll(false); XCTAssertFalse(model.canCommit)
        model.selectAll(true); XCTAssertEqual(model.selected.count, 2)
        let first = report.candidates[0], empty = report.candidates[1], invalid = report.candidates[2]
        XCTAssertFalse(model.isEligible(invalid))
        model.selected = [invalid.id]; XCTAssertFalse(model.canCommit)
        model.selected = [first.id]; model.names[first.id] = " "
        XCTAssertFalse(model.canCommit)
        model.names[first.id] = "Destination renamed"
        let fingerprint = first.operationID
        XCTAssertTrue(model.canCommit); model.commit()
        await libraryEventually { !model.busy }
        let committed = try XCTUnwrap(model.results[first.id])
        XCTAssertEqual(committed.session.sourcePlaylistName, "First")
        XCTAssertEqual(first.operationID, fingerprint)
        let name = try await f.storage.database.dbQueue.read { try StoredPlaylist.fetchOne($0, key: committed.session.destinationPlaylistID)?.name }
        XCTAssertEqual(name, "Destination renamed")
        XCTAssertNil(model.results[empty.id]); XCTAssertEqual(model.eligible.count, 1)
        model.presentationClosed(); XCTAssertNil(model.report); XCTAssertEqual(model.results.count, 1)
        model.presentationOpened(); model.load(url)
        await libraryEventually { !model.busy }
        let retry = try XCTUnwrap(model.report?.candidates.first)
        XCTAssertEqual(model.duplicate[retry.id], .existing(committed.session.id))
        XCTAssertFalse(model.isEligible(retry)); XCTAssertEqual(model.selected.count, 1)
        model.presentationClosed()
    }

    @MainActor func testConfirmedImportSurvivesDismissalAndPreventsConcurrentCommit() async throws {
        try await exerciseDismissal(cancel: false)
    }
    @MainActor func testAmbiguousIdentityCannotBeSelectedOrCommitted() async throws {
        let f = try LibraryFixture(count: 0)
        let original = f.paths.documents.appendingPathComponent("Original.csv")
        let renamed = f.paths.documents.appendingPathComponent("Renamed.csv")
        let bytes = PlaylistImportFixtures.csv(3)
        try bytes.write(to: original); try bytes.write(to: renamed)
        let model = PlaylistImportViewModel(storage: f.storage)
        model.presentationOpened(); model.load(original)
        await libraryEventually { !model.busy }; model.commit()
        await libraryEventually { !model.busy }
        model.load(renamed); await libraryEventually { !model.busy }
        let candidate = try XCTUnwrap(model.report?.candidates.first)
        XCTAssertEqual(model.duplicate[candidate.id], .ambiguous)
        model.selectAll(true); XCTAssertTrue(model.selected.isEmpty)
        model.selected = [candidate.id]; XCTAssertFalse(model.canCommit)
        model.commit(); XCTAssertFalse(model.busy)
        let sessions = try await f.storage.playlistMigrations.importSessions()
        XCTAssertEqual(sessions.count, 1)
    }
    @MainActor func testExplicitCancelKeepsEarlierTransactionAndReportsPending() async throws {
        try await exerciseDismissal(cancel: true)
    }
    @MainActor private func exerciseDismissal(cancel: Bool) async throws {
        let f = try LibraryFixture(count: 0)
        let url = f.paths.documents.appendingPathComponent("Two.json")
        try PlaylistImportFixtures.json([PlaylistImportFixtures.playlist(1, name: "First"), PlaylistImportFixtures.playlist(1, name: "Second")]).write(to: url)
        let blocked = expectation(description: "Second playlist paused before transaction")
        let gate = PausingImportPersistence(repository: f.storage.playlistMigrations, blocked: blocked)
        let model = PlaylistImportViewModel(storage: f.storage, persistence: gate)
        let library = MusicLibraryService(storage: f.storage, player: nil)
        model.presentationOpened(); model.load(url)
        await libraryEventually { !model.busy }
        XCTAssertTrue(model.canCommit); model.commit()
        let operation = model.operationID
        model.commit(); XCTAssertEqual(model.operationID, operation)
        await fulfillment(of: [blocked], timeout: 10)
        await libraryEventually { library.snapshot.migrationSessions.count == 1 }
        XCTAssertTrue(model.busy); XCTAssertEqual(model.completed, 1); XCTAssertEqual(model.pending, 1)
        model.presentationClosed()
        if cancel { model.cancel() }
        await gate.release()
        await libraryEventually { !model.busy }
        XCTAssertEqual(model.results.count, cancel ? 1 : 2)
        XCTAssertEqual(model.pending, cancel ? 1 : 0)
        XCTAssertEqual(model.error != nil, cancel)
        XCTAssertNil(model.report) // no retained parsed buffers after closing
        await libraryEventually { library.snapshot.migrationSessions.count == (cancel ? 1 : 2) }
    }

    @MainActor func testCommitFailureDoesNotDiscardEarlierPlaylistAndRetryIsSafe() async throws {
        let f = try LibraryFixture(count: 0)
        let url = f.paths.documents.appendingPathComponent("Failure.json")
        try PlaylistImportFixtures.json([PlaylistImportFixtures.playlist(1, name: "First"), PlaylistImportFixtures.playlist(1, name: "Second")]).write(to: url)
        try await f.storage.database.dbQueue.write { db in
            try db.execute(sql: "CREATE TRIGGER reject_second BEFORE INSERT ON playlists WHEN NEW.name = 'Second' BEGIN SELECT RAISE(ABORT, 'injected failure'); END")
        }
        let model = PlaylistImportViewModel(storage: f.storage)
        model.presentationOpened(); model.load(url)
        await libraryEventually { !model.busy }; model.commit()
        await libraryEventually { !model.busy }
        XCTAssertEqual(model.results.count, 1); XCTAssertEqual(model.failed, 1); XCTAssertEqual(model.failures.count, 1)
        XCTAssertEqual(model.selectedCandidates.count, 1)
        try await f.storage.database.dbQueue.write { try $0.execute(sql: "DROP TRIGGER reject_second") }
        model.commit(); await libraryEventually { !model.busy }
        XCTAssertEqual(model.results.count, 2); XCTAssertTrue(model.failures.isEmpty); XCTAssertNil(model.report)
    }
}

/// Only the scheduling boundary is controlled; transactions use the real repository.
private actor PausingImportPersistence: PlaylistImportPersisting {
    let repository: GRDBPlaylistMigrationRepository
    let blocked: XCTestExpectation
    var calls = 0
    var continuation: CheckedContinuation<Void, Never>?
    init(repository: GRDBPlaylistMigrationRepository, blocked: XCTestExpectation) { self.repository = repository; self.blocked = blocked }
    func release() { continuation?.resume(); continuation = nil }
    func createPlaylist(from source: PlaylistMigrationSourcePlaylist, operationID: String, destinationName: String) async throws -> PlaylistMigrationSession {
        calls += 1
        if calls == 2 {
            await withCheckedContinuation { continuation = $0; blocked.fulfill() }
        }
        try Task.checkCancellation()
        return try await repository.createPlaylist(from: source, operationID: operationID, destinationName: destinationName)
    }
    func createPlaylist(from source: PlaylistMigrationSourcePlaylist, operationID: String) async throws -> PlaylistMigrationSession {
        try await createPlaylist(from: source, operationID: operationID, destinationName: source.name)
    }
    func importSessions() async throws -> [PlaylistMigrationSession] { try await repository.importSessions() }
    func session(id: UUID) async throws -> PlaylistMigrationSession? { try await repository.session(id: id) }
    func entries(migrationID: UUID) async throws -> [PlaylistMigrationEntry] { try await repository.entries(migrationID: migrationID) }
    func candidates(entryID: UUID) async throws -> [PlaylistMigrationCandidate] { try await repository.candidates(entryID: entryID) }
    func issues(migrationID: UUID) async throws -> [PlaylistMigrationIssue] { try await repository.issues(migrationID: migrationID) }
    func progress(migrationID: UUID) async throws -> PlaylistMigrationProgress { try await repository.progress(migrationID: migrationID) }
}
