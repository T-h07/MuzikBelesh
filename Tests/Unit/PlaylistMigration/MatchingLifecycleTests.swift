import XCTest
import GRDB
@testable import OFFLINE

@MainActor private final class MatchingExecutionMock: MatchingBackgroundExecuting {
    var begins = 0
    var ends = 0
    var expiration: (@MainActor () -> Void)?
    var pendingStart: (@MainActor () -> Void)?
    var delayLaunch = false
    func begin(start: @escaping @MainActor () -> Void, expiration: @escaping @MainActor () -> Void) {
        begins += 1; self.expiration = expiration
        if delayLaunch { pendingStart = start } else { start() }
    }
    func update(_ progress: SongMatchingProgress) { }
    func finish(success: Bool) { ends += 1; pendingStart = nil }
}

@MainActor final class MatchingLifecycleTests: XCTestCase {
    func testBackgroundAndLockDoNotCancelAndForegroundDoesNotDuplicateWorker() async throws {
        let f = try LibraryFixture(count: 0), repo = f.storage.playlistMigrations
        let session = try await repo.createPlaylist(from: MatchingCorrectionTests.source(48), operationID: "background")
        let provider = CorrectionDiscovery(suspended: true), execution = MatchingExecutionMock()
        let service = PlaylistMigrationMatchingService(repository: repo, providers: [provider])
        let model = PlaylistMatchingViewModel(service: service, repository: repo, execution: execution)
        model.start(session.id)
        for _ in 0..<200 { let count = await provider.calls.count; if count > 0 { break }; try await Task.sleep(for: .milliseconds(10)) }
        model.setForeground(false) // application switch / screen lock
        XCTAssertTrue(model.busy)
        model.setForeground(true); await model.restoreIfNeeded()
        XCTAssertEqual(execution.begins, 1)
        model.cancel(); await model.waitForCompletion()
        let remaining = try await repo.resumableMatchingJobs()
        XCTAssertTrue(remaining.isEmpty); XCTAssertEqual(model.message, MatchingFailureCategory.cancelled.message)
    }
    func testExpirationAndManualReopenRestoreIntentAndSkipCheckpoints() async throws {
        let f = try LibraryFixture(count: 0), repo = f.storage.playlistMigrations
        let session = try await repo.createPlaylist(from: MatchingCorrectionTests.source(1), operationID: "expire")
        let provider = CorrectionDiscovery(suspended: true), execution = MatchingExecutionMock()
        let model = PlaylistMatchingViewModel(service: .init(repository: repo, providers: [provider]), repository: repo, execution: execution)
        model.start(session.id)
        for _ in 0..<200 { let count = await provider.calls.count; if count > 0 { break }; try await Task.sleep(for: .milliseconds(10)) }
        model.setForeground(false); execution.expiration?(); await model.waitForCompletion()
        let jobs = try await repo.resumableMatchingJobs()
        XCTAssertEqual(jobs, [session.id]); XCTAssertEqual(model.message, MatchingFailureCategory.interrupted.message)
        let reopenedExecution = MatchingExecutionMock(), resumedProvider = CorrectionDiscovery()
        let reopened = PlaylistMatchingViewModel(service: .init(repository: repo, providers: [resumedProvider]), repository: repo, execution: reopenedExecution)
        await reopened.restoreIfNeeded(); await reopened.waitForCompletion()
        let finished = try await repo.resumableMatchingJobs()
        XCTAssertTrue(finished.isEmpty); XCTAssertEqual(reopenedExecution.begins, 1)
    }
    func testForceQuitIntentRestoresOnlyOnManualLaunchAndPendingRequestCanBeCancelled() async throws {
        let f = try LibraryFixture(count: 0), repo = f.storage.playlistMigrations
        let session = try await repo.createPlaylist(from: MatchingCorrectionTests.source(1), operationID: "force-quit")
        try await repo.setMatchingIntent(session.id, intent: "running") // durable state left by process termination
        let execution = MatchingExecutionMock(); execution.delayLaunch = true
        let model = PlaylistMatchingViewModel(service: .init(repository: repo, providers: []), repository: repo, execution: execution)
        await model.restoreIfNeeded()
        for _ in 0..<200 { if execution.pendingStart != nil { break }; try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertNotNil(execution.pendingStart)
        model.cancel(); await model.waitForCompletion()
        let jobs = try await repo.resumableMatchingJobs()
        XCTAssertTrue(jobs.isEmpty); XCTAssertNil(execution.pendingStart)
    }
    func testPendingCancellationPersistenceFailureClearsBusyAndReportsStorageFailure() async throws {
        let f = try LibraryFixture(count: 0), repo = f.storage.playlistMigrations
        let session = try await repo.createPlaylist(from: MatchingCorrectionTests.source(1), operationID: "cancel-write-failure")
        let execution = MatchingExecutionMock(); execution.delayLaunch = true
        let model = PlaylistMatchingViewModel(service: .init(repository: repo, providers: []), repository: repo, execution: execution)
        model.start(session.id)
        for _ in 0..<200 { if execution.pendingStart != nil { break }; try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertNotNil(execution.pendingStart)
        try await f.storage.database.dbQueue.write { db in
            try db.execute(sql: "CREATE TRIGGER fail_stop BEFORE UPDATE ON migration_matching_jobs WHEN NEW.intent = 'userCancelled' BEGIN SELECT RAISE(ABORT, 'synthetic stop failure'); END")
        }
        model.cancel(); await model.waitForCompletion()
        XCTAssertFalse(model.busy); XCTAssertNil(execution.pendingStart)
        XCTAssertEqual(model.message, MatchingFailureCategory.storageFatal.message)
    }
}
