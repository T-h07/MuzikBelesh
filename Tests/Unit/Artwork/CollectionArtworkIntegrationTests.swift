import Combine
import Foundation
import GRDB
import XCTest
@testable import OFFLINE

/// Phase 11.5 end to end with the real library service, storage and managed-file workflow.
@MainActor
final class CollectionArtworkIntegrationTests: XCTestCase {
    private func fixture(_ count: Int = 6) throws -> LibraryFixture {
        let fixture = try LibraryFixture(count: count)
        retainUntilTeardown(fixture)
        for index in 0..<count { try fixture.setTrackArtwork("cover-\(index).jpg", index) }
        return fixture
    }

    func testAddingAndRemovingSongsUpdatesTheMosaic() async throws {
        let f = try fixture()
        let (_, _, library) = f.services()
        let playlist = try f.repository.createPlaylist(name: "Growing")
        let artwork = f.artworkService(library: library)
        let identity = CollectionArtworkIdentity.playlist(playlist.id)
        await libraryEventually { artwork.entries[identity] != nil }
        XCTAssertEqual(artwork.presentation(for: identity), .placeholder, "An empty playlist shows the standard placeholder")
        try f.repository.addTracks([f.ids[0], f.ids[1]], playlistID: playlist.id)
        await libraryEventually { artwork.entry(for: identity).candidates.count == 2 }
        guard case .mosaic(let partial) = artwork.presentation(for: identity) else { return XCTFail("Partial mosaic expected") }
        XCTAssertEqual(partial.coverCount, 2)
        try f.repository.removeTrack(f.ids[0], playlistID: playlist.id)
        await libraryEventually { artwork.entry(for: identity).candidates == ["cover-1.jpg"] }
        try f.setTrackArtwork("cover-new.jpg", 1) // Song artwork replaced.
        await libraryEventually { artwork.entry(for: identity).candidates == ["cover-new.jpg"] }
        try f.setTrackArtwork(nil, 1) // Song artwork removed.
        await libraryEventually { artwork.entry(for: identity).candidates.isEmpty }
        XCTAssertEqual(artwork.presentation(for: identity), .placeholder)
    }

    func testImportedPlaceholderGainsArtworkWhenItsRecordingArrives() async throws {
        let f = try fixture()
        let (_, _, library) = f.services()
        let source = PlaylistMigrationSourcePlaylist(source: .muzikBelesh, name: "Shared With Me", entries: (0..<3).map {
            PlaylistMigrationSourceTrack(position: $0, title: "Shared \($0)", primaryArtist: "Friend")
        })
        let session = try f.storage.playlistMigrations.createCommittedPlaylist(from: source, operationID: "artwork-arrival")
        let identity = CollectionArtworkIdentity.playlist(try XCTUnwrap(session.destinationPlaylistID))
        let artwork = f.artworkService(library: library)
        await libraryEventually { artwork.entries[identity] != nil }
        XCTAssertTrue(artwork.entry(for: identity).candidates.isEmpty, "Unresolved placeholders never fetch remote artwork")
        try resolve(session.id, position: 1, trackID: f.ids[3], f)
        await libraryEventually { artwork.entry(for: identity).candidates == ["cover-3.jpg"] }
    }

    private func resolve(_ migration: UUID, position: Int, trackID: String, _ f: LibraryFixture) throws {
        try f.storage.database.dbQueue.write { db in
            try db.execute(sql: "UPDATE migration_entries SET localTrackID = ?, status = 'ready' WHERE migrationID = ? AND sourcePosition = ?",
                           arguments: [trackID, migration.uuidString, position])
        }
    }

