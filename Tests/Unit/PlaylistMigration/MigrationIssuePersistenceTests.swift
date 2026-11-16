import Foundation
import GRDB
import XCTest
@testable import OFFLINE

/// Phase 10.7 persistence and reconciliation (T10–T17, T39) plus schema compatibility.
@MainActor final class MigrationIssuePersistenceTests: XCTestCase {

    // T10
    func testIssuesSurviveReconstructionWithStableIdentity() async throws {
        let f = try issueFixture()
        let p = try await f.playlist("Persist", count: 3)
        try await f.intent(p.session, "completed")
        try await f.set(p.entries[0], .unavailable); try await f.checkpoint(p.entries[0], "noMatch")
        try await f.set(p.entries[1], .needsReview); try await f.candidates(p.entries[1], 2); try await f.checkpoint(p.entries[1], "review")
        try await f.set(p.entries[2], .failed); try await f.checkpoint(p.entries[2], "provider", retryable: true)
        await f.reconcile()
        let before = try await f.open(p.session)
        XCTAssertEqual(Set(before.map(\.entryID)), Set(p.entries.map(\.id)), "Every unresolved occurrence has one open record")
        XCTAssertEqual(before.first { $0.entryID == p.entries[0].id }?.category, MigrationIssueCategory.noReliableMatch.rawValue)
        XCTAssertEqual(before.first { $0.entryID == p.entries[1].id }?.category, MigrationIssueCategory.ambiguousMatches.rawValue)
        XCTAssertEqual(before.first { $0.entryID == p.entries[2].id }?.category, MigrationIssueCategory.temporaryProviderFailure.rawValue)
        XCTAssertEqual(before.first { $0.entryID == p.entries[2].id }?.stage, .matching)

        // A new database connection and a new coordinator read the same records.
        await f.relaunch()
        let reopened = try DatabaseManager(url: f.fixture.paths.database)
        let stored = try await MigrationIssueRepository(db: reopened.dbQueue, paths: f.fixture.paths).issueRows(migrationID: p.session.id)
        XCTAssertEqual(stored.filter { $0.resolution == .open }.map(\.id).sorted { $0.uuidString < $1.uuidString },
                       before.map(\.id).sorted { $0.uuidString < $1.uuidString })
        await f.reconcile()
        let after = try await f.open(p.session)
        XCTAssertEqual(Set(after.map(\.id)), Set(before.map(\.id)), "Restart never recreates or clears records")
        XCTAssertEqual(f.coordinator.summaries[p.session.id]?.attention, 3)
    }

    // T11
    func testDismissingTheReportOrSummaryChangesNothingDurable() async throws {
        let f = try issueFixture()
        let p = try await f.playlist("Dismiss", count: 2)
        try await f.intent(p.session, "running")
        await f.reconcile()
        XCTAssertFalse(f.coordinator.hasNewCompletion(p.session.id))
        for entry in p.entries { try await f.set(entry, .unavailable); try await f.checkpoint(entry, "noMatch") }
        try await f.intent(p.session, "completed")
        await f.reconcile()
        XCTAssertTrue(f.coordinator.hasNewCompletion(p.session.id), "A settled cycle offers its summary once")
        let rows = try await f.rows(p.session)
        let entries = try await f.repo.entries(migrationID: p.session.id)
        let summary = try XCTUnwrap(f.coordinator.summaries[p.session.id])

        await f.coordinator.dismissCompletion(p.session.id)
        XCTAssertFalse(f.coordinator.hasNewCompletion(p.session.id))
        await f.reconcile()
        let rowsAfter = try await f.rows(p.session)
        let entriesAfter = try await f.repo.entries(migrationID: p.session.id)
        XCTAssertEqual(rowsAfter, rows, "Closing the summary never resolves or deletes issues")
        XCTAssertEqual(entriesAfter, entries)
        XCTAssertEqual(f.coordinator.summaries[p.session.id], summary)
        let intent = try await f.repo.matchingIntent(p.session.id)
        XCTAssertEqual(intent, "completed")

        await f.relaunch(); await f.reconcile()
        XCTAssertFalse(f.coordinator.hasNewCompletion(p.session.id), "Dismissal of this cycle is durable")
        XCTAssertEqual(f.coordinator.summaries[p.session.id]?.attention, 2, "The summary remains available after dismissal")
        let reopenedRows = try await f.rows(p.session)
        XCTAssertEqual(reopenedRows, rows)
    }

