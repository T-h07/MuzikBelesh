import Foundation
import GRDB
import XCTest
@testable import OFFLINE

/// Phase 10.5 coordinator contracts: automatic enqueueing, reuse, deduplication,
/// failure isolation, stale decisions and playlist integrity.
@MainActor final class PlaylistAcquisitionTests: XCTestCase {
    private let x = AcquisitionHarness.video(1), y = AcquisitionHarness.video(2), z = AcquisitionHarness.video(3)

    func testConfirmedRecordingsAutoEnqueueUnconfirmedNeverDoAndOrderIsPreserved() async throws {
        let h = try harness()
        let confirmed = try await h.playlist("Mixed", [x, nil, y])
        // A saved recommendation that the user never confirmed.
        let (pendingOnly, _) = try await h.playlist("Recommendations", [z], confirm: false)
        try await h.until("Confirmed songs available offline") {
            try await h.entries(confirmed.session).filter { $0.status == .ready }.count == 2
        }
        await h.settle()
        let after = try await h.entries(confirmed.session)
        XCTAssertEqual(after.map(\.id), confirmed.entries.map(\.id), "Occurrence identities never change")
        XCTAssertEqual(after.map(\.position), [0, 1, 2], "Source positions never change")
        XCTAssertEqual(after.map(\.source), confirmed.entries.map(\.source), "Spotify metadata is preserved")
        XCTAssertEqual(after[1].status, .pending, "An unresolved occurrence stays in place")
        XCTAssertEqual(Set(try h.jobs().compactMap(\.sourceIdentifier)), [x, y], "Only confirmed recordings are acquired")
        let awaited1 = try await h.entries(pendingOnly).first?.status
        XCTAssertEqual(awaited1, .pending)
        let prepared = h.preparer.prepared
        XCTAssertFalse(prepared.contains(z), "An unconfirmed recommendation is never resolved or downloaded")
        // Ready means verified, playable managed audio (Invariant A).
        let rows = try h.repo.rows(playlistID: confirmed.session.destinationPlaylistID!)
        XCTAssertEqual(rows.compactMap(\.playableTrack).count, 2)
        XCTAssertEqual(h.coordinator.displayStates[confirmed.entries[0].id], .availableOffline)
        XCTAssertEqual(h.notifier.authorizationRequests, 1, "Permission is requested once, when real work starts")
    }

    func testDuplicateOccurrencesAndPlaylistsShareOneJobAndOneStoredFile() async throws {
        let h = try harness()
        let a = try await h.playlist("A", [x, y, x])
        let b = try await h.playlist("B", [x])
        try await h.until("Both playlists offline") {
            let first = try await h.allReady(a.session), second = try await h.allReady(b.session)
            return first && second
        }
        await h.settle()
        let jobs = try h.jobs()
        XCTAssertEqual(jobs.count, 2, "One acquisition job per recording identity")
        let awaited2 = try await h.trackCount()
        XCTAssertEqual(awaited2, 2, "One stored audio file per recording")
        let started = await h.transfer.started
        XCTAssertEqual(started.sorted(), [x, y].sorted(), "Each recording is transferred once")
        let aEntries = try await h.entries(a.session), bEntries = try await h.entries(b.session)
        XCTAssertNotEqual(aEntries[0].id, aEntries[2].id, "Repeated occurrences stay distinct rows")
        XCTAssertEqual(aEntries[0].localTrackID, aEntries[2].localTrackID)
        XCTAssertEqual(aEntries[0].localTrackID, bEntries[0].localTrackID, "Playlists share one verified download")
        // Repeated reconciliation (refreshes, relaunches) is idempotent.
        let linksBefore = try await h.links()
        for _ in 0..<3 { await h.coordinator.reconcileNow() }
        await h.relaunch()
        await h.settle()
        XCTAssertEqual(try h.jobs().count, 2)
        let awaited3 = try await h.links().sorted { $0.entryID < $1.entryID }.map(\.state)
        XCTAssertEqual(awaited3, linksBefore.sorted { $0.entryID < $1.entryID }.map(\.state))
        let awaited4 = try await h.trackCount()
        XCTAssertEqual(awaited4, 2)
        let startedAgain = await h.transfer.started
        XCTAssertEqual(startedAgain.count, 2, "Relaunch never acquires completed audio again")
    }

