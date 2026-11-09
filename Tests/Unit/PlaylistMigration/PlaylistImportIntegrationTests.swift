import Foundation
import GRDB
import XCTest
@testable import OFFLINE

final class PlaylistImportIntegrationTests: XCTestCase {
    private typealias F = PlaylistImportFixtures
    private func count(_ table: String, _ fixture: LibraryFixture) throws -> Int {
        try fixture.storage.database.dbQueue.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM \(table)")! }
    }

    func testFiveHundredAndThousandFileImportsPersistOrderedOccurrencesAcrossRestart() async throws {
        for size in [500, 1000] {
            let fixture = try LibraryFixture(count: 0)
            let url = fixture.paths.documents.appendingPathComponent("Source.csv")
            try F.csv(size).write(to: url)
            let report = try await F.importer(fixture).prepare(file: url)
            let candidate = try XCTUnwrap(report.candidates.first)
            let coordinator = PlaylistImportCoordinator(persistence: fixture.storage.playlistMigrations)
            let result = try await coordinator.commit(candidate, destinationName: "Reviewed destination")
            let session = result.session
            XCTAssertFalse(result.existing)
            let entries = try await fixture.storage.playlistMigrations.entries(migrationID: session.id)
            XCTAssertEqual(entries.count, size)
            XCTAssertEqual(entries.map(\.position), Array(0..<size))
            XCTAssertEqual(entries.map(\.source), candidate.source?.entries)
            XCTAssertEqual(Set(entries.map(\.id)).count, size)
            XCTAssertEqual(Set(entries.compactMap { $0.source.sourceTrackID }).count, 1)
            XCTAssertTrue(entries.allSatisfy { $0.status == .pending && $0.localTrackID == nil })
            let progress = try await fixture.storage.playlistMigrations.progress(migrationID: session.id)
            XCTAssertTrue(progress.metadataComplete); XCTAssertFalse(progress.audioComplete); XCTAssertEqual(progress.ready, 0)
            let rows = try fixture.storage.playlistMigrations.rows(playlistID: XCTUnwrap(session.destinationPlaylistID))
            XCTAssertEqual(rows.count, size); XCTAssertTrue(rows.playbackOccurrences.isEmpty)
            XCTAssertEqual(try count("tracks", fixture), 0); XCTAssertEqual(try count("playlist_tracks", fixture), 0)
            XCTAssertEqual(try count("migration_candidates", fixture), 0)
            let reopened = try StorageCoordinator(paths: fixture.paths)
            let restored = try await reopened.playlistMigrations.entries(migrationID: session.id)
            XCTAssertEqual(restored, entries)
            let destination = try await reopened.database.dbQueue.read { try StoredPlaylist.fetchOne($0, key: session.destinationPlaylistID) }
            XCTAssertEqual(destination?.name, "Reviewed destination")
            XCTAssertEqual(session.sourcePlaylistName, "Source")
            XCTAssertEqual(try fixture.foreignKeys(), 0)
        }
    }

    func testJSONThousandOccurrencesUseTheSamePersistencePipeline() async throws {
        let fixture = try LibraryFixture(count: 0)
        let candidate = try XCTUnwrap(F.parse(F.json([F.playlist(1000)]), filename: "Playlist1.json").candidates.first)
        let result = try await PlaylistImportCoordinator(persistence: fixture.storage.playlistMigrations).commit(candidate, destinationName: candidate.name)
        let entries = try await fixture.storage.playlistMigrations.entries(migrationID: result.session.id)
        XCTAssertEqual(entries.count, 1000); XCTAssertEqual(entries.map(\.position), Array(0..<1000))
        XCTAssertEqual(try count("tracks", fixture), 0)
    }

