import XCTest
import GRDB
@testable import OFFLINE

final class MigrationPresentationTests: XCTestCase {
    private func source(_ count: Int) -> PlaylistMigrationSourcePlaylist {
        PlaylistMigrationSourcePlaylist(source: .exportify, name: "Repeated source", entries: (0..<count).map {
            PlaylistMigrationSourceTrack(position: $0, title: "Song \($0 % 3)", primaryArtist: "Artist", additionalArtists: ["Guest"], album: "Album", durationMs: 180000, sourceTrackID: "same-recording")
        })
    }
    @MainActor func testEmptyOneFiveHundredAndThousandLogicalRowsAndRestart() async throws {
        for count in [0, 1, 500, 1000] {
            let f = try LibraryFixture(count: 0), input = source(count)
            let session = try await f.storage.playlistMigrations.createPlaylist(from: input, operationID: "presentation-\(count)")
            let id = try XCTUnwrap(session.destinationPlaylistID)
            let library = MusicLibraryService(storage: f.storage, player: nil)
            let value = try XCTUnwrap(library.snapshot.migrationPresentations[id])
            XCTAssertEqual(value.rows.map(\.id), input.entries.map(\.id))
            XCTAssertEqual(value.rows.map { $0.entry.position }, Array(0..<count))
            XCTAssertEqual(value.rowsByID.count, count)
            XCTAssertEqual(value.progress.actual, count); XCTAssertEqual(value.progress.ready, 0)
            XCTAssertEqual(value.progress.unresolved, count); XCTAssertTrue(value.progress.metadataComplete)
            XCTAssertEqual(value.statusCounts[.pending, default: 0], count)
            XCTAssertEqual(value.session.status, .metadataReady)
            XCTAssertFalse(value.session.status.displayName.contains("Downloading"))
            XCTAssertTrue(value.issues.isEmpty); XCTAssertTrue(value.rows.playbackOccurrences.isEmpty)
            XCTAssertTrue(value.rows.allSatisfy { $0.entry.source.artworkURL == nil && $0.playableTrack == nil })
            let reopened = try StorageCoordinator(paths: f.paths)
            let restored = MusicLibraryService(storage: reopened, player: nil)
            XCTAssertEqual(restored.snapshot.migrationPresentations[id], value)
            print("PHASE10.3 logical occurrences=\(count), distinct=\(value.rowsByID.count), restored=true")
        }
    }

