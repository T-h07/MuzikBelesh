import Foundation
import GRDB
import XCTest
@testable import OFFLINE

/// Phase 10.7 completion summaries (T26–T31) and the offline-library regression (T42).
@MainActor final class MigrationCompletionSummaryTests: XCTestCase {

    // T26
    func testFullyPlayablePlaylistReportsExactSuccess() async throws {
        let f = try issueFixture()
        let p = try await f.playlist("Done", count: 3)
        try await f.intent(p.session, "completed")
        for (index, entry) in p.entries.enumerated() { try await f.set(entry, .ready, track: f.fixture.ids[index % 2]) }
        let summary = try await f.report(p.session).summary
        XCTAssertEqual(summary.outcome, .fullyReady)
        XCTAssertEqual(summary.total, 3); XCTAssertEqual(summary.playable, 3)
        XCTAssertEqual(summary.unresolved, 0); XCTAssertEqual(summary.skipped, 0)
        XCTAssertTrue(summary.accountedFor)
        XCTAssertEqual(summary.sentence, "All 3 songs are available offline.")
    }

    // T27
    func testUnresolvedOrSkippedSongsPreventFullSuccess() async throws {
        let f = try issueFixture()
        let p = try await f.playlist("Partial", count: 4)
        try await f.intent(p.session, "completed")
        try await f.set(p.entries[0], .ready, track: f.fixture.ids[0])
        try await f.set(p.entries[1], .ready, track: f.fixture.ids[1])
        try await f.set(p.entries[2], .unavailable); try await f.checkpoint(p.entries[2], "noMatch")
        try await f.set(p.entries[3], .skipped)
        let summary = try await f.report(p.session).summary
        XCTAssertEqual(summary.outcome, .finishedWithIssues)
        XCTAssertFalse(summary.fullyReady)
        XCTAssertEqual(summary.playable, 2); XCTAssertEqual(summary.unresolved, 1); XCTAssertEqual(summary.skipped, 1)
        XCTAssertEqual(summary.sentence, "2 of 4 songs are playable offline. 1 needs attention and 1 was skipped.")
        XCTAssertEqual(summary.outcome.title, "Processing Finished — Needs Attention")
        // Every other song playable, one skipped: still not "ready".
        try await f.set(p.entries[2], .ready, track: f.fixture.ids[2])
        let skippedOnly = try await f.report(p.session).summary
        XCTAssertEqual(skippedOnly.outcome, .finishedWithIssues)
        XCTAssertEqual(skippedOnly.skipped, 1)
    }

    // T28
    func testPausedWaitingOrRetryingMigrationIsNeverReportedFinished() async throws {
        let f = try issueFixture()
        let p = try await f.playlist("Active", count: 3)
        try await f.set(p.entries[0], .ready, track: f.fixture.ids[0])
        try await f.set(p.entries[1], .unavailable); try await f.checkpoint(p.entries[1], "noMatch")
        var summary = try await f.report(p.session).summary
        XCTAssertFalse(summary.outcome.settled, "Never-started matching is not finished")

        try await f.intent(p.session, "running")
        summary = try await f.report(p.session).summary
        XCTAssertEqual(summary.outcome, .inProgress)
        XCTAssertEqual(summary.waiting, 1)

        try await f.intent(p.session, "userPaused")
        summary = try await f.report(p.session).summary
        XCTAssertEqual(summary.outcome, .paused)

        // Matching finished, but an ordinary automatic retry is still scheduled.
        try await f.intent(p.session, "completed")
        try await f.set(p.entries[2], .failed); try await f.checkpoint(p.entries[2], "provider", retryable: true)
        try await f.retryRecord(p.entries[2], failures: 1, eligible: true, next: f.clock.now.addingTimeInterval(60))
        summary = try await f.report(p.session).summary
        XCTAssertEqual(summary.outcome, .inProgress, "A scheduled retry is not a finished migration")
        XCTAssertEqual(summary.waiting, 1); XCTAssertEqual(summary.failed, 1)

        // Downloads paused by the user while a confirmed song waits.
        try await f.db.write { db in _ = try EntryRetryRecord.deleteAll(db) }
        try await f.set(p.entries[2], .matched)
        try await f.link(p.entries[2], .waiting, jobState: .queued)
        try await f.db.write { db in
            try AcquisitionControlRecord(migrationID: p.session.id.uuidString, userPaused: true, readyNotifiedAt: nil, partialNotifiedSummary: nil,
                                         updatedAt: Date()).save(db)
        }
        summary = try await f.report(p.session).summary
        XCTAssertEqual(summary.outcome, .paused)
        XCTAssertTrue(summary.accountedFor)
    }

    // T29
    func testReadyEntryWhoseAudioIsMissingIsNotPlayable() async throws {
        let f = try issueFixture()
        let p = try await f.playlist("Missing", count: 2)
        try await f.intent(p.session, "completed")
        try await f.set(p.entries[0], .ready, track: f.fixture.ids[0])
        try await f.set(p.entries[1], .ready, track: f.fixture.ids[1])
        var summary = try await f.report(p.session).summary
        XCTAssertEqual(summary.outcome, .fullyReady)
        try FileManager.default.removeItem(at: try f.fixture.file(1))
        let report = try await f.report(p.session)
        summary = report.summary
        XCTAssertEqual(summary.playable, 1, "A 'ready' row without its file never counts as playable")
        XCTAssertEqual(summary.outcome, .finishedWithIssues)
        XCTAssertEqual(report.occurrence(p.entries[1].id)?.assessment.category, .missingLocalAudio)
        XCTAssertTrue(report.occurrence(p.entries[1].id)?.assessment.actions.contains(.importLocalFile) == true)
    }