    func testRetryIsIdempotentDespiteNewOccurrenceUUIDsAndDestinationRename() async throws {
        let fixture = try LibraryFixture(count: 0)
        let first = try XCTUnwrap(F.parse(F.csv(5)).candidates.first)
        let second = try XCTUnwrap(F.parse(F.csv(5)).candidates.first)
        XCTAssertNotEqual(first.source?.entries[0].id, second.source?.entries[0].id)
        XCTAssertEqual(first.operationID, second.operationID)
        let coordinator = PlaylistImportCoordinator(persistence: fixture.storage.playlistMigrations)
        let created = try await coordinator.commit(first, destinationName: "Renamed destination")
        let retried = try await coordinator.commit(second, destinationName: "Do not rename an existing import")
        XCTAssertEqual(created.session, retried.session); XCTAssertTrue(retried.existing)
        XCTAssertEqual(try count("playlists", fixture), 1); XCTAssertEqual(try count("migration_entries", fixture), 5)
        let destination = try fixture.repository.snapshot().playlists.first
        XCTAssertEqual(destination?.name, "Renamed destination")
    }

    func testChangedContentIsSeparateAndForcedOperationConflictRollsBack() async throws {
        let fixture = try LibraryFixture(count: 0)
        let original = try XCTUnwrap(F.parse(F.csv(2)).candidates.first)
        let changed = try XCTUnwrap(F.parse(F.csv(3)).candidates.first)
        let coordinator = PlaylistImportCoordinator(persistence: fixture.storage.playlistMigrations)
        _ = try await coordinator.commit(original, destinationName: original.name)
        let review = try await coordinator.review(F.parse(F.csv(3)))
        XCTAssertEqual(Array(review.values), [.changed])
        XCTAssertNotEqual(original.operationID, changed.operationID)
        do {
            _ = try await fixture.storage.playlistMigrations.createPlaylist(from: XCTUnwrap(changed.source), operationID: XCTUnwrap(original.operationID))
            XCTFail("Conflicting operation was accepted")
        } catch { XCTAssertEqual(error as? PlaylistMigrationStorageError, .operationConflict) }
        XCTAssertEqual(try count("playlists", fixture), 1)
        _ = try await coordinator.commit(changed, destinationName: changed.name)
        XCTAssertEqual(try count("playlists", fixture), 2); XCTAssertEqual(try count("migration_entries", fixture), 5)
    }

    func testRenamedFallbackExportSurfacesAmbiguityWithoutCreatingDuplicate() async throws {
        let fixture = try LibraryFixture(count: 0)
        let coordinator = PlaylistImportCoordinator(persistence: fixture.storage.playlistMigrations)
        let first = try XCTUnwrap(F.parse(F.csv(2), filename: "First.csv").candidates.first)
        _ = try await coordinator.commit(first, destinationName: first.name)
        let report = try F.parse(F.csv(2), filename: "Renamed.csv")
        let second = try XCTUnwrap(report.candidates.first)
        let status = try await coordinator.review(report)
        XCTAssertEqual(status[second.id], .ambiguous)
        do { _ = try await coordinator.commit(second, destinationName: second.name); XCTFail("Ambiguity silently imported") }
        catch { XCTAssertTrue(error is PlaylistImportProblem) }
        // The repository also enforces ambiguity atomically if review was bypassed.
        do {
            _ = try await fixture.storage.playlistMigrations.createPlaylist(from: XCTUnwrap(second.source), operationID: XCTUnwrap(second.operationID))
            XCTFail("Atomic ambiguity check bypassed")
        } catch { XCTAssertTrue(error is PlaylistImportProblem) }
        XCTAssertEqual(try count("playlists", fixture), 1)
    }

    func testTrustedPlaylistURIIsStableAcrossFileRename() throws {
        var playlist = F.playlist(3); playlist["playlistUri"] = "spotify:playlist:0000000000000000000003"
        let bytes = try F.json([playlist])
        let a = try F.parse(bytes, filename: "Playlist1.json")
        let b = try F.parse(bytes, filename: "Renamed.json")
        XCTAssertEqual(a.candidates[0].operationID, b.candidates[0].operationID)
    }