    func testCompletedAndActiveDownloadsAreReusedNotRestarted() async throws {
        let h = try harness(holding: true)
        let a = try await h.playlist("A", [x])
        try await h.until("Transfer started") { await h.transfer.waiting == 1 }
        // A second playlist confirms the same recording while it is downloading.
        let b = try await h.playlist("B", [x])
        await h.settle()
        XCTAssertEqual(try h.jobs().count, 1, "The active job is reused")
        await h.transfer.releaseAll()
        try await h.until("Both ready") {
            let first = try await h.allReady(a.session), second = try await h.allReady(b.session)
            return first && second
        }
        // Completed job + valid library track: a third playlist reuses it without transfer.
        let c = try await h.playlist("C", [x])
        try await h.until("Third playlist ready") { try await h.allReady(c.session) }
        await h.settle()
        let started = await h.transfer.started
        XCTAssertEqual(started, [x], "No completed download is restarted")
        XCTAssertEqual(try h.jobs().first?.state, .completed)
        let awaited5 = try await h.trackCount()
        XCTAssertEqual(awaited5, 1)
    }

    func testOneFailureNeverBlocksTheQueueAndDecisionsSurvive() async throws {
        let h = try harness(limit: 1)
        h.preparer.fail(y, with: .noCompatibleAudio)           // Permanent: unsupported source.
        await h.transfer.fail(z, [.rejected, .rejected])          // Recoverable: succeeds after one automatic retry.
        let p = try await h.playlist("Failures", [x, y, z])
        try await h.until("Healthy songs offline") {
            let entries = try await h.entries(p.session)
            return entries[0].status == .ready && entries[2].status == .ready
        }
        try await h.until("Unsupported source surfaced") {
            if case .unsupported = h.coordinator.displayStates[p.entries[1].id] { return true }
            return false
        }
        await h.settle()
        let entries = try await h.entries(p.session)
        XCTAssertEqual(entries.count, 3, "A failed song is never removed")
        XCTAssertEqual(entries[1].status, .matched, "Failed acquisition keeps the confirmed decision (Invariant G)")
        XCTAssertNil(entries[1].localTrackID)
        let accepted = try await h.repo.candidates(entryID: entries[1].id).filter { $0.decision == .accepted }
        XCTAssertEqual(accepted.map(\.providerTrackID), [y])
        let link = try XCTUnwrap(h.coordinator.link(for: entries[1].id))
        XCTAssertEqual(link.state, .unsupported)
        XCTAssertEqual(link.retries, 0, "Unsupported sources are never retried automatically")
        XCTAssertEqual(h.coordinator.link(for: entries[2].id)?.retries, 1, "A recoverable failure used bounded automatic retry")
        let summary = h.coordinator.summary(for: try XCTUnwrap(h.fixture.storage.playlistMigrations.presentation(p.session)))
        XCTAssertEqual(summary.availableOffline, 2); XCTAssertEqual(summary.unsupported, 1); XCTAssertFalse(summary.complete)
    }