    // T12
    func testRepeatedReconciliationNeverDuplicatesOpenIssues() async throws {
        let f = try issueFixture()
        let p = try await f.playlist("Repeat", count: 4)
        try await f.intent(p.session, "completed")
        for entry in p.entries { try await f.set(entry, .unavailable); try await f.checkpoint(entry, "noMatch") }
        await f.reconcile()
        let first = try await f.count("migration_issues")
        XCTAssertEqual(first, 4)
        for _ in 0..<5 { await f.reconcile(); await f.relaunch() }
        let changes = try await f.db.read { $0.totalChangesCount }
        await f.reconcile()
        let unchanged = try await f.db.read { $0.totalChangesCount }
        XCTAssertEqual(unchanged, changes, "An unchanged state writes nothing")
        let count = try await f.count("migration_issues")
        XCTAssertEqual(count, 4)
        // The database itself refuses a second open record for the same occurrence and stage.
        do {
            try await f.db.write { db in
                try db.execute(sql: """
                    INSERT INTO migration_issues (id, migrationID, entryID, code, message, severity, resolution, createdAt, updatedAt)
                    VALUES (?, ?, ?, 'report.matching', 'Duplicate', 'blocking', 'open', ?, ?)
                    """, arguments: [UUID().uuidString, p.session.id.uuidString, p.entries[0].id.uuidString, Date(), Date()])
            }
            XCTFail("A duplicate open issue must violate the unique index")
        } catch let error as DatabaseError {
            XCTAssertEqual(error.resultCode, .SQLITE_CONSTRAINT)
        }
    }

    // T13
    func testDuplicateSpotifySongsKeepSeparateIssueIdentities() async throws {
        let f = try issueFixture()
        let p = try await f.playlist("Twice", count: 3, duplicate: { $0 == 2 ? 0 : nil })
        XCTAssertEqual(p.entries[0].source.title, p.entries[2].source.title)
        XCTAssertEqual(p.entries[0].source.sourceTrackID, p.entries[2].source.sourceTrackID)
        try await f.intent(p.session, "completed")
        for index in [0, 2] { try await f.set(p.entries[index], .unavailable); try await f.checkpoint(p.entries[index], "noMatch") }
        try await f.set(p.entries[1], .ready, track: f.fixture.ids[0])
        await f.reconcile()
        let open = try await f.open(p.session)
        XCTAssertEqual(open.count, 2)
        XCTAssertEqual(Set(open.map(\.entryID)), [p.entries[0].id, p.entries[2].id])
        let report = try await f.report(p.session)
        XCTAssertEqual(report.rows(.failed).map(\.position), [0, 2], "Both occurrences are listed at their own positions")
        XCTAssertEqual(report.summary.attention, 2)
    }

    // T14
    func testCorrectedConditionResolvesTheIssueAndKeepsHistory() async throws {
        let f = try issueFixture()
        let p = try await f.playlist("Fixed", count: 2)
        try await f.intent(p.session, "completed")
        try await f.set(p.entries[0], .unavailable); try await f.checkpoint(p.entries[0], "noMatch")
        try await f.set(p.entries[1], .ready, track: f.fixture.ids[1])
        await f.reconcile()
        let openRows = try await f.open(p.session)
        let opened = try XCTUnwrap(openRows.first)
        try await f.set(p.entries[0], .ready, track: f.fixture.ids[0])
        await f.reconcile()
        let rows = try await f.rows(p.session)
        XCTAssertEqual(rows.count, 1, "History is never deleted")
        let resolved = try XCTUnwrap(rows.first)
        XCTAssertEqual(resolved.id, opened.id)
        XCTAssertEqual(resolved.resolution, .resolved)
        XCTAssertEqual(resolved.closeReason, MigrationIssueCloseReason.conditionCleared.rawValue)
        XCTAssertNotNil(resolved.resolvedAt)
        let report = try await f.report(p.session)
        XCTAssertEqual(report.rows(.resolved).map(\.id), [p.entries[0].id])
        XCTAssertEqual(report.summary.outcome, .fullyReady)
    }

    // T15
    func testChangedFailureCategorySupersedesTheStaleIssue() async throws {
        let f = try issueFixture()
        let p = try await f.playlist("Change", count: 1)
        try await f.intent(p.session, "completed")
        try await f.set(p.entries[0], .failed); try await f.checkpoint(p.entries[0], "provider", retryable: true)
        await f.reconcile()
        let firstRows = try await f.open(p.session)
        let first = try XCTUnwrap(firstRows.first)
        XCTAssertEqual(first.category, MigrationIssueCategory.temporaryProviderFailure.rawValue)
        try await f.set(p.entries[0], .unavailable); try await f.checkpoint(p.entries[0], "noMatch")
        await f.reconcile()
        let rows = try await f.rows(p.session)
        XCTAssertEqual(rows.count, 2)
        let old = try XCTUnwrap(rows.first { $0.id == first.id })
        XCTAssertEqual(old.resolution, .resolved); XCTAssertEqual(old.closeReason, MigrationIssueCloseReason.superseded.rawValue)
        let current = try XCTUnwrap(rows.first { $0.resolution == .open })
        XCTAssertEqual(current.category, MigrationIssueCategory.noReliableMatch.rawValue)
        XCTAssertEqual(current.entryID, p.entries[0].id)
    }