    func testCustomCoverTakesPriorityAndRemovingItRevealsTheMosaic() async throws {
        let f = try fixture()
        let (_, _, library) = f.services()
        let playlist = try f.repository.createPlaylist(name: "Covered", description: "Keep me")
        try f.repository.addTracks(f.ids, playlistID: playlist.id)
        let artwork = f.artworkService(library: library)
        let identity = CollectionArtworkIdentity.playlist(playlist.id)
        try await library.setCollectionCover(identity, artworkData: LibraryFixture.image())
        let stored = try XCTUnwrap(try playlistRecord(playlist.id, f)?.artworkRelativePath)
        XCTAssertTrue(FileManager.default.fileExists(atPath: try f.paths.artworkURL(relativePath: stored).path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: try f.paths.artworkURL(relativePath: ManagedLibraryFiles.thumbnailName(stored)).path))
        await libraryEventually { artwork.presentation(for: identity) == .custom(stored) }
        artwork.setMode(.automatic, for: identity)
        XCTAssertEqual(artwork.presentation(for: identity), .custom(stored), "Enabling mosaics never replaces a custom cover")
        XCTAssertEqual(try playlistRecord(playlist.id, f)?.artworkRelativePath, stored, "Toggling never deletes a custom cover")

        try await library.setCollectionCover(identity, artworkData: nil)
        await libraryEventually { if case .mosaic = artwork.presentation(for: identity) { return true }; return false }
        XCTAssertFalse(FileManager.default.fileExists(atPath: try f.paths.artworkURL(relativePath: stored).path), "An unreferenced custom cover is cleaned up")
        let record = try XCTUnwrap(try playlistRecord(playlist.id, f))
        XCTAssertEqual(record.name, "Covered"); XCTAssertEqual(record.description, "Keep me")
        XCTAssertEqual(try f.repository.snapshot().memberships.filter { $0.playlistID == playlist.id }.map(\.trackID), f.ids)
        XCTAssertEqual(try f.artworkCount("SELECT COUNT(*) FROM library_file_operations"), 0, "The journal is finished")
        artwork.setMode(.staticArtwork, for: identity)
        XCTAssertEqual(artwork.presentation(for: identity), .single("cover-0.jpg"), "Static mode shows the legacy first song cover")
    }

    func testRemovingACustomCoverKeepsArtworkStillUsedBySongs() async throws {
        let f = try fixture(2)
        let (_, _, library) = f.services()
        let playlist = try f.repository.createPlaylist(name: "Shared Cover")
        let identity = CollectionArtworkIdentity.playlist(playlist.id)
        try await library.setCollectionCover(identity, artworkData: LibraryFixture.image())
        let stored = try XCTUnwrap(try playlistRecord(playlist.id, f)?.artworkRelativePath)
        try f.setTrackArtwork(stored, 0)
        try await library.setCollectionCover(identity, artworkData: nil)
        XCTAssertNil(try playlistRecord(playlist.id, f)?.artworkRelativePath)
        XCTAssertTrue(FileManager.default.fileExists(atPath: try f.paths.artworkURL(relativePath: stored).path), "Reference counting keeps a cover a song still uses")
    }

    func testReplacingACustomCoverCleansUpTheOldOne() async throws {
        let f = try fixture(1)
        let (_, _, library) = f.services()
        let playlist = try f.repository.createPlaylist(name: "Replace")
        let identity = CollectionArtworkIdentity.playlist(playlist.id)
        try await library.setCollectionCover(identity, artworkData: LibraryFixture.image())
        let old = try XCTUnwrap(try playlistRecord(playlist.id, f)?.artworkRelativePath)
        try await library.setCollectionCover(identity, artworkData: LibraryFixture.image(png: false))
        let new = try XCTUnwrap(try playlistRecord(playlist.id, f)?.artworkRelativePath)
        XCTAssertNotEqual(old, new)
        XCTAssertFalse(FileManager.default.fileExists(atPath: try f.paths.artworkURL(relativePath: old).path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: try f.paths.artworkURL(relativePath: new).path))
    }