    func testChangedDecisionWhileDownloadingIsNeverAssociated() async throws {
        let h = try harness(holding: true)
        let p = try await h.playlist("Stale", [x])
        try await h.until("Transfer started") { await h.transfer.waiting == 1 }
        let awaited6 = try await h.repo.candidates(entryID: p.entries[0].id).first { $0.decision == .accepted }
        let accepted = try XCTUnwrap(awaited6)
        try await h.repo.rejectCandidate(entryID: p.entries[0].id, candidateID: accepted.id)
        // The download existed only for the superseded decision: it is stopped, not associated.
        try await h.until("Orphaned download paused") { try h.jobs().first?.state == .paused }
        await h.settle()
        var entry = try await h.entries(p.session)[0]
        XCTAssertEqual(entry.status, .needsReview)
        XCTAssertNil(entry.localTrackID)
        let awaited7 = try await h.links().isEmpty
        XCTAssertTrue(awaited7, "The superseded link is removed")

        // A late completion for the old decision (for example a background transfer that
        // finished before the app ran again) is rejected by the stale-decision guard.
        await h.transfer.releaseAll()
        let other = try await h.playlist("Other", [x])
        try await h.until("Recording completed for another playlist") { try await h.allReady(other.session) }
        let otherTrack = try await h.entries(other.session)[0].localTrackID
        let trackID = try XCTUnwrap(otherTrack)
        let outcome = try await h.repo.associateAcquiredTrack(trackID: trackID, occurrences: [(entryID: p.entries[0].id, candidateID: accepted.id)])
        XCTAssertEqual(outcome[p.entries[0].id], .stale, "Invariant H")
        entry = try await h.entries(p.session)[0]
        XCTAssertEqual(entry.status, .needsReview, "The newer decision is never overwritten")
        XCTAssertNil(entry.localTrackID)
        let awaited8 = try await h.trackCount()
        XCTAssertEqual(awaited8, 1, "Completed audio remains in the library")
    }
}

/// Global concurrency, Pause/Continue (including shared consumers), network policy and
/// bounded background execution.
@MainActor final class PlaylistAcquisitionSchedulingTests: XCTestCase {
    func testLimitIsGlobalAcrossOrdinaryAndPlaylistDownloadsAndFollowsChanges() async throws {
        let h = try harness(limit: 1, holding: true)
        h.downloads.enqueue(YouTubeVideo(id: AcquisitionHarness.video(90), title: "Ordinary download"), quality: .standard)
        try await h.until("Ordinary transfer started") { await h.transfer.waiting == 1 }
        let p = try await h.playlist("Limits", (1...3).map(AcquisitionHarness.video))
        try await h.until("Playlist jobs queued") { try h.jobs().count == 4 }
        await h.settle()
        var waiting = await h.transfer.waiting
        XCTAssertEqual(waiting, 1, "Limit 1: an ordinary download occupies the only slot")
        h.prefs.simultaneous = 2
        try await h.until("Second slot used") { await h.transfer.waiting == 2 }
        await h.settle()
        waiting = await h.transfer.waiting
        XCTAssertEqual(waiting, 2, "Limit 2")
        h.prefs.simultaneous = 3
        try await h.until("Third slot used") { await h.transfer.waiting == 3 }
        await h.settle()
        let maxActive = await h.transfer.maxActive
        XCTAssertEqual(maxActive, 3, "Limit 3 is never exceeded")
        // Decrease: running transfers finish, and nothing new starts above the new limit.
        h.prefs.simultaneous = 1
        let before = await h.transfer.activeAtStart.count
        await h.transfer.releaseWaiting()
        try await h.until("Last song started after slots drained") { await h.transfer.waiting == 1 }
        let starts = await h.transfer.activeAtStart
        XCTAssertEqual(Array(starts.dropFirst(before)), [1], "After lowering the limit only one transfer runs")
        await h.transfer.releaseAll()
        try await h.until("Playlist offline") { try await h.allReady(p.session) }
    }