    // T16
    func testUnresolvedEntryWithoutAnyIssueRowIsSurfacedAndPersisted() async throws {
        let f = try issueFixture()
        let p = try await f.playlist("Coverage", count: 3)
        // Older code paths left these unresolved without a Phase 10.7 record.
        try await f.repo.saveIssue(PlaylistMigrationIssue(id: UUID(), migrationID: p.session.id, entryID: p.entries[0].id, code: "matching-attempt",
            message: "Search temporarily unavailable. You can retry later.", technicalDetails: "Category: provider", severity: .warning,
            resolution: .open, createdAt: Date(), resolvedAt: nil))
        try await f.set(p.entries[0], .failed); try await f.checkpoint(p.entries[0], "provider", retryable: true)
        try await f.set(p.entries[1], .pending)
        try await f.set(p.entries[2], .ready, track: f.fixture.ids[2])
        try await f.intent(p.session, "completed")
        let none = try await f.rows(p.session)
        XCTAssertTrue(none.isEmpty)
        await f.reconcile()
        let open = try await f.open(p.session)
        XCTAssertEqual(Set(open.map(\.entryID)), [p.entries[0].id, p.entries[1].id])
        XCTAssertEqual(open.first { $0.entryID == p.entries[1].id }?.category, MigrationIssueCategory.notSearched.rawValue)
        // The legacy matching record is left to its owner, untouched.
        let legacy = try await f.repo.issues(migrationID: p.session.id).filter { $0.code == "matching-attempt" }
        XCTAssertEqual(legacy.count, 1); XCTAssertEqual(legacy.first?.resolution, .open)
        XCTAssertEqual(f.coordinator.summaries[p.session.id]?.unresolved, 2)
    }