    func testZIPCommitsValidPlaylistsIndependentlyAndRetainsSameNameMembers() async throws {
        let fixture = try LibraryFixture(count: 0)
        let archive = try F.zip([("one/Same.csv", F.csv(500)), ("two/Same.csv", F.csv(500)), ("Bad.csv", Data("Track Name\n\n".utf8))])
        let report = try F.parse(archive, filename: "Batch.zip")
        XCTAssertEqual(report.validCount, 2)
        let coordinator = PlaylistImportCoordinator(persistence: fixture.storage.playlistMigrations)
        for candidate in report.candidates where candidate.source != nil { _ = try await coordinator.commit(candidate, destinationName: candidate.name) }
        XCTAssertEqual(try count("playlists", fixture), 2); XCTAssertEqual(try count("migration_entries", fixture), 1000)
        for candidate in try F.parse(archive, filename: "Batch.zip").candidates where candidate.source != nil {
            let result = try await coordinator.commit(candidate, destinationName: candidate.name)
            XCTAssertTrue(result.existing)
        }
        XCTAssertEqual(try count("playlists", fixture), 2)
    }

    func testMidTransactionFailureRollsBackOnlyAffectedPlaylistAndPreservesOrdinaryLibrary() async throws {
        let fixture = try LibraryFixture(count: 1)
        let ordinary = try fixture.repository.createPlaylist(name: "Ordinary")
        try fixture.repository.addTracks(fixture.ids, playlistID: ordinary.id)
        let before = try fixture.repository.snapshot().playlistTracks(ordinary.id)
        try await fixture.storage.database.dbQueue.write { db in
            try db.execute(sql: "CREATE TEMP TRIGGER fail_import BEFORE INSERT ON migration_entries WHEN NEW.sourcePosition = 2 BEGIN SELECT RAISE(ABORT, 'synthetic failure'); END")
        }
        let report = try F.parse(F.zip([("A.csv", F.csv(2)), ("B.csv", F.csv(3)), ("C.csv", F.csv(1))]), filename: "Batch.zip")
        let coordinator = PlaylistImportCoordinator(persistence: fixture.storage.playlistMigrations)
        var successes = 0, failures = 0
        for candidate in report.candidates {
            do { _ = try await coordinator.commit(candidate, destinationName: candidate.name); successes += 1 }
            catch { failures += 1 }
        }
        XCTAssertEqual(successes, 2); XCTAssertEqual(failures, 1)
        XCTAssertEqual(try count("playlists", fixture), 3); XCTAssertEqual(try count("playlist_migrations", fixture), 2)
        XCTAssertEqual(try count("migration_entries", fixture), 3); XCTAssertEqual(try count("tracks", fixture), 1)
        XCTAssertEqual(try fixture.repository.snapshot().playlistTracks(ordinary.id), before)
        XCTAssertEqual(try count("grdb_migrations", fixture), 13); XCTAssertEqual(try fixture.foreignKeys(), 0)
    }

    func testCancelledCommitCreatesNothingAndStrictFileContractRejectsPartialReport() async throws {
        let fixture = try LibraryFixture(count: 0)
        let candidate = try XCTUnwrap(F.parse(F.csv(5)).candidates.first)
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await PlaylistImportCoordinator(persistence: fixture.storage.playlistMigrations).commit(candidate, destinationName: candidate.name)
        }
        do { _ = try await task.value; XCTFail("Cancellation ignored") } catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(try count("playlists", fixture), 0)
        let url = fixture.paths.documents.appendingPathComponent("Playlist1.json")
        try F.json([F.playlist(2), ["name": "Bad", "items": [["episode": [:]]]]]).write(to: url)
        do { _ = try await F.importer(fixture).playlists(from: url); XCTFail("Partial snapshot escaped strict contract") }
        catch { XCTAssertTrue(error is PlaylistImportProblem) }
        XCTAssertEqual(try count("playlists", fixture), 0)
    }
}