    func testPauseIsDurableAcrossRelaunchAndContinueResumes() async throws {
        let h = try harness(limit: 1, holding: true)
        let videos = (1...4).map(AcquisitionHarness.video)
        let p = try await h.playlist("Pause", [videos[0], videos[1], videos[2], nil])
        let migrationID = p.session.id.uuidString
        // Precondition: every confirmed song is durably enqueued before the pause.
        try await h.until("Three jobs enqueued") { try h.jobs().count == 3 }
        try await h.until("First transfer started") { await h.transfer.waiting == 1 }
        await h.coordinator.pause(migrationID: migrationID)
        try await h.until("All playlist jobs paused") { try h.jobs().allSatisfy { $0.state == .paused } }
        await h.transfer.releaseAll()
        // A song confirmed while paused is queued durably (link) but starts no download.
        try await h.confirm(p.entries[3], video: videos[3])
        try await h.until("Paused confirmation linked") { try await h.links().count == 4 }
        await h.settle()
        var started = await h.transfer.started
        XCTAssertEqual(started.count, 1, "No new download starts while paused")
        XCTAssertEqual(try h.jobs().count, 3, "A paused playlist creates no new download job")
        XCTAssertEqual(h.coordinator.displayStates[p.entries[1].id], .playlistPaused)
        XCTAssertEqual(h.coordinator.displayStates[p.entries[3].id], .playlistPaused)

        // Relaunch: the pause is user intent and is never resumed automatically (Invariant F).
        await h.relaunch()
        await h.settle()
        XCTAssertTrue(h.coordinator.pausedMigrations.contains(migrationID))
        started = await h.transfer.started
        XCTAssertEqual(started.count, 1)
        XCTAssertEqual(try h.jobs().count, 3, "The download queue survives reconstruction")
        XCTAssertTrue(try h.jobs().allSatisfy { $0.state == .paused }, "Paused jobs stay paused after relaunch")
        let links = try await h.links()
        XCTAssertEqual(links.count, 4, "Every confirmed song keeps its durable acquisition link")
        XCTAssertTrue(links.allSatisfy { $0.state == .waiting })
        XCTAssertEqual(links.filter { $0.downloadJobID == nil }.map(\.providerIdentity), [videos[3]])

        await h.coordinator.continueDownloads(migrationID: migrationID)
        try await h.until("Playlist offline after Continue") { try await h.allReady(p.session) }
        XCTAssertFalse(h.coordinator.pausedMigrations.contains(migrationID))
        XCTAssertEqual(try h.jobs().count, 4)
        started = await h.transfer.started
        XCTAssertEqual(Set(started), Set(videos), "Continue resumed every song, including the one confirmed while paused")
    }

    func testPausingOnePlaylistKeepsASharedDownloadRunningForAnother() async throws {
        let h = try harness(holding: true)
        let x = AcquisitionHarness.video(1)
        let a = try await h.playlist("A", [x])
        let b = try await h.playlist("B", [x])
        try await h.until("Shared transfer started") { await h.transfer.waiting == 1 }
        await h.coordinator.pause(migrationID: a.session.id.uuidString)
        await h.settle()
        XCTAssertEqual(try h.jobs().first?.state, .downloading, "Playlist B still needs the shared recording")
        await h.transfer.releaseAll()
        try await h.until("Both occurrences use the one verified result") {
            let first = try await h.allReady(a.session), second = try await h.allReady(b.session)
            return first && second
        }
        let awaited9 = try await h.trackCount()
        XCTAssertEqual(awaited9, 1)
        // With no active consumer left, a shared job created for playlists is paused.
        let y = AcquisitionHarness.video(2)
        await h.transfer.hold(true)
        let c = try await h.playlist("C", [y]), d = try await h.playlist("D", [y])
        try await h.until("Second shared transfer started") { await h.transfer.waiting == 1 }
        await h.coordinator.pause(migrationID: c.session.id.uuidString)
        await h.coordinator.pause(migrationID: d.session.id.uuidString)
        try await h.until("Shared job paused") { try h.jobs().first { $0.sourceIdentifier == y }?.state == .paused }
    }