    // T17
    func testLateCallbackFromAnOlderAttemptCannotReopenANewerOutcome() async throws {
        let f = try issueFixture()
        let p = try await f.playlist("Stale", count: 1)
        try await f.intent(p.session, "completed")
        try await f.set(p.entries[0], .failed); try await f.checkpoint(p.entries[0], "provider", retryable: true)
        await f.reconcile()
        let issueRows = try await f.open(p.session)
        let issue = try XCTUnwrap(issueRows.first)
        // An older matching attempt claims the song...
        let lease = try await f.repo.beginMatching(migrationID: p.session.id)
        let current = try await f.repo.entry(id: p.entries[0].id)
        let claimed = try await f.repo.claimMatchingEntry(current, session: lease, retryFailed: true)
        let claim = try XCTUnwrap(claimed)
        // ...the user confirms a library recording meanwhile...
        let inFlight = try await f.repo.entry(id: p.entries[0].id)
        try await f.repo.confirmLocalRecording(for: inFlight, trackID: f.fixture.ids[0])
        await f.reconcile()
        // ...and the old attempt's failure arrives late.
        try await f.repo.recordMatchingFailure(claim, category: .provider)
        await f.reconcile(); await f.reconcile()
        let entry = try await f.repo.entry(id: p.entries[0].id)
        XCTAssertEqual(entry.status, .ready); XCTAssertEqual(entry.localTrackID, f.fixture.ids[0])
        let rows = try await f.rows(p.session)
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows.first?.id, issue.id)
        XCTAssertEqual(rows.first?.resolution, .resolved, "The stale failure never reopens the resolved issue")
        let report = try await f.report(p.session)
        XCTAssertEqual(report.occurrence(p.entries[0].id)?.assessment.disposition, .playable)
    }

    // T39
    func testThousandEntryReportIsIndexedStableAndQuietWhenUnchanged() async throws {
        let f = try issueFixture()
        let p = try await f.playlist("Large", count: 1000)
        try await f.intent(p.session, "completed")
        try await f.db.write { db in
            try db.execute(sql: """
                UPDATE migration_entries SET status = CASE sourcePosition % 4 WHEN 0 THEN 'unavailable' WHEN 1 THEN 'needsReview'
                    WHEN 2 THEN 'failed' ELSE 'skipped' END WHERE migrationID = ?
                """, arguments: [p.session.id.uuidString])
            for entry in p.entries where entry.position % 4 != 3 {
                let outcome = entry.position % 4 == 0 ? "noMatch" : entry.position % 4 == 1 ? "review" : "provider"
                try MatchingCheckpoint(entryID: entry.id.uuidString, algorithm: CandidateScoringEngine.algorithmVersion, retryable: entry.position % 4 == 2,
                                       outcome: outcome, updatedAt: Date()).save(db)
            }
        }
        let started = Date()
        await f.reconcile()
        let elapsed = Date().timeIntervalSince(started)
        XCTAssertLessThan(elapsed, 30, "One indexed pass over 1,000 occurrences")
        let report = try XCTUnwrap(f.coordinator.reports[p.session.id])
        XCTAssertEqual(report.occurrences.map(\.position), Array(0..<1000), "Rows keep source order")
        XCTAssertEqual(Set(report.occurrences.map(\.id)).count, 1000, "Stable, unique identities")
        XCTAssertEqual(report.summary.total, 1000)
        XCTAssertTrue(report.summary.accountedFor)
        XCTAssertEqual(report.summary.skipped, 250)
        let open = try await f.open(p.session)
        XCTAssertEqual(open.count, 750)
        let changes = try await f.db.read { $0.totalChangesCount }
        await f.reconcile()
        let after = try await f.db.read { $0.totalChangesCount }
        XCTAssertEqual(after, changes, "Re-observation of 1,000 unchanged rows writes nothing")
        // The per-migration issue queries are served by indexes, not table scans.
        let plan = try await f.db.read { db in
            try Row.fetchAll(db, sql: "EXPLAIN QUERY PLAN SELECT * FROM migration_issues WHERE migrationID = ? AND resolution = 'open' AND code = 'report.matching'",
                             arguments: [p.session.id.uuidString]).map { $0["detail"] as String }.joined(separator: " ")
        }
        XCTAssertTrue(plan.contains("USING INDEX") || plan.contains("USING COVERING INDEX"), plan)
    }

    // Schema compatibility
    func testUpgradeFromV018PreservesExistingIssueHistory() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = try AppStoragePaths(root: root)
        let old = try DatabaseManager(url: paths.database, migrationTarget: CoordinatorSchema.version)
        let legacy = GRDBPlaylistMigrationRepository(db: old.dbQueue, paths: paths)
        let source = PlaylistMigrationSourcePlaylist(source: .exportify, name: "Upgrade", entries: (0..<3).map {
            PlaylistMigrationSourceTrack(position: $0, title: "Upgrade \($0)", primaryArtist: "Artist", durationMs: 2000)
        })
        let session = try legacy.createCommittedPlaylist(from: source, operationID: "upgrade-v018")
        let entries = try await legacy.entries(migrationID: session.id)
        var ids: [UUID] = []
        for (index, entry) in entries.enumerated() {
            let id = UUID(); ids.append(id)
            try await legacy.saveIssue(PlaylistMigrationIssue(id: id, migrationID: session.id, entryID: entry.id, code: "matching-attempt",
                message: "Legacy message \(index)", technicalDetails: nil, severity: .warning, resolution: .open, createdAt: Date(), resolvedAt: nil))
        }
        try await legacy.resolveIssue(id: ids[1], resolution: .resolved)
        try await legacy.resolveIssue(id: ids[2], resolution: .dismissed)
        let before = try await legacy.issues(migrationID: session.id)

        let upgraded = try DatabaseManager(url: paths.database)
        let after = try await GRDBPlaylistMigrationRepository(db: upgraded.dbQueue, paths: paths).issues(migrationID: session.id)
        XCTAssertEqual(after, before, "Existing open, resolved and dismissed history is preserved")
        let migrations = try await upgraded.dbQueue.read { try String.fetchAll($0, sql: "SELECT identifier FROM grdb_migrations ORDER BY identifier") }
        XCTAssertTrue(migrations.contains(MigrationIssueSchema.version)); XCTAssertEqual(migrations.last, ReplacementSchema.version)
        let unset: Int = try await upgraded.dbQueue.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM migration_issues WHERE category IS NULL AND stage IS NULL AND closeReason IS NULL") ?? 0
        }
        XCTAssertEqual(unset, 3, "Pre-existing rows get NULL for the new columns")
        let fk = try await upgraded.dbQueue.read { try Row.fetchAll($0, sql: "PRAGMA foreign_key_check").count }
        XCTAssertEqual(fk, 0)
        // The upgraded store reconciles normally, without touching legacy rows.
        let reconciled = try await MigrationIssueRepository(db: upgraded.dbQueue, paths: paths).reconcile(migrationID: session.id, now: Date(), capacity: nil)
        XCTAssertEqual(reconciled?.report.summary.total, 3)
        let legacyAfter = try await GRDBPlaylistMigrationRepository(db: upgraded.dbQueue, paths: paths).issues(migrationID: session.id).filter { $0.code == "matching-attempt" }
        XCTAssertEqual(legacyAfter, before)
    }
}