    @MainActor func testObservedLegalTransitionsIssuesVerifiedAudioAndMissingFile() async throws {
        let f = try LibraryFixture(count: 1), input = source(5), repo = f.storage.playlistMigrations
        let library = MusicLibraryService(storage: f.storage, player: nil)
        let session = try await repo.createPlaylist(from: input, operationID: "observed")
        let id = try XCTUnwrap(session.destinationPlaylistID), first = input.entries[0].id
        await libraryEventually { library.snapshot.migrationPresentations[id]?.rows.count == 5 }
        let original = library.migrationRows(id).map(\.id)
        try await repo.updateStatus(migrationID: session.id, to: .matching, failureInformation: nil)
        try await repo.updateEntryStatus(entryID: first, to: .matching)
        await libraryEventually { library.snapshot.migrationPresentations[id]?.statusCounts[.matching] == 1 }
        XCTAssertEqual(library.snapshot.migrationPresentations[id]?.session.status, .matching)
        try await repo.updateEntryStatus(entryID: first, to: .needsReview)
        await libraryEventually { library.snapshot.migrationPresentations[id]?.progress.needsReview == 1 }
        let issue = PlaylistMigrationIssue(id: UUID(), migrationID: session.id, entryID: first, code: "review", message: "Recording requires review.", technicalDetails: "Synthetic persisted issue", severity: .warning, resolution: .open, createdAt: Date(), resolvedAt: nil)
        try await repo.saveIssue(issue)
        await libraryEventually { library.snapshot.migrationPresentations[id]?.issuesByEntry[first]?.first?.id == issue.id }
        try await repo.resolveIssue(id: issue.id, resolution: .resolved)
        await libraryEventually { library.snapshot.migrationPresentations[id]?.issues.first?.resolution == .resolved }
        try await repo.updateEntryStatus(entryID: first, to: .matched)
        try await repo.associateVerifiedTrack(entryID: first, trackID: f.ids[0])
        await libraryEventually { library.snapshot.migrationPresentations[id]?.progress.ready == 1 }
        XCTAssertEqual(library.migrationRows(id).map(\.id), original)
        XCTAssertEqual(library.migrationRows(id)[0].entry.source, input.entries[0])
        XCTAssertEqual(library.migrationRows(id).playbackOccurrences.map(\.id), [first.uuidString])
        try await repo.updateEntryStatus(entryID: input.entries[1].id, to: .failed)
        try await repo.updateEntryStatus(entryID: input.entries[2].id, to: .skipped)
        await libraryEventually { library.snapshot.migrationPresentations[id]?.progress.failed == 1 && library.snapshot.migrationPresentations[id]?.progress.skipped == 1 }
        let other = try await repo.createPlaylist(from: source(1), operationID: "other")
        let otherID = try XCTUnwrap(other.destinationPlaylistID)
        await libraryEventually { library.snapshot.migrationPresentations[otherID] != nil }
        XCTAssertTrue(library.snapshot.migrationPresentations[otherID]?.issues.isEmpty == true)
        let reopened = try StorageCoordinator(paths: f.paths)
        let restored = MusicLibraryService(storage: reopened, player: nil)
        XCTAssertEqual(restored.snapshot.migrationPresentations[id], library.snapshot.migrationPresentations[id])
        try FileManager.default.removeItem(at: f.file(0))
        // A fresh snapshot must distrust ready even before recovery persists unavailable.
        let missing = MusicLibraryService(storage: f.storage, player: nil)
        XCTAssertEqual(missing.migrationRows(id)[0].effectiveStatus, .unavailable)
        XCTAssertNil(missing.migrationRows(id)[0].playableTrack)
        try await Task.detached { try repo.recover() }.value
        await libraryEventually { library.snapshot.migrationPresentations[id]?.progress.ready == 0 && library.snapshot.migrationPresentations[id]?.progress.unavailable == 1 }
        XCTAssertEqual(library.migrationRows(id).map(\.id), original)
        try await repo.deleteSession(id: session.id)
        await libraryEventually { library.snapshot.migrationPresentations[id] == nil }
        XCTAssertTrue(library.migrationRows(id).isEmpty)
    }

    @MainActor func testPersistedAvailabilityChangeAndRepeatedReadyOccurrences() async throws {
        let f = try LibraryFixture(count: 1), input = source(5), repo = f.storage.playlistMigrations
        let session = try await repo.createPlaylist(from: input, operationID: "mixed")
        let id = try XCTUnwrap(session.destinationPlaylistID)
        let library = MusicLibraryService(storage: f.storage, player: nil)
        for position in [0, 2, 4] { try await repo.associateVerifiedTrack(entryID: input.entries[position].id, trackID: f.ids[0]) }
        await libraryEventually { library.snapshot.migrationPresentations[id]?.progress.ready == 3 }
        XCTAssertEqual(library.migrationRows(id).playbackOccurrences.map(\.id), [0, 2, 4].map { input.entries[$0].id.uuidString })
        var track = try XCTUnwrap(f.storage.tracks.find(id: f.ids[0]))
        track.availability = .missing
        try f.storage.tracks.save(track)
        await libraryEventually { library.snapshot.migrationPresentations[id]?.progress.ready == 0 }
        XCTAssertEqual(library.snapshot.migrationPresentations[id]?.progress.unavailable, 3)
        XCTAssertEqual(library.migrationRows(id).map(\.id), input.entries.map(\.id))
    }
}