    func testWiFiOnlyBlocksCellularAndResumesOnWiFiAndStricterPolicyStopsTransfers() async throws {
        let h = try harness(wifiOnly: true, start: false)
        await h.relaunch(wifi: false)
        let p = try await h.playlist("Network", [AcquisitionHarness.video(1)])
        try await h.until("Waiting for Wi-Fi shown") { h.coordinator.displayStates[p.entries[0].id] == .waitingForWiFi }
        await h.settle()
        var started = await h.transfer.started
        XCTAssertTrue(started.isEmpty, "Wi-Fi only never starts cellular acquisition")
        h.downloads.setPath(connected: true, wifi: true)
        try await h.until("Offline after Wi-Fi returns") { try await h.allReady(p.session) }

        // Cellular permitted, then made stricter mid-transfer.
        h.prefs.wifiOnly = false
        h.downloads.setPath(connected: true, wifi: false)
        await h.transfer.hold(true)
        let q = try await h.playlist("Cellular", [AcquisitionHarness.video(2)])
        try await h.until("Cellular transfer started") { await h.transfer.waiting == 1 }
        h.prefs.wifiOnly = true
        try await h.until("Disallowed transfer stopped") { h.coordinator.displayStates[q.entries[0].id] == .waitingForWiFi }
        // A network loss preserves pending work.
        h.downloads.setPath(connected: false, wifi: false)
        await h.transfer.releaseAll()
        await h.settle()
        let awaited10 = try await h.entries(q.session)[0].status
        XCTAssertEqual(awaited10, .matched)
        XCTAssertEqual(try h.jobs().count, 2)
        h.downloads.setPath(connected: true, wifi: true)
        try await h.until("Completed over Wi-Fi") { try await h.allReady(q.session) }
        started = await h.transfer.started
        XCTAssertEqual(started.filter { $0 == AcquisitionHarness.video(2) }.count, 2, "The stopped transfer restarted, never duplicated")
    }