    func testAlbumCoverChangesTouchOnlyTheCover() async throws {
        let f = try fixture()
        let (_, _, library) = f.services()
        let album = try f.repository.saveAlbum(draft: AlbumDraft(title: "Kept", artist: "Kept Artist", releaseYear: 2001, description: "Notes"), trackIDs: [f.ids[0], f.ids[1]])
        let before = try XCTUnwrap(try albumRecord(album.id, f))
        try await library.setCollectionCover(.album(album.id), artworkData: LibraryFixture.image())
        var after = try XCTUnwrap(try albumRecord(album.id, f))
        XCTAssertNotNil(after.artworkRelativePath)
        after.artworkRelativePath = nil; after.dateModified = before.dateModified
        XCTAssertEqual(after, before, "Title, artist, year, description and management source are unchanged")
        XCTAssertEqual(try albumTrackIDs(album.id, f), [f.ids[0], f.ids[1]])
        do { try await library.setCollectionCover(.artist("anyone"), artworkData: LibraryFixture.image()); XCTFail("Artists have no custom cover") }
        catch { XCTAssertEqual(error as? CollectionArtworkPreferenceError, .unsupportedCollection) }
        do { try await library.setCollectionCover(.playlist("missing"), artworkData: LibraryFixture.image()); XCTFail("Missing playlist") }
        catch { XCTAssertEqual(error as? LibraryError, .notFound) }
        XCTAssertEqual(try f.artworkCount("SELECT COUNT(*) FROM library_file_operations"), 0)
    }

    private func albumRecord(_ id: String, _ f: LibraryFixture) throws -> StoredAlbum? {
        try f.storage.database.dbQueue.read { try StoredAlbum.fetchOne($0, key: id) }
    }
    private func playlistRecord(_ id: String, _ f: LibraryFixture) throws -> StoredPlaylist? {
        try f.storage.database.dbQueue.read { try StoredPlaylist.fetchOne($0, key: id) }
    }
    private func albumTrackIDs(_ id: String, _ f: LibraryFixture) throws -> [String] {
        try f.storage.database.dbQueue.read { try String.fetchAll($0, sql: "SELECT id FROM tracks WHERE albumID = ? ORDER BY id", arguments: [id]) }
    }

    func testDeletingAPlaylistRemovesItsArtworkAndPreference() async throws {
        let f = try fixture()
        let (_, _, library) = f.services()
        let playlist = try f.repository.createPlaylist(name: "Short Lived")
        try f.repository.addTracks(f.ids, playlistID: playlist.id)
        let artwork = f.artworkService(library: library)
        let identity = CollectionArtworkIdentity.playlist(playlist.id)
        await libraryEventually { artwork.entry(for: identity).candidates.count == 6 }
        artwork.setMode(.staticArtwork, for: identity)
        try await library.deletePlaylist(id: playlist.id, confirmed: true)
        await libraryEventually { artwork.entries[identity] == nil && artwork.preferences[identity] == nil }
        XCTAssertEqual(artwork.presentation(for: identity), .placeholder)
        XCTAssertEqual(try f.preferenceRows(), 0)
        let recreated = try f.repository.createPlaylist(name: "Short Lived")
        XCTAssertEqual(artwork.mode(for: .playlist(recreated.id)), .appDefault, "A new collection starts with the app default")
    }

    func testMissingOrCorruptArtworkIsSkippedAndRecomputed() async throws {
        let f = try fixture(5)
        let (_, _, library) = f.services()
        let playlist = try f.repository.createPlaylist(name: "Broken")
        try f.repository.addTracks(f.ids, playlistID: playlist.id)
        let artwork = f.artworkService(library: library)
        let identity = CollectionArtworkIdentity.playlist(playlist.id)
        await libraryEventually { artwork.entry(for: identity).candidates.count == 5 }
        artwork.reportUnusable("cover-2.jpg")
        await libraryEventually { artwork.entry(for: identity).candidates.count == 4 }
        XCTAssertFalse(artwork.entry(for: identity).candidates.contains("cover-2.jpg"))
        guard case .mosaic(let selection) = artwork.presentation(for: identity) else { return XCTFail("Mosaic expected") }
        XCTAssertFalse(selection.tiles.contains("cover-2.jpg"))
        artwork.setForeground(false)
        artwork.setForeground(true) // Recovery may restore files: unusable paths are retried.
        await libraryEventually { artwork.entry(for: identity).candidates.count == 5 }
        artwork.setForeground(false)
    }

