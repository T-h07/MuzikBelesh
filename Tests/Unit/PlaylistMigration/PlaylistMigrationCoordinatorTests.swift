import AVFoundation
import Foundation
import GRDB
import XCTest
@testable import OFFLINE

/// Phase 10.6 acceptance contracts (T01–T32). Deterministic: scripted providers, a
/// controlled wall clock for deadlines, explicit execution grants and simulated
/// restarts over the same SQLite store. Waits are bounded condition checks only.
@MainActor final class PlaylistMigrationCoordinatorTests: XCTestCase {
    private func title(_ name: String, _ index: Int) -> String { CoordinatorHarness.title(name, index) }

    // MARK: A. Persistence and recovery

    func testT01FiveHundredSongMigrationSurvivesRestartWithOrderDuplicatesAndResults() async throws {
        let h = try await coordinatorHarness(limit: 2)
        let session = try await h.importPlaylist("Big", count: 500, duplicate: { $0 > 0 && $0 % 50 == 0 ? 0 : nil })
        for index in stride(from: 7, to: 500, by: 7) where index % 50 != 0 { await h.discovery.set(title("Big", index), [.empty]) }
        await h.discovery.set(title("Big", 120), [.block])
        try await h.coordinator.startMigration(session.id)
        try await h.until("Song 121 in flight", timeout: 90) { await h.discovery.isHolding(self.title("Big", 120)) }

        // Confirm and download a few reviewed songs while matching is still running.
        let early = try await h.entries(session)
        var confirmed: [UUID: UUID] = [:]
        for index in 1...6 { confirmed[early[index].id] = try await h.confirmTop(early[index]).id }
        try await h.until("Six songs offline", timeout: 90) { try await h.readyCount(session) == 6 }
        let before = try await h.entries(session)
        let tracks = Dictionary(uniqueKeysWithValues: before.compactMap { entry in entry.localTrackID.map { (entry.id, $0) } })
        let jobs = try h.base.jobs().map(\.id).sorted()
        let started = await h.base.transfer.started.count
        let processed = try await h.summary(session).processed
        XCTAssertGreaterThanOrEqual(processed, 120)

        // Process termination while the 121st search is in flight, then a cold launch.
        try await h.relaunch()
        try await h.complete(session, timeout: 110)

        let after = try await h.entries(session)
        XCTAssertEqual(after.map(\.id), before.map(\.id), "Every occurrence survives with its identity")
        XCTAssertEqual(after.map(\.position), Array(0..<500), "Source order is unchanged")
        XCTAssertEqual(after.filter { $0.source.sourceTrackID == "Big-0" }.count, 10, "Duplicate Spotify occurrences stay separate")
        for (entry, track) in tracks {
            let value = try XCTUnwrap(after.first { $0.id == entry })
            XCTAssertEqual(value.status, .ready); XCTAssertEqual(value.localTrackID, track)
        }
        for (entry, candidate) in confirmed {
            let accepted = try await h.repo.candidates(entryID: entry).filter { $0.decision == .accepted }.map(\.id)
            XCTAssertEqual(accepted, [candidate], "The committed decision is unchanged")
        }
        XCTAssertEqual(after.filter { $0.status == .ready }.count, 6, "Nothing was confirmed or downloaded automatically")
        XCTAssertEqual(after.filter { $0.status == .matched }.count, 0, "No suggestion was approved without the user")
        XCTAssertEqual(try h.base.jobs().map(\.id).sorted(), jobs, "No new download jobs")
        let startedAfter = await h.base.transfer.started.count
        XCTAssertEqual(startedAfter, started, "No recording was downloaded again")
        for index in 1..<120 where index % 50 != 0 {
            let calls = await h.discovery.calls(for: title("Big", index))
            XCTAssertEqual(calls, 1, "Committed song \(index) was not searched again")
        }
        let interrupted = await h.discovery.calls(for: title("Big", 120))
        XCTAssertLessThanOrEqual(interrupted, 2)
        let summary = try await h.summary(session)
        XCTAssertEqual(summary.processed, 500)
        XCTAssertEqual(summary.noMatch, (1..<500).filter { $0 % 7 == 0 && $0 % 50 != 0 }.count)
    }

    func testT02RepeatedAndOverlappingRecoveryNeverDuplicatesWork() async throws {
        let h = try await coordinatorHarness()
        let session = try await h.importPlaylist("Twice", count: 60)
        await h.discovery.set(title("Twice", 30), [.block])
        try await h.coordinator.startMigration(session.id)
        try await h.until("Holding") { await h.discovery.isHolding(self.title("Twice", 30)) }
        let entries = try await h.entries(session)
        try await h.confirmTop(entries[0]); try await h.confirmTop(entries[1])
        try await h.until("Two offline") { try await h.readyCount(session) == 2 }
        try await h.until("Batch notification") { h.base.notifier.batches.count == 1 }
        try await h.relaunch()
        let coordinator = h.coordinator!
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<4 { group.addTask { await coordinator.restoreUnfinishedMigrations() } }
            for _ in 0..<3 { group.addTask { await coordinator.reconcileAll() } }
            group.addTask { await coordinator.applicationDidBecomeActive() }
            group.addTask { await coordinator.networkDidChange(NetworkPathSnapshot(known: true, connected: true, wifi: true)) }
        }
        try await h.complete(session)
        for _ in 0..<3 { await coordinator.restoreUnfinishedMigrations() }
        try await h.idle()
        await h.base.settle()