    func testBackgroundSessionEventFillsFreedSlotInsideABoundedWindow() async throws {
        let fixture = try LibraryFixture(count: 0)
        let prefs = YouTubePreferences(defaults: UserDefaults(suiteName: "acquisition-" + UUID().uuidString)!)
        prefs.simultaneous = 1; prefs.wifiOnly = false
        let system = AcquisitionTestSystem(), execution = RecordingBackgroundExecution()
        let manager = DownloadManager(storage: fixture.storage, preferences: prefs, preparer: AcquisitionTestPreparer(), transfer: GatedAcquisitionTransfer(),
                                      artwork: YouTubeArtworkLoader(), observeNetwork: false, system: system, execution: execution)
        addTeardownBlock { await manager.invalidate() }
        manager.setForeground(true)
        manager.setPath(connected: true, wifi: true)
        manager.enqueue(YouTubeVideo(id: AcquisitionHarness.video(1), title: "First"), quality: .standard)
        manager.enqueue(YouTubeVideo(id: AcquisitionHarness.video(2), title: "Second"), quality: .standard)
        for _ in 0..<200 where system.created < 1 { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertEqual(system.created, 1, "Limit 1")
        manager.setForeground(false)
        let first = try XCTUnwrap(system.tasks.first)
        let file = fixture.root.appendingPathComponent("delivered.m4a")
        try AcquisitionToneAudio.write(to: file, seed: 3)
        let bytes = try XCTUnwrap(try file.resourceValues(forKeys: [.fileSizeKey]).fileSize)
        let response = HTTPURLResponse(url: URL(string: "https://rr1---sn-test.googlevideo.com/videoplayback")!, statusCode: 200, httpVersion: nil,
                                       headerFields: ["Content-Type": "audio/mp4", "Content-Length": String(bytes)])
        // iOS wakes the suspended app for the finished transfer.
        manager.backgroundFile(first, response: response, location: file)
        system.tasks.removeAll()
        manager.backgroundEnded(first, failure: nil)
        for _ in 0..<300 where system.created < 2 { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertEqual(system.created, 2, "The freed slot is filled while iOS grants execution")
        XCTAssertEqual(manager.jobs.first { $0.sourceIdentifier == AcquisitionHarness.video(1) }?.state, .completed, "Staged audio verified and imported")
        for _ in 0..<100 where execution.active > 0 { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertEqual(execution.began, 1); XCTAssertEqual(execution.active, 0, "The window ends once no app work remains")
    }
}

/// Launch recovery, verification failures, manual Files fallback and completion notifications.
@MainActor final class PlaylistAcquisitionRecoveryTests: XCTestCase {
    private let x = AcquisitionHarness.video(1), y = AcquisitionHarness.video(2), z = AcquisitionHarness.video(3)

    func testInterruptedProcessIsReconciledAndRepeatedLaunchesAreIdempotent() async throws {
        let h = try harness(limit: 1, holding: true)
        let p = try await h.playlist("Relaunch", [x, y])
        try await h.until("Transfer in flight") { await h.transfer.waiting == 1 }
        // The process dies mid-transfer: its in-flight transfer and work end with it.
        await h.relaunch(transfer: GatedAcquisitionTransfer())
        try await h.until("Recovered playlist offline") { try await h.allReady(p.session) }
        for _ in 0..<2 { await h.relaunch(); await h.settle() }
        XCTAssertEqual(try h.jobs().count, 2, "Recovery never duplicates queue records")
        let awaited11 = try await h.trackCount()
        XCTAssertEqual(awaited11, 2, "Recovery never duplicates files")
        let started = await h.transfer.started
        XCTAssertEqual(started.sorted(), [x, y], "The interrupted recording restarted once; completed audio was not acquired again")
        let awaited12 = try await h.entries(p.session).map(\.position)
        XCTAssertEqual(awaited12, [0, 1])
        XCTAssertEqual(try h.fixture.foreignKeys(), 0)
    }

    func testImportedButUnassociatedTrackIsAssociatedWithoutDownloadingAgain() async throws {
        let h = try harness(start: false)
        // Audio was imported before the process ended; the association never committed.
        h.downloads.enqueue(YouTubeVideo(id: x, title: "Imported earlier"), quality: .standard)
        try await h.until("Earlier download imported") { try h.jobs().first?.state == .completed }
        let p = try await h.playlist("Recover", [x])
        let job = try XCTUnwrap(try h.jobs().first)
        let stamp = Date()
        let awaited13 = try await h.repo.candidates(entryID: p.entries[0].id).first { $0.decision == .accepted }
        let candidate = try XCTUnwrap(awaited13)
        try await h.coordinator.repository.save([AcquisitionLinkRecord(entryID: p.entries[0].id.uuidString, migrationID: p.session.id.uuidString,
            candidateID: candidate.id.uuidString,
            provider: "youtube", providerIdentity: x, downloadJobID: job.id, createdJob: true, state: .associating, trackID: job.trackID,
            failure: nil, retries: 0, nextRetryAt: nil, createdAt: stamp, updatedAt: stamp, completedAt: nil)])
        h.coordinator.start()
        try await h.until("Association recovered") { try await h.allReady(p.session) }
        let started = await h.transfer.started
        XCTAssertEqual(started, [x], "No second transfer")
        let awaited14 = try await h.entries(p.session)[0].localTrackID
        XCTAssertEqual(awaited14, job.trackID)
    }

    func testFailedVerificationNeverMarksReadyAndIdenticalAudioIsStoredOnce() async throws {
        let h = try harness(limit: 1)
        await h.transfer.corrupt(x)
        await h.transfer.seed(y, 42); await h.transfer.seed(z, 42) // Different identities, identical bytes.
        let p = try await h.playlist("Verify", [x, y, z])
        try await h.until("Verified songs offline") {
            let entries = try await h.entries(p.session)
            return entries[1].status == .ready && entries[2].status == .ready
        }
        try await h.until("Corrupt audio failed after its bounded retry") { h.coordinator.link(for: p.entries[0].id)?.state == .failed }
        await h.settle()
        let entries = try await h.entries(p.session)
        XCTAssertEqual(entries[0].status, .matched, "Failed verification never marks an entry ready (Invariant A/B)")
        XCTAssertNil(entries[0].localTrackID)
        let started = await h.transfer.started
        XCTAssertEqual(started.filter { $0 == x }.count, 2, "One automatic retry for a verification failure, then the user decides")
        let awaited15 = try await h.trackCount()
        XCTAssertEqual(awaited15, 1, "Unverified audio never enters the library; identical audio is stored once")
        XCTAssertEqual(entries[1].localTrackID, entries[2].localTrackID, "SHA-256 deduplication reuses the stored file")
        XCTAssertEqual(h.coordinator.displayStates[p.entries[0].id]?.label, "Download failed")
        // An explicit Retry is available and does not disturb completed songs.
        await h.transfer.heal(x); await h.transfer.seed(x, 7)
        await h.coordinator.retry(entryID: p.entries[0].id)
        try await h.until("Retried song offline") { try await h.allReady(p.session) }
        let awaited16 = try await h.trackCount()
        XCTAssertEqual(awaited16, 2)
    }

    func testCompletionNotificationIsAccurateDeduplicatedAndPermissionIndependent() async throws {
        let h = try harness()
        h.notifier.permitted = false // Denied permission never affects downloads.
        h.preparer.fail(z, with: .videoUnavailable)
        let full = try await h.playlist("Full", [x, y])
        let partial = try await h.playlist("Partial", [x, z])
        try await h.until("Full playlist offline") { try await h.allReady(full.session) }
        try await h.until("Partial result reported") { h.notifier.partial.count == 1 }
        await h.settle()
        XCTAssertEqual(h.notifier.ready.count, 1, "Exactly one ready notification, only for the complete playlist")
        XCTAssertTrue(h.notifier.ready[0].contains("All 2 songs in “Full”"))
        XCTAssertTrue(h.notifier.partial[0].contains("1 of 2 songs"))
        XCTAssertTrue(h.notifier.partial[0].contains("1 still need attention"))
        // Relaunch never repeats delivered notifications.
        await h.relaunch()
        await h.settle()
        XCTAssertEqual(h.notifier.ready.count, 1)
        XCTAssertEqual(h.notifier.partial.count, 1)

        // Manual Files fallback resolves the last song; the playlist then becomes eligible.
        let entry = try await h.entries(partial.session)[1]
        let file = h.fixture.root.appendingPathComponent("My Local Copy.m4a")
        try AcquisitionToneAudio.write(to: file, seed: 99)
        let imported = try await h.storage.importAudio(from: file)
        try await h.repo.confirmImportedRecording(for: entry, trackID: imported.track.id)
        try await h.until("Final song completes the playlist") { h.notifier.ready.count == 2 }
        let resolved = try await h.entries(partial.session)
        XCTAssertEqual(resolved.map(\.id), partial.entries.map(\.id), "No new occurrence is created")
        XCTAssertEqual(resolved[1].localTrackID, imported.track.id)
        let candidates = try await h.repo.candidates(entryID: entry.id)
        XCTAssertEqual(candidates.filter { $0.decision == .accepted }.map(\.provider), ["local"])
        XCTAssertEqual(candidates.first { $0.provider == "youtube" }?.evidence["supersededBy"], "local-file", "The YouTube decision is kept as evidence")
        XCTAssertTrue(h.notifier.ready[1].contains("“Partial”"))
        let awaited17 = try await h.allReady(partial.session)
        XCTAssertTrue(awaited17)
    }
}

extension GRDBPlaylistMigrationRepository {
    /// Test convenience: the presentation the playlist screen derives from the snapshot.
    func presentation(_ session: PlaylistMigrationSession) throws -> MigrationPlaylistPresentation? {
        guard let id = session.destinationPlaylistID else { return nil }
        return MigrationPlaylistPresentation(session: session, rows: try rows(playlistID: id), issues: [])
    }
}