    func testUnrelatedLibraryChangesDoNotRepublishArtwork() async throws {
        let f = try fixture()
        let (_, _, library) = f.services()
        let playlist = try f.repository.createPlaylist(name: "Stable")
        try f.repository.addTracks(f.ids, playlistID: playlist.id)
        let artwork = f.artworkService(library: library)
        await libraryEventually { artwork.entry(for: .playlist(playlist.id)).candidates.count == 6 }
        await artwork.waitForRebuild()
        let presentation = artwork.presentation(for: .playlist(playlist.id))
        var publications = 0
        let subscription = artwork.$entries.dropFirst().sink { _ in publications += 1 }
        defer { subscription.cancel() }
        let rebuilds = artwork.rebuildCount
        try f.repository.updatePlaylist(id: playlist.id, name: "Renamed", description: "")
        try f.repository.setLiked(true, trackID: f.ids[0])
        await libraryEventually { artwork.rebuildCount > rebuilds }
        await artwork.waitForRebuild()
        XCTAssertEqual(publications, 0, "A rename or a like does not change artwork eligibility")
        XCTAssertEqual(artwork.presentation(for: .playlist(playlist.id)), presentation)
    }

    func testArtworkWorkNeverMutatesTheLibrary() async throws {
        let f = try fixture()
        let (_, _, library) = f.services()
        let playlist = try f.repository.createPlaylist(name: "Untouched")
        try f.repository.addTracks(f.ids, playlistID: playlist.id)
        try ArtworkTestFiles.write("cover-0.jpg", paths: f.paths)
        let clock = ArtworkTestClock(Date(timeIntervalSince1970: 1_700_000_000))
        let images = ArtworkImagePipeline()
        let artwork = f.artworkService(library: library, clock: clock, images: images)
        await libraryEventually { artwork.entry(for: .playlist(playlist.id)).candidates.count == 6 }
        let before = try ReleaseIntegritySnapshot.capture(f.storage.database.dbQueue, paths: f.paths)
        let identity = CollectionArtworkIdentity.playlist(playlist.id)
        for _ in 0..<5 {
            _ = artwork.presentation(for: identity)
            artwork.refresh(identity)
            clock.advance(CollectionArtworkService.defaultInterval)
            artwork.reconcileEpoch()
        }
        artwork.setForeground(false); artwork.setForeground(true)
        _ = await images.load(path: "cover-0.jpg", bucket: 128, paths: f.paths)
        _ = await images.load(path: "cover-5.jpg", bucket: 128, paths: f.paths)
        artwork.reportUnusable("cover-5.jpg")
        await libraryEventually { artwork.entry(for: identity).candidates.count == 5 }
        let after = try ReleaseIntegritySnapshot.capture(f.storage.database.dbQueue, paths: f.paths)
        XCTAssertEqual(after, before, "Audio, metadata, order, membership, queue, downloads, statistics and covers are unchanged: \(before) → \(after)")
        artwork.setForeground(false)
    }

    func testRotationAndSettingsNeverTouchPlayback() async throws {
        let f = try fixture()
        let (player, transport, library) = f.services()
        let playlist = try f.repository.createPlaylist(name: "Now Playing")
        try f.repository.addTracks(f.ids, playlistID: playlist.id)
        try await player.play(trackID: f.ids[0], contextTrackIDs: f.ids, contextKind: "playlist", contextSourceID: playlist.id)
        let generation = player.activeItemGeneration
        let replacements = transport.replacements
        let queue = player.queue.contextTrackIDs
        let clock = ArtworkTestClock(Date(timeIntervalSince1970: 1_700_000_000))
        let artwork = f.artworkService(library: library, clock: clock)
        await libraryEventually { artwork.entry(for: .playlist(playlist.id)).candidates.count == 6 }
        clock.advance(CollectionArtworkService.defaultInterval); artwork.reconcileEpoch()
        artwork.setMode(.staticArtwork, for: .playlist(playlist.id))
        artwork.setAutomaticByDefault(false)
        artwork.refresh(.playlist(playlist.id))
        artwork.setForeground(false); artwork.setForeground(true)
        XCTAssertEqual(player.activeItemGeneration, generation, "The current item is never replaced")
        XCTAssertEqual(transport.replacements, replacements)
        XCTAssertTrue(transport.isPlaying)
        XCTAssertEqual(player.state.currentTrackID, f.ids[0])
        XCTAssertEqual(player.queue.contextTrackIDs, queue)
        player.stop(); artwork.setForeground(false)
    }
}