    // T30
    func testFiveHundredMixedOccurrencesAlwaysAddUp() async throws {
        let f = try issueFixture()
        let p = try await f.playlist("Mixed", count: 500, duplicate: { $0 % 50 == 49 ? 0 : nil })
        try await f.intent(p.session, "completed")
        let statuses = PlaylistMigrationEntryStatus.allCases, ids = f.fixture.ids
        try await f.db.write { db in
            for entry in p.entries {
                let status = statuses[(entry.position * 7) % statuses.count]
                let track: String? = status == .ready ? ids[entry.position % 4] : nil
                try db.execute(sql: "UPDATE migration_entries SET status = ?, localTrackID = ? WHERE id = ?",
                               arguments: [status.rawValue, track, entry.id.uuidString])
                if [.unavailable, .needsReview, .failed].contains(status) {
                    try MatchingCheckpoint(entryID: entry.id.uuidString, algorithm: CandidateScoringEngine.algorithmVersion, retryable: status == .failed,
                                           outcome: status == .unavailable ? "noMatch" : status == .failed ? "provider" : "review", updatedAt: Date()).save(db)
                }
            }
        }
        for running in ["completed", "running", "userPaused"] {
            try await f.intent(p.session, running)
            let summary = try await f.report(p.session).summary
            XCTAssertEqual(summary.playable + summary.unresolved + summary.skipped, 500, running)
            XCTAssertEqual(summary.total, 500)
            XCTAssertEqual(summary.needsReview + summary.failed + summary.waiting, summary.unresolved)
            let ready = p.entries.filter { statuses[($0.position * 7) % statuses.count] == .ready }.count
            let skipped = p.entries.filter { statuses[($0.position * 7) % statuses.count] == .skipped }.count
            XCTAssertEqual(summary.playable, ready); XCTAssertEqual(summary.skipped, skipped)
            XCTAssertNotEqual(summary.outcome, .fullyReady)
        }
    }

    // T31
    func testSongsAddedManuallyLaterDoNotChangeMigrationTotals() async throws {
        let f = try issueFixture()
        let p = try await f.playlist("Hybrid", count: 2)
        try await f.intent(p.session, "completed")
        try await f.set(p.entries[0], .ready, track: f.fixture.ids[0])
        try await f.set(p.entries[1], .unavailable); try await f.checkpoint(p.entries[1], "noMatch")
        let before = try await f.report(p.session).summary
        let playlistID = try XCTUnwrap(p.session.destinationPlaylistID)
        try f.fixture.repository.addTracks([f.fixture.ids[2], f.fixture.ids[3], f.fixture.ids[2]], playlistID: playlistID)
        let after = try await f.report(p.session).summary
        XCTAssertEqual(after, before)
        XCTAssertEqual(after.total, 2); XCTAssertEqual(after.playable, 1)
    }

    // T42
    func testIssueReportingLeavesLibraryAndOfflinePlaybackUntouched() async throws {
        let f = try issueFixture()
        let p = try await f.playlist("Playback", count: 3)
        try await f.intent(p.session, "completed")
        try await f.set(p.entries[0], .ready, track: f.fixture.ids[0])
        try await f.set(p.entries[1], .ready, track: f.fixture.ids[1])
        try await f.set(p.entries[2], .unavailable); try await f.checkpoint(p.entries[2], "noMatch")
        let ordinary = try f.fixture.repository.createPlaylist(name: "Ordinary")
        try f.fixture.repository.addTracks([f.fixture.ids[3]], playlistID: ordinary.id)
        let playlistID = try XCTUnwrap(p.session.destinationPlaylistID)
        let snapshot = try f.fixture.repository.snapshot()
        let playable = try f.repo.rows(playlistID: playlistID).filter { $0.playableTrack != nil }.map(\.id)
        let audio = try f.repo.hybridPlaybackOccurrences(playlistID: playlistID)

        await f.reconcile()
        let row = try XCTUnwrap(f.coordinator.reports[p.session.id]?.occurrence(p.entries[2].id))
        try await f.coordinator.skip(row)
        await f.reconcile()

        let after = try f.fixture.repository.snapshot()
        XCTAssertEqual(after.tracks.map(\.id), snapshot.tracks.map(\.id), "No library track is created or removed")
        XCTAssertEqual(after.playlistTracks(ordinary.id).map(\.id), [f.fixture.ids[3]])
        XCTAssertEqual(try f.repo.rows(playlistID: playlistID).filter { $0.playableTrack != nil }.map(\.id), playable)
        XCTAssertEqual(try f.repo.hybridPlaybackOccurrences(playlistID: playlistID), audio, "Offline playback order is unchanged")
        for index in 0..<4 { XCTAssertTrue(FileManager.default.fileExists(atPath: try f.fixture.file(index).path)) }
    }
}