        let maxActive = await h.discovery.maxActive
        XCTAssertEqual(maxActive, 1, "One matching worker, one request at a time")
        for index in 0..<60 {
            let calls = await h.discovery.calls(for: title("Twice", index))
            XCTAssertEqual(calls, index == 30 ? 2 : 1, "Song \(index)")
        }
        XCTAssertEqual(try h.base.jobs().count, 2)
        let tracks = try await h.base.trackCount()
        XCTAssertEqual(tracks, 2)
        let awaited1 = try await h.entries(session).count
        XCTAssertEqual(awaited1, 60)
        for entry in try await h.entries(session) {
            let candidates = try await h.repo.candidates(entryID: entry.id)
            XCTAssertEqual(candidates.count, 2, "No duplicate suggestions for position \(entry.position)")
        }
        let awaited2 = try await h.count("migration_coordinator_state")
        XCTAssertEqual(awaited2, 1)
        let awaited3 = try await h.count("migration_entry_retries")
        XCTAssertEqual(awaited3, 0)
        XCTAssertEqual(h.base.notifier.batches.count, 1, "A completion notification is never repeated")
    }

    func testT03CompletedRecordingIsReusedAfterRestartAndBySharingPlaylists() async throws {
        let h = try await coordinatorHarness()
        let a = try await h.importPlaylist("Reuse", count: 3)
        try await h.coordinator.startMigration(a.id)
        try await h.complete(a)
        let entry = try await h.entries(a)[0]
        let candidate = try await h.confirmTop(entry)
        try await h.until("Offline") { try await h.readyCount(a) == 1 }
        let jobs = try h.base.jobs()
        let started = await h.base.transfer.started.count
        let track = try await h.entries(a)[0].localTrackID
        try await h.relaunch(); try await h.relaunch()
        await h.coordinator.reconcileAll(); await h.base.settle()
        XCTAssertEqual(try h.base.jobs().map(\.id), jobs.map(\.id))
        XCTAssertEqual(try h.base.jobs().first?.state, .completed)
        var startedNow = await h.base.transfer.started.count
        XCTAssertEqual(startedNow, started)
        let awaited4 = try await h.entries(a)[0].localTrackID
        XCTAssertEqual(awaited4, track)

        // A second playlist confirming the same recording uses the verified track.
        let b = try await h.importPlaylist("Reuse B", count: 1)
        try await h.base.confirm(try await h.entries(b)[0], video: try XCTUnwrap(candidate.providerTrackID))
        try await h.until("Shared recording offline") { try await h.readyCount(b) == 1 }
        let awaited5 = try await h.entries(b)[0].localTrackID
        XCTAssertEqual(awaited5, track)
        XCTAssertEqual(try h.base.jobs().count, 1)
        startedNow = await h.base.transfer.started.count
        XCTAssertEqual(startedNow, started, "Never downloaded twice")
        let tracks = try await h.base.trackCount()
        XCTAssertEqual(tracks, 1)
    }

    func testT04InterruptionAfterImportBeforeAssociationCompletesWithoutDownloading() async throws {
        let h = try await coordinatorHarness()
        let a = try await h.importPlaylist("Associate", count: 2)
        try await h.coordinator.startMigration(a.id)
        try await h.complete(a)
        let entry = try await h.entries(a)[0]
        try await h.confirmTop(entry)
        try await h.until("Offline") { try await h.readyCount(a) == 1 }
        let awaited6 = try await h.entries(a)[0].localTrackID
        let track = try XCTUnwrap(awaited6)
        let started = await h.base.transfer.started.count
        let id = entry.id.uuidString
        // The audio was verified and imported, but the process died before association.
        try await h.relaunch(crash: { db in
            try db.execute(sql: "UPDATE migration_entries SET status = 'matched', localTrackID = NULL WHERE id = ?", arguments: [id])
            try db.execute(sql: "UPDATE migration_acquisitions SET state = 'waiting', trackID = NULL, completedAt = NULL WHERE entryID = ?", arguments: [id])
        })
        try await h.until("Association recovered") { try await h.readyCount(a) == 1 }
        let awaited7 = try await h.entries(a)[0].localTrackID
        XCTAssertEqual(awaited7, track, "The existing verified track is associated")
        let startedAfter = await h.base.transfer.started.count
        XCTAssertEqual(startedAfter, started, "No second download")
        let tracks = try await h.base.trackCount()
        XCTAssertEqual(tracks, 1, "No duplicate imported audio")
        XCTAssertEqual(try h.base.jobs().count, 1)
    }

    func testT05AcceptedRejectedAndPendingDecisionsSurviveRestart() async throws {
        let h = try await coordinatorHarness()
        let a = try await h.importPlaylist("Decide", count: 4)
        try await h.coordinator.startMigration(a.id)
        try await h.complete(a)
        let entries = try await h.entries(a)
        let accepted = try await h.confirmTop(entries[0])
        let second = try await h.repo.candidates(entryID: entries[1].id).sorted { $0.id.uuidString < $1.id.uuidString }
        try await h.repo.rejectCandidate(entryID: entries[1].id, candidateID: second[0].id)
        let pending = Set(try await h.repo.candidates(entryID: entries[2].id).map(\.id))
        try await h.relaunch()
        try await h.coordinator.resumeMatching(a.id)
        try await h.idle()

        let first = try await h.repo.candidates(entryID: entries[0].id)
        XCTAssertEqual(first.filter { $0.decision == .accepted }.map(\.id), [accepted.id], "The exact committed decision")
        let rejected = try await h.repo.candidates(entryID: entries[1].id)
        XCTAssertEqual(rejected.first { $0.id == second[0].id }?.decision, .rejected, "Rejection history survives")
        XCTAssertFalse(rejected.contains { $0.decision == .accepted })
        XCTAssertEqual(rejected.filter { $0.providerTrackID == second[0].providerTrackID }.count, 1, "A rejected recording is never re-proposed")
        let third = try await h.repo.candidates(entryID: entries[2].id)
        XCTAssertEqual(Set(third.map(\.id)), pending)
        XCTAssertTrue(third.allSatisfy { $0.decision == .pending }, "Nothing selected silently")
        let fourth = try await h.repo.candidates(entryID: entries[3].id)
        XCTAssertFalse(fourth.contains { $0.decision == .accepted })
        let statuses = try await h.entries(a).map(\.status)
        XCTAssertEqual(Array(statuses[1...3]), [.needsReview, .needsReview, .needsReview])
    }

    // MARK: B. Networking and retry policy

    /// Shared setup: matching in flight, two confirmed downloads held, then Wi-Fi lost.
    private func loseConnectivity(_ h: CoordinatorHarness) async throws -> PlaylistMigrationSession {
        let a = try await h.importPlaylist("Loss", count: 30)
        await h.discovery.set(title("Loss", 10), [.block])
        try await h.coordinator.startMigration(a.id)
        try await h.until("Holding") { await h.discovery.isHolding(self.title("Loss", 10)) }
        let entries = try await h.entries(a)
        try await h.confirmTop(entries[0]); try await h.confirmTop(entries[1])
        try await h.until("Downloads in flight") { await h.base.transfer.waiting == 2 }
        await h.discovery.setDefault(.offline)
        h.base.downloads.setPath(connected: false, wifi: false)
        try await h.until("Coordinator observed the loss") { !h.coordinator.network.connected }
        await h.discovery.release()
        try await h.idle()
        return a
    }

    func testT06WiFiLossPreservesWorkWithoutDestructiveChanges() async throws {
        let h = try await coordinatorHarness(holding: true)
        let a = try await loseConnectivity(h)
        let summary = try await h.summary(a)
        XCTAssertEqual(summary.failed, 0, "Lost connectivity is not a song failure")
        XCTAssertEqual(summary.discoveryFailed, 0)
        XCTAssertGreaterThanOrEqual(summary.processed, 11)
        let intent = try await h.intent(a)
        XCTAssertEqual(intent, "systemPaused")
        XCTAssertEqual(h.coordinator.status(for: a.id)?.state, .waitingForNetwork)
        let entries = try await h.entries(a)
        XCTAssertEqual(entries[0].status, .matched); XCTAssertEqual(entries[1].status, .matched)
        let awaited8 = try await h.base.links().contains { [.failed, .unsupported].contains($0.state) }
        XCTAssertFalse(awaited8, "Confirmed selections are preserved")
        let calls = await h.discovery.total
        for _ in 0..<3 { await h.coordinator.reconcileAll() }
        XCTAssertFalse(h.model.busy)
        let after = await h.discovery.total
        XCTAssertEqual(after, calls, "No repeated network failures while offline")
    }

    func testT07ConnectivityRestorationResumesMatchingAndDownloadsAutomatically() async throws {
        let h = try await coordinatorHarness(holding: true)
        let a = try await loseConnectivity(h)
        await h.discovery.setDefault(.candidates)
        await h.base.transfer.releaseAll()
        h.base.downloads.setPath(connected: true, wifi: true)
        try await h.complete(a)
        try await h.until("Confirmed downloads offline") { try await h.readyCount(a) == 2 }
        XCTAssertEqual(try h.base.jobs().count, 2, "No duplicated jobs")
        let summary = try await h.summary(a)
        XCTAssertEqual(summary.externalDeferred, 0); XCTAssertEqual(summary.failed, 0)
        let intent = try await h.intent(a)
        XCTAssertEqual(intent, "completed")
    }

    func testT08TemporaryFailuresRetryWithBoundedExponentialBackoff() async throws {
        let h = try await coordinatorHarness()
        let a = try await h.importPlaylist("Retry", count: 5)
        await h.discovery.set(title("Retry", 3), Array(repeating: .fail, count: 6))
        try await h.coordinator.startMigration(a.id)
        try await h.complete(a)
        let entry = try await h.entries(a)[3]
        let awaited9 = try await h.store.retryRecord(entryID: entry.id)
        var record = try XCTUnwrap(awaited9)
        XCTAssertEqual(record.failures, 1); XCTAssertTrue(record.eligible)
        XCTAssertEqual(try XCTUnwrap(record.nextRetryAt).timeIntervalSince(h.clock.now), 15, accuracy: 0.01)

        for (wait, expectedCalls, delay) in [(14.0, 1, 15.0), (2.0, 2, 60.0), (61.0, 3, 180.0)] {
            h.clock.advance(wait)
            await h.coordinator.reconcileAll(); try await h.idle()
            let calls = await h.discovery.calls(for: title("Retry", 3))
            XCTAssertEqual(calls, expectedCalls)
            if expectedCalls > 1 {
                let awaited10 = try await h.store.retryRecord(entryID: entry.id)
                record = try XCTUnwrap(awaited10)
                XCTAssertEqual(record.failures, expectedCalls)
                XCTAssertEqual(try XCTUnwrap(record.nextRetryAt).timeIntervalSince(h.clock.now), delay, accuracy: 0.01)
            }
        }
        h.clock.advance(181)
        await h.coordinator.reconcileAll(); try await h.idle()
        let awaited11 = try await h.store.retryRecord(entryID: entry.id)
        record = try XCTUnwrap(awaited11)
        XCTAssertEqual(record.failures, 4); XCTAssertFalse(record.eligible, "Three automatic retries, then explicit action")
        XCTAssertNil(record.nextRetryAt)
        h.clock.advance(100_000)
        await h.coordinator.reconcileAll(); try await h.idle()
        let calls = await h.discovery.calls(for: title("Retry", 3))
        XCTAssertEqual(calls, 4, "Initial attempt plus three automatic retries")
        for index in [0, 1, 2, 4] {
            let others = await h.discovery.calls(for: title("Retry", index))
            XCTAssertEqual(others, 1)
        }
        // An explicit retry restarts the bounded budget.
        try await h.coordinator.retryFailedEntries(a.id)
        try await h.idle()
        let explicit = await h.discovery.calls(for: title("Retry", 3))
        XCTAssertEqual(explicit, 5)
        let awaited12 = try await h.store.retryRecord(entryID: entry.id)
        record = try XCTUnwrap(awaited12)
        XCTAssertEqual(record.failures, 1); XCTAssertTrue(record.eligible)
    }

    func testT09RetryDeadlineAndAttemptCountSurviveRestart() async throws {
        let h = try await coordinatorHarness()
        let a = try await h.importPlaylist("Persist", count: 4)
        await h.discovery.set(title("Persist", 2), [.fail, .fail])
        try await h.coordinator.startMigration(a.id)
        try await h.complete(a)
        let entry = try await h.entries(a)[2]
        let awaited13 = try await h.store.retryRecord(entryID: entry.id)
        let original = try XCTUnwrap(awaited13)
        h.clock.advance(5)
        try await h.relaunch()
        await h.coordinator.reconcileAll(); try await h.idle()
        var calls = await h.discovery.calls(for: title("Persist", 2))
        XCTAssertEqual(calls, 1, "The original deadline is honored after restart")
        let awaited14 = try await h.store.retryRecord(entryID: entry.id)
        let restored = try XCTUnwrap(awaited14)
        XCTAssertEqual(restored.failures, original.failures)
        XCTAssertEqual(try XCTUnwrap(restored.nextRetryAt).timeIntervalSince1970, try XCTUnwrap(original.nextRetryAt).timeIntervalSince1970, accuracy: 0.01)
        h.clock.advance(11)
        await h.coordinator.reconcileAll(); try await h.idle()
        calls = await h.discovery.calls(for: title("Persist", 2))
        XCTAssertEqual(calls, 2)
        let awaited15 = try await h.store.retryRecord(entryID: entry.id)
        let next = try XCTUnwrap(awaited15)
        XCTAssertEqual(next.failures, 2, "Restart never resets the attempt count")
    }

    func testT10PermanentFailuresReachStableTerminalStateWithoutRepeatedRequests() async throws {
        let h = try await coordinatorHarness()
        let a = try await h.importPlaylist("Missing", count: 5)
        await h.discovery.setDefault(.empty)
        try await h.coordinator.startMigration(a.id)
        try await h.complete(a)
        let awaited16 = try await h.summary(a).noMatch
        XCTAssertEqual(awaited16, 5)
        for round in 0..<2 {
            try await h.relaunch()
            h.clock.advance(100_000)
            await h.coordinator.reconcileAll(); try await h.idle()
            let total = await h.discovery.total
            XCTAssertEqual(total, 5, "Round \(round): a permanently missing recording is not searched again")
        }
        let awaited17 = try await h.entries(a).allSatisfy { $0.status == .unavailable }
        XCTAssertTrue(awaited17)
        let awaited18 = try await h.count("migration_entry_retries")
        XCTAssertEqual(awaited18, 0)
        XCTAssertEqual(h.coordinator.status(for: a.id)?.state, .completedWithIssues)

        // Invalid metadata is classified as permanent: visible, never scheduled.
        let entry = try await h.entries(a)[0]
        let since = Date().addingTimeInterval(-1)
        try await h.storage.database.dbQueue.write { db in
            try db.execute(sql: "UPDATE migration_entries SET status = 'failed' WHERE id = ?", arguments: [entry.id.uuidString])
            try db.execute(sql: "UPDATE migration_matching_checkpoints SET outcome = 'metadata', retryable = 1, updatedAt = ? WHERE entryID = ?",
                           arguments: [Date(), entry.id.uuidString])
        }
        try await h.store.recordOutcomes(migrationID: a.id, since: since, policy: .deterministic, now: h.clock.now)
        let awaited19 = try await h.store.retryRecord(entryID: entry.id)
        let record = try XCTUnwrap(awaited19)
        XCTAssertFalse(record.eligible); XCTAssertEqual(record.category, MigrationFailureCategory.invalidMetadata.rawValue)
        h.clock.advance(100_000)
        await h.coordinator.reconcileAll(); try await h.idle()
        let total = await h.discovery.total
        XCTAssertEqual(total, 5)
    }

    func testT11RateLimitActivatesDurableProviderCooldownAcrossMigrationsAndRestarts() async throws {
        let h = try await coordinatorHarness()
        let a = try await h.importPlaylist("Limited", count: 10)
        await h.discovery.set(title("Limited", 0), [.rateLimited(.seconds(120))])
        try await h.coordinator.startMigration(a.id)
        try await h.complete(a)
        var total = await h.discovery.total
        XCTAssertEqual(total, 1, "The restricted provider is not hit again for the next songs")
        let awaited20 = try await h.store.providerCooldowns()["fixture"]
        let cooldown = try XCTUnwrap(awaited20)
        XCTAssertEqual(cooldown.expiresAt.timeIntervalSince(h.clock.now), 120, accuracy: 1, "Retry-After is honored")
        let status = try XCTUnwrap(h.coordinator.status(for: a.id))
        XCTAssertEqual(status.state, .coolingDown); XCTAssertEqual(status.message, "Search provider cooling down")
        let awaited21 = try await h.summary(a).externalDeferred
        XCTAssertEqual(awaited21, 9)

        // The cooldown applies to every migration using the provider.
        let b = try await h.importPlaylist("Other", count: 5)
        try await h.coordinator.startMigration(b.id)
        try await h.complete(b)
        total = await h.discovery.total
        XCTAssertEqual(total, 1)
        // Song 0's retry is due, but the provider is still cooling down; then a restart.
        h.clock.advance(20)
        await h.coordinator.reconcileAll(); try await h.idle()
        try await h.relaunch()
        await h.coordinator.reconcileAll(); try await h.idle()
        total = await h.discovery.total
        XCTAssertEqual(total, 1, "Persisted cooldown survives restart")

        h.clock.advance(101)
        await h.coordinator.reconcileAll()
        try await h.until("Both playlists searched after the cooldown") {
            let first = try await h.summary(a), second = try await h.summary(b)
            return !h.model.busy && first.readyToReview == 10 && second.readyToReview == 5
        }
        let first = await h.discovery.calls(for: title("Limited", 0))
        XCTAssertEqual(first, 2)
        for index in 1..<10 { let calls = await h.discovery.calls(for: title("Limited", index)); XCTAssertEqual(calls, 1) }
        for index in 0..<5 { let calls = await h.discovery.calls(for: title("Other", index)); XCTAssertEqual(calls, 1) }
        let awaited22 = try await h.store.providerCooldowns()["fixture"]
        XCTAssertNil(awaited22, "A successful search clears the cooldown")
    }

    func testT12HealthyProviderContinuesWhileAnotherIsCoolingDown() async throws {
        let h = try await coordinatorHarness(providers: ["alpha", "beta"])
        try await h.store.saveProviderCooldown(PersistedProviderCooldown(provider: "alpha", expiresAt: h.clock.now.addingTimeInterval(600),
                                                                         probes: 1, reason: "Search temporarily limited.", updatedAt: h.clock.now))
        let a = try await h.importPlaylist("Two", count: 6)
        try await h.coordinator.startMigration(a.id)
        try await h.complete(a)
        let alpha = await h.providers[0].total, beta = await h.providers[1].total
        XCTAssertEqual(alpha, 0, "The cooling provider is never called")
        XCTAssertEqual(beta, 6)
        let summary = try await h.summary(a)
        XCTAssertEqual(summary.readyToReview, 6); XCTAssertEqual(summary.externalDeferred, 0)
        XCTAssertNotEqual(h.coordinator.status(for: a.id)?.state, .coolingDown)
    }

    // MARK: C. Concurrency and resource management

    func testT13GlobalMatchingLimitHoldsUnderConcurrentTriggers() async throws {
        let h = try await coordinatorHarness(sliceSize: 25)
        let a = try await h.importPlaylist("Alpha", count: 100), b = try await h.importPlaylist("Beta", count: 100)
        let coordinator = h.coordinator!
        await withTaskGroup(of: Void.self) { group in
            group.addTask { try? await coordinator.startMigration(a.id) }
            group.addTask { try? await coordinator.startMigration(b.id) }
            for _ in 0..<3 { group.addTask { await coordinator.reconcileAll() } }
            group.addTask { await coordinator.restoreUnfinishedMigrations() }
            group.addTask { await coordinator.applicationDidBecomeActive() }
        }
        try await h.until("Both complete", timeout: 90) {
            let first = try await h.summary(a).processed, second = try await h.summary(b).processed
            return first == 100 && second == 100 && !h.model.busy
        }
        let maxActive = await h.discovery.maxActive
        XCTAssertEqual(maxActive, 1, "Never more than one external discovery request")
        for name in ["Alpha", "Beta"] {
            for index in 0..<100 { let calls = await h.discovery.calls(for: title(name, index)); XCTAssertEqual(calls, 1, "\(name) \(index)") }
        }
    }

    func testT14OrdinaryAndPlaylistDownloadsShareTheGlobalLimit() async throws {
        let h = try await coordinatorHarness(limit: 2, holding: true)
        for index in [901, 902] {
            let video = AcquisitionHarness.video(index)
            await h.base.transfer.seed(video, 500 + index % 100)
            h.base.downloads.enqueue(YouTubeVideo(id: video, title: "Ordinary \(index)"), quality: .standard)
        }
        let a = try await h.importPlaylist("Limit", count: 4)
        try await h.coordinator.startMigration(a.id)
        try await h.complete(a)
        for entry in try await h.entries(a) { try await h.confirmTop(entry) }
        try await h.until("Slots full") { await h.base.transfer.waiting == 2 }
        await h.base.settle()
        let active = await h.base.transfer.active
        XCTAssertEqual(active, 2)
        await h.base.transfer.releaseAll()
        try await h.until("All downloads finished", timeout: 90) {
            try await h.readyCount(a) == 4 && h.base.jobs().filter { $0.state == .completed }.count == 6
        }
        let maxActive = await h.base.transfer.maxActive
        XCTAssertLessThanOrEqual(maxActive, 2, "One limit across ordinary and playlist downloads")
    }

    func testT15FairSchedulingProgressesEveryPlaylist() async throws {
        let h = try await coordinatorHarness(sliceSize: 20)
        let a = try await h.importPlaylist("Fair A", count: 200), b = try await h.importPlaylist("Fair B", count: 200)
        await h.discovery.set(title("Fair A", 0), [.block])
        try await h.coordinator.startMigration(a.id)
        try await h.until("A started") { await h.discovery.isHolding(self.title("Fair A", 0)) }
        try await h.coordinator.startMigration(b.id)
        await h.discovery.release()
        try await h.until("Both complete", timeout: 100) {
            let first = try await h.summary(a).processed, second = try await h.summary(b).processed
            return first == 200 && second == 200 && !h.model.busy
        }
        let order = await h.discovery.history
        let firstB = try XCTUnwrap(order.firstIndex { $0.hasPrefix("Fair B") })
        XCTAssertLessThanOrEqual(firstB, 20, "B starts after A's first slice, not after all of A")
        let early = order.prefix(160)
        XCTAssertGreaterThanOrEqual(early.filter { $0.hasPrefix("Fair A") }.count, 60)
        XCTAssertGreaterThanOrEqual(early.filter { $0.hasPrefix("Fair B") }.count, 60)
        // Source order is preserved within each playlist.
        for name in ["Fair A", "Fair B"] {
            let positions = order.filter { $0.hasPrefix(name + " ") }.compactMap { Int($0.split(separator: " ").last ?? "") }
            XCTAssertEqual(positions, Array(0..<200))
        }
    }

    func testT16LowPowerModeReducesDownloadsWhileMatchingContinuesSerially() async throws {
        let h = try await coordinatorHarness(limit: 3, holding: true)
        h.base.downloads.setResourcePolicy(ResourcePolicy(lowPower: true))
        try await h.until("Coordinator observed Low Power Mode") { h.coordinator.resourcePolicy.lowPower }
        let a = try await h.importPlaylist("Power", count: 20)
        try await h.coordinator.startMigration(a.id)
        try await h.complete(a)
        let maxActive = await h.discovery.maxActive
        XCTAssertEqual(maxActive, 1)
        let entries = try await h.entries(a)
        for index in 0..<3 { try await h.confirmTop(entries[index]) }
        try await h.until("One transfer") { await h.base.transfer.waiting == 1 }
        await h.base.settle()
        let active = await h.base.transfer.active
        XCTAssertEqual(active, 1, "Low Power Mode limits downloads to one")
        await h.base.transfer.releaseAll()
        try await h.until("Offline", timeout: 90) { try await h.readyCount(a) == 3 }
        let transfers = await h.base.transfer.maxActive
        XCTAssertEqual(transfers, 1)
    }

    func testT17ThermalRestrictionDefersAndThenRecoversWork() async throws {
        let h = try await coordinatorHarness()
        h.base.downloads.setResourcePolicy(ResourcePolicy(thermal: .serious))
        try await h.until("Coordinator observed thermal pressure") { h.coordinator.resourcePolicy.defersNewWork }
        let a = try await h.importPlaylist("Thermal", count: 10)
        try await h.coordinator.startMigration(a.id)
        await h.coordinator.reconcileAll()
        XCTAssertFalse(h.model.busy)
        let total = await h.discovery.total
        XCTAssertEqual(total, 0, "No new work while the device is hot")
        XCTAssertEqual(h.coordinator.status(for: a.id)?.state, .resourceDeferred)
        h.base.downloads.setResourcePolicy(ResourcePolicy())
        try await h.complete(a)
        let after = await h.discovery.total
        XCTAssertEqual(after, 10)
    }

    func testT18ThousandEntryMigrationUsesBoundedWorkersQueriesAndUpdates() async throws {
        let h = try await coordinatorHarness(sliceSize: 40)
        let a = try await h.importPlaylist("Perf", count: 1000)
        try await h.coordinator.startMigration(a.id)
        try await h.complete(a, timeout: 115)
        XCTAssertEqual(h.execution.begins, 1, "Every slice ran under one execution grant")
        let maxActive = await h.discovery.maxActive
        XCTAssertEqual(maxActive, 1)
        XCTAssertLessThanOrEqual(h.coordinator.scheduledItems, 26, "Bounded slices, no per-song tasks")
        XCTAssertLessThan(h.coordinator.refreshes, 250, "Status publishes are coalesced")
        let clock = ContinuousClock(), started = clock.now
        for _ in 0..<10 { await h.coordinator.refresh() }
        XCTAssertLessThan(started.duration(to: clock.now), .seconds(10), "Aggregation over 1,000 occurrences stays cheap")
        let status = try XCTUnwrap(h.coordinator.status(for: a.id))
        XCTAssertEqual(status.progress.total, 1000); XCTAssertEqual(status.progress.matchingCompleted, 1000)
        XCTAssertEqual(status.progress.awaitingReview, 1000); XCTAssertEqual(status.progress.availableOffline, 0)
        let playlistID = try XCTUnwrap(a.destinationPlaylistID)
        XCTAssertEqual(try h.repo.rows(playlistID: playlistID).count, 1000)
    }

    // MARK: D. User controls

    func testT19PausedPlaylistStaysPausedAfterRestart() async throws {
        let h = try await coordinatorHarness()
        let a = try await h.importPlaylist("Paused", count: 30)
        await h.discovery.set(title("Paused", 10), [.block])
        try await h.coordinator.startMigration(a.id)
        try await h.until("Holding") { await h.discovery.isHolding(self.title("Paused", 10)) }
        try await h.coordinator.pauseMigration(a.id)
        XCTAssertFalse(h.model.busy)
        let calls = await h.discovery.total
        var intent = try await h.intent(a)
        XCTAssertEqual(intent, "userPaused")
        try await h.relaunch()
        await h.coordinator.applicationDidBecomeActive(); await h.coordinator.reconcileAll()
        try await h.idle()
        XCTAssertFalse(h.model.busy)
        let after = await h.discovery.total
        XCTAssertEqual(after, calls, "A user-paused playlist never resumes automatically")
        intent = try await h.intent(a)
        XCTAssertEqual(intent, "userPaused")
        XCTAssertEqual(h.coordinator.status(for: a.id)?.state, .userPaused)
        let paused = try await h.base.storage.database.dbQueue.read {
            try Bool.fetchOne($0, sql: "SELECT userPaused FROM migration_acquisition_controls WHERE migrationID = ?", arguments: [a.id.uuidString])
        }
        XCTAssertEqual(paused, true)
    }

    func testT20PausingOnePlaylistDoesNotAffectAnother() async throws {
        let h = try await coordinatorHarness(sliceSize: 10)
        let a = try await h.importPlaylist("Iso A", count: 40), b = try await h.importPlaylist("Iso B", count: 40)
        await h.discovery.set(title("Iso A", 5), [.block])
        try await h.coordinator.startMigration(a.id)
        try await h.until("A holding") { await h.discovery.isHolding(self.title("Iso A", 5)) }
        try await h.coordinator.startMigration(b.id)
        try await h.coordinator.pauseMigration(a.id)
        let aCalls = await h.discovery.history.filter { $0.hasPrefix("Iso A") }.count
        try await h.complete(b)
        let aAfter = await h.discovery.history.filter { $0.hasPrefix("Iso A") }.count
        XCTAssertEqual(aAfter, aCalls, "A stays paused")
        let awaited23 = try await h.summary(a).processed
        XCTAssertLessThan(awaited23, 40)
        let awaited24 = try await h.summary(b).processed
        XCTAssertEqual(awaited24, 40, "B continued independently")
        let intent = try await h.intent(a)
        XCTAssertEqual(intent, "userPaused")
    }

    func testT21CancellationPreservesLibraryAudioAndNeverResumes() async throws {
        let h = try await coordinatorHarness()
        let a = try await h.importPlaylist("Cancel", count: 8)
        await h.discovery.set(title("Cancel", 6), [.block])
        try await h.coordinator.startMigration(a.id)
        try await h.until("Holding") { await h.discovery.isHolding(self.title("Cancel", 6)) }
        let entries = try await h.entries(a)
        for index in 0..<3 { try await h.confirmTop(entries[index]) }
        try await h.until("Three offline") { try await h.readyCount(a) == 3 }
        try await h.coordinator.cancelMigration(a.id)
        XCTAssertFalse(h.model.busy)
        let awaited25 = try await h.repo.session(id: a.id)
        let session = try XCTUnwrap(awaited25)
        XCTAssertEqual(session.status, .cancelled)
        let intent = try await h.intent(a)
        XCTAssertEqual(intent, "userCancelled")
        let awaited26 = try await h.entries(a)[6].status
        XCTAssertEqual(awaited26, .pending, "The in-flight song is unfinished, not failed")
        let calls = await h.discovery.total

        let playlistID = try XCTUnwrap(a.destinationPlaylistID)
        func verifyLibrary() async throws {
            let rows = try h.repo.rows(playlistID: playlistID)
            XCTAssertEqual(rows.count, 8, "The destination playlist and every occurrence remain")
            XCTAssertEqual(rows.filter { $0.playableTrack != nil }.count, 3, "Verified songs stay playable")
            for track in rows.compactMap(\.playableTrack) {
                XCTAssertTrue(MigrationLocalAudio.isAvailable(track, paths: h.storage.paths))
                let url = try h.storage.paths.musicURL(relativePath: track.fileRelativePath)
                XCTAssertNoThrow(try AVAudioFile(forReading: url), "Audio decodes")
            }
            let playlist = try await h.storage.database.dbQueue.read { try StoredPlaylist.fetchOne($0, key: playlistID) }
            XCTAssertNotNil(playlist)
        }
        try await verifyLibrary()
        try await h.relaunch()
        await h.coordinator.reconcileAll(); try await h.idle()
        let after = await h.discovery.total
        XCTAssertEqual(after, calls, "A cancelled migration never resumes")
        XCTAssertEqual(h.coordinator.status(for: a.id)?.state, .cancelled)
        try await verifyLibrary()
        do { try await h.coordinator.startMigration(a.id); XCTFail("Cancelled migrations cannot restart") } catch {}
        let tracks = try await h.base.trackCount()
        XCTAssertEqual(tracks, 3)
    }

    func testT22CancellingOnePlaylistKeepsASharedDownloadForAnother() async throws {
        let h = try await coordinatorHarness(holding: true)
        let a = try await h.importPlaylist("Shared A", count: 1), b = try await h.importPlaylist("Shared B", count: 1)
        let video = AcquisitionHarness.video(77)
        try await h.base.confirm(try await h.entries(a)[0], video: video)
        try await h.base.confirm(try await h.entries(b)[0], video: video)
        try await h.until("Transfer in flight") { await h.base.transfer.waiting == 1 }
        try await h.coordinator.cancelMigration(a.id)
        await h.base.settle()
        let job = try XCTUnwrap(try h.base.jobs().first { $0.sourceIdentifier == video })
        XCTAssertFalse([.paused, .cancelled].contains(job.state), "B still needs the shared download")
        await h.base.transfer.releaseAll()
        try await h.until("B offline") { try await h.readyCount(b) == 1 }
        XCTAssertEqual(try h.base.jobs().count, 1)
        let started = await h.base.transfer.started.count
        XCTAssertEqual(started, 1)
    }

    func testT23ExplicitResumeRestoresOnlyUnfinishedWork() async throws {
        let h = try await coordinatorHarness()
        let a = try await h.importPlaylist("Resume", count: 30)
        await h.discovery.set(title("Resume", 12), [.block])
        try await h.coordinator.startMigration(a.id)
        try await h.until("Holding") { await h.discovery.isHolding(self.title("Resume", 12)) }
        try await h.coordinator.pauseMigration(a.id)
        let awaited27 = try await h.summary(a).processed
        XCTAssertEqual(awaited27, 12)
        try await h.coordinator.resumeMigration(a.id)
        try await h.complete(a)
        for index in 0..<30 {
            let calls = await h.discovery.calls(for: title("Resume", index))
            XCTAssertEqual(calls, index == 12 ? 2 : 1, "Song \(index)")
        }
        let intent = try await h.intent(a)
        XCTAssertEqual(intent, "completed")
    }

    // MARK: E. Background lifecycle

    func testT24BackgroundExpirationLeavesDurableRecoverableState() async throws {
        let h = try await coordinatorHarness()
        let a = try await h.importPlaylist("Expire", count: 30)
        await h.discovery.set(title("Expire", 10), [.block])
        try await h.coordinator.startMigration(a.id)
        try await h.until("Holding") { await h.discovery.isHolding(self.title("Expire", 10)) }
        await h.coordinator.applicationDidEnterBackground()
        h.execution.expire()
        try await h.idle()
        let intent = try await h.intent(a)
        XCTAssertEqual(intent, "systemPaused")
        let awaited28 = try await h.summary(a).processed
        XCTAssertEqual(awaited28, 10, "Committed progress is preserved")
        let awaited29 = try await h.entries(a)[10].status
        XCTAssertEqual(awaited29, .pending, "The interrupted song is unfinished")
        XCTAssertEqual(h.coordinator.status(for: a.id)?.state, .systemSuspended)
        await h.coordinator.reconcileAll()
        XCTAssertFalse(h.model.busy, "No new work without an execution opportunity")
        await h.coordinator.applicationDidBecomeActive()
        try await h.complete(a)
        for index in 0..<30 {
            let calls = await h.discovery.calls(for: title("Expire", index))
            XCTAssertEqual(calls, index == 10 ? 2 : 1)
        }
    }

    func testT25ForceQuitStateIsRecoveredWithoutAssumingBackgroundProgress() async throws {
        let h = try await coordinatorHarness()
        let a = try await h.importPlaylist("Quit", count: 20)
        await h.discovery.set(title("Quit", 8), [.block])
        try await h.coordinator.startMigration(a.id)
        try await h.until("Holding") { await h.discovery.isHolding(self.title("Quit", 8)) }
        let entry = try await h.entries(a)[8]
        let id = a.id.uuidString, entryID = entry.id.uuidString
        // Force quit: nothing is cleaned up. Reproduce the exact on-disk state.
        try await h.relaunch(crash: { db in
            try db.execute(sql: "UPDATE playlist_migrations SET status = 'matching' WHERE id = ?", arguments: [id])
            try db.execute(sql: "UPDATE migration_entries SET status = 'matching' WHERE id = ?", arguments: [entryID])
            try db.execute(sql: "INSERT OR REPLACE INTO migration_matching_jobs (migrationID, intent, updatedAt) VALUES (?, 'running', ?)", arguments: [id, Date()])
            try db.execute(sql: "UPDATE migration_coordinator_state SET state = 'matching', generation = ? WHERE migrationID = ?", arguments: [UUID().uuidString, id])
        })
        try await h.complete(a)
        XCTAssertGreaterThanOrEqual(h.coordinator.restorations, 1)
        for index in 0..<20 {
            let calls = await h.discovery.calls(for: title("Quit", index))
            XCTAssertEqual(calls, index == 8 ? 2 : 1)
        }
        let state = try await h.store.state(a.id)
        XCTAssertNil(state?.generation, "No abandoned lease remains")
        let awaited30 = try await h.entries(a).filter { $0.status == .matching }.count
        XCTAssertEqual(awaited30, 0)
    }

    func testT26StaleCompletionCannotOverwriteANewerGeneration() async throws {
        let h = try await coordinatorHarness()
        let a = try await h.importPlaylist("Stale", count: 10)
        try await h.repo.setMatchingIntent(a.id, intent: "running")
        let awaited31 = await h.coordinator.nextMatchingWork()
        let first = try XCTUnwrap(awaited31)
        let awaited32 = await h.coordinator.nextMatchingWork()
        let second = try XCTUnwrap(awaited32)
        XCTAssertNotEqual(first.generation, second.generation)
        let before = try await h.store.state(a.id)
        let stale = await h.coordinator.intentAfterRun(a.id, item: first, report: SongMatchingProgress(), startedAt: Date())
        XCTAssertEqual(stale, "running", "The persisted intent is returned unchanged")
        XCTAssertEqual(h.coordinator.recoveryConflicts, 1)
        let after = try await h.store.state(a.id)
        XCTAssertEqual(after?.generation, second.generation.uuidString)
        XCTAssertEqual(after?.cursorPosition, before?.cursorPosition)
        _ = await h.coordinator.intentAfterRun(a.id, item: second, report: SongMatchingProgress(), startedAt: Date())
        XCTAssertEqual(h.coordinator.recoveryConflicts, 1)
        let awaited33 = try await h.store.state(a.id)?.generation
        XCTAssertNil(awaited33)

        // Engine level: an older matching lease can no longer commit.
        let older = try await h.repo.beginMatching(migrationID: a.id)
        let newer = try await h.repo.beginMatching(migrationID: a.id)
        do { try await h.repo.finishMatching(older, paused: true); XCTFail("A stale lease committed") }
        catch SongMatchingError.staleAttempt { } catch { XCTFail("Unexpected \(error)") }
        try await h.repo.finishMatching(newer, paused: true)
    }

    func testT27DeferredBackgroundTransferIsRecreatedOnceOnForegroundReturn() async throws {
        let h = try await coordinatorHarness(limit: 1, systemTransfers: true, backgroundExecution: true)
        let system = try XCTUnwrap(h.base.system)
        let first = AcquisitionHarness.video(1), second = AcquisitionHarness.video(2)
        let p = try await h.base.playlist("Stall", [first, second])
        try await h.until("First transfer") { try h.base.systemTask(for: first) != nil }
        h.base.downloads.setForeground(false); await h.coordinator.applicationDidEnterBackground()
        try h.base.finishSystemTransfer(first)
        try await h.until("Final task created in the background") { try h.base.systemTask(for: second) != nil }
        try await h.until("First song offline") { try await h.base.entries(p.session)[0].status == .ready }
        let deferred = try XCTUnwrap(try h.base.systemTask(for: second))
        // Return exactly as RootView does: DownloadManager first, then the coordinator.
        h.base.downloads.setForeground(true); await h.coordinator.applicationDidBecomeActive()
        try await h.until("Recreated in the foreground") { try h.base.systemTask(for: second) != nil && system.cancelled.contains(deferred.number) }
        XCTAssertEqual(system.created, 3)
        for _ in 0..<3 { await h.coordinator.reconcileAll(); h.base.downloads.checkQueueHealth() }
        await h.base.settle()
        XCTAssertEqual(system.created, 3, "Coordinator recovery never duplicates the repair")
        try h.base.finishSystemTransfer(second)
        try await h.until("Playlist offline") { try await h.base.allReady(p.session) }
        XCTAssertEqual(try h.base.jobs().count, 2)
    }

    func testT28QueuedWorkWithFreeCapacityStartsWithoutPauseContinue() async throws {
        let h = try await coordinatorHarness(limit: 2)
        h.base.downloads.setPath(connected: false, wifi: false)
        let p = try await h.base.playlist("Idle", [AcquisitionHarness.video(31), AcquisitionHarness.video(32), AcquisitionHarness.video(33)])
        try await h.until("Jobs created") { try h.base.jobs().count == 3 }
        let first = try XCTUnwrap(try h.base.jobs().first?.id)
        // A worker died mid-transfer; the others never started. Capacity is free on launch.
        try await h.relaunch(crash: { db in
            try db.execute(sql: "UPDATE download_jobs SET state = 'downloading' WHERE id = ?", arguments: [first])
        })
        try await h.until("Recovered without user action", timeout: 90) { try await h.base.allReady(p.session) }
        XCTAssertEqual(try h.base.jobs().count, 3)
        XCTAssertTrue(try h.base.jobs().allSatisfy { $0.state == .completed })
    }

    // MARK: F. Library regressions

    func testT29OrdinaryLibraryPlaylistAndAudioAreUnaffected() async throws {
        let h = try await coordinatorHarness()
        let url = try h.storage.paths.musicURL(relativePath: "library-song.wav")
        let data = LibraryFixture.wav(seed: 3)
        try data.write(to: url)
        let now = Date()
        try h.storage.tracks.save(StoredTrack(id: "library-song", title: "Library Song", artistID: nil, albumID: nil, durationMs: 2000,
            fileRelativePath: url.lastPathComponent, fileExtension: "wav", fileSizeBytes: Int64(data.count), contentSHA256: try h.storage.audio.sha256(url: url),
            artworkRelativePath: nil, availability: .available, dateAdded: now, dateModified: now, originalFilename: url.lastPathComponent, metadataSource: "synthetic-test"))
        try await h.storage.database.dbQueue.write { db in
            try db.execute(sql: "INSERT INTO playlists (id, name, dateAdded, dateModified) VALUES ('ordinary', 'Ordinary', ?, ?)", arguments: [now, now])
            try db.execute(sql: "INSERT INTO playlist_tracks (playlistID, trackID, position, dateAdded) VALUES ('ordinary', 'library-song', 0, ?)", arguments: [now])
        }
        let a = try await h.importPlaylist("Library", count: 4)
        try await h.coordinator.startMigration(a.id)
        try await h.complete(a)
        try await h.confirmTop(try await h.entries(a)[0])
        try await h.until("Offline") { try await h.readyCount(a) == 1 }
        try await h.coordinator.cancelMigration(a.id)
        try await h.relaunch()
        await h.coordinator.reconcileAll()
        let members = try await h.storage.database.dbQueue.read {
            try String.fetchAll($0, sql: "SELECT trackID FROM playlist_tracks WHERE playlistID = 'ordinary' ORDER BY position")
        }
        XCTAssertEqual(members, ["library-song"])
        let awaited34 = try await h.storage.database.dbQueue.read { try StoredTrack.fetchOne($0, key: "library-song") }
        let track = try XCTUnwrap(awaited34)
        XCTAssertTrue(MigrationLocalAudio.isAvailable(track, paths: h.storage.paths))
        XCTAssertEqual(try h.storage.audio.sha256(url: url), track.contentSHA256, "Audio is untouched")
        XCTAssertNoThrow(try AVAudioFile(forReading: url))
        let tracks = try await h.base.trackCount()
        XCTAssertEqual(tracks, 2)
    }

    func testT30DuplicateOccurrencesKeepPositionsAndShareOneVerifiedRecording() async throws {
        let h = try await coordinatorHarness()
        let a = try await h.importPlaylist("Dup", count: 7, duplicate: { [3, 6].contains($0) ? 0 : nil })
        try await h.coordinator.startMigration(a.id)
        try await h.complete(a)
        let entries = try await h.entries(a)
        XCTAssertEqual(entries.map(\.position), Array(0..<7))
        XCTAssertEqual(Set([entries[0], entries[3], entries[6]].map(\.id)).count, 3, "Separate occurrences")
        let first = try await h.repo.candidates(entryID: entries[0].id), second = try await h.repo.candidates(entryID: entries[3].id)
        XCTAssertTrue(Set(first.map(\.id)).isDisjoint(with: second.map(\.id)), "Each occurrence has its own decisions")
        XCTAssertEqual(Set(first.compactMap(\.providerTrackID)), Set(second.compactMap(\.providerTrackID)))
        let chosenA = try await h.confirmTop(entries[0]), chosenB = try await h.confirmTop(entries[3])
        XCTAssertEqual(chosenA.providerTrackID, chosenB.providerTrackID)
        try await h.until("Both offline") { try await h.readyCount(a) == 2 }
        let after = try await h.entries(a)
        XCTAssertEqual(after[0].localTrackID, after[3].localTrackID, "One verified local track for one recording")
        XCTAssertEqual(try h.base.jobs().count, 1, "One shared download")
        XCTAssertEqual(after[6].status, .needsReview, "The third occurrence still waits for its own review")
        XCTAssertEqual(after.map(\.position), Array(0..<7))
    }

    func testT31MatchingConfirmedDownloadsAndReadyOfflineAreDistinct() async throws {
        let h = try await coordinatorHarness()
        let a = try await h.importPlaylist("Done", count: 6)
        try await h.coordinator.startMigration(a.id)
        try await h.complete(a)
        var status = try XCTUnwrap(h.coordinator.status(for: a.id))
        XCTAssertEqual(status.progress.matchingCompleted, 6); XCTAssertEqual(status.progress.availableOffline, 0)
        XCTAssertEqual(status.state, .awaitingReview, "Matching finished is not ready offline")
        let entries = try await h.entries(a)
        try await h.confirmTop(entries[0]); try await h.confirmTop(entries[1])
        try await h.until("Confirmed downloads finished") { h.base.notifier.batches.count == 1 }
        await h.coordinator.refresh()
        status = try XCTUnwrap(h.coordinator.status(for: a.id))
        XCTAssertEqual(status.progress.availableOffline, 2); XCTAssertEqual(status.progress.awaitingReview, 4)
        XCTAssertNotEqual(status.state, .completed, "Confirmed downloads finished is not the whole playlist")
        XCTAssertTrue(h.base.notifier.ready.isEmpty)
        for index in 2..<6 { try await h.confirmTop(entries[index]) }
        try await h.until("Whole playlist offline", timeout: 90) { try await h.readyCount(a) == 6 }
        await h.coordinator.refresh()
        status = try XCTUnwrap(h.coordinator.status(for: a.id))
        XCTAssertEqual(status.state, .completed); XCTAssertEqual(status.progress.availableOffline, 6)
        try await h.until("Ready notification") { h.base.notifier.ready.count == 1 }
    }

    func testT32RepeatedLaunchesCauseNoCumulativeCorruption() async throws {
        let h = try await coordinatorHarness()
        let a = try await h.importPlaylist("Launch", count: 50)
        await h.discovery.set(title("Launch", 20), Array(repeating: .block, count: 5))
        try await h.coordinator.startMigration(a.id)
        try await h.until("Holding") { await h.discovery.isHolding(self.title("Launch", 20)) }
        let entries = try await h.entries(a)
        try await h.confirmTop(entries[0]); try await h.confirmTop(entries[1])
        try await h.until("Two offline") { try await h.readyCount(a) == 2 }
        let ids = entries.map(\.id)
        let tracks = try await h.entries(a).compactMap(\.localTrackID)
        for round in 1...4 {
            try await h.relaunch()
            await h.coordinator.reconcileAll()
            try await h.until("Round \(round): searching again") { await h.discovery.isHolding(self.title("Launch", 20)) }
            let current = try await h.entries(a)
            XCTAssertEqual(current.map(\.id), ids); XCTAssertEqual(current.map(\.position), Array(0..<50))
            XCTAssertEqual(current.compactMap(\.localTrackID), tracks)
            XCTAssertEqual(try h.base.jobs().count, 2)
            let count = try await h.base.trackCount()
            XCTAssertEqual(count, 2)
            let awaited35 = try await h.count("migration_coordinator_state")
            XCTAssertEqual(awaited35, 1)
            let awaited36 = try await h.count("migration_entry_retries")
            XCTAssertEqual(awaited36, 0)
            for entry in current.prefix(20) {
                let candidates = try await h.repo.candidates(entryID: entry.id)
                XCTAssertEqual(candidates.count, 2)
            }
        }
        await h.discovery.release()
        try await h.complete(a)
        for index in 0..<50 {
            let calls = await h.discovery.calls(for: title("Launch", index))
            XCTAssertEqual(calls, index == 20 ? 5 : 1, "Song \(index)")
        }
        let summary = try await h.summary(a)
        XCTAssertEqual(summary.processed, 50)
    }
}
