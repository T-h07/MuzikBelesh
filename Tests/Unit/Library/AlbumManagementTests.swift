import XCTest
import GRDB
import SwiftUI
import AVFoundation
@testable import OFFLINE

final class AlbumManagementTests: XCTestCase {
    private func order(_ f: LibraryFixture, _ album: String) throws -> [String] {
        try f.storage.database.dbQueue.read { try LibraryRepository.albumTrackIDs(album, db: $0) }
    }
    func testCreateEmptyAlbumAndDuplicateNamesHaveIndependentStableIdentities() throws {
        let f = try LibraryFixture()
        let a = try f.repository.saveAlbum(draft: AlbumDraft(title: "夜 Café", artist: "Beyoncé"))
        let b = try f.repository.saveAlbum(draft: AlbumDraft(title: "夜 Café", artist: "Beyoncé"))
        XCTAssertNotEqual(a.id, b.id)
        let snapshot = try f.repository.snapshot()
        XCTAssertEqual(snapshot.albumGroups.filter { $0.title == "夜 Café" }.count, 2)
        XCTAssertEqual(snapshot.albumGroups.first { $0.id == a.id }?.count, 0)
        XCTAssertEqual(LibrarySearchEngine.search("beyonce", in: snapshot).albums.count, 2)
        XCTAssertTrue(snapshot.artistGroups.contains { $0.title == "Beyoncé" })
    }
    func testAddRenameArtistYearDescriptionAndSearchUpdatePrimaryMetadata() throws {
        let f = try LibraryFixture()
        let a = try f.repository.saveAlbum(draft: AlbumDraft(title: "Before"), trackIDs: Array(f.ids.prefix(3)))
        let updated = try f.repository.saveAlbum(id: a.id, draft: AlbumDraft(title: "Été 夜 100%_", artist: "Album Artist", releaseYear: 2026, description: "Summer collection"))
        XCTAssertEqual(updated.id, a.id); XCTAssertEqual(updated.releaseYear, 2026); XCTAssertEqual(updated.description, "Summer collection")
        XCTAssertEqual(try order(f, a.id), Array(f.ids.prefix(3)))
        for id in f.ids.prefix(3) {
            let song = try XCTUnwrap(f.storage.tracks.find(id: id))
            XCTAssertEqual(song.albumID, a.id); XCTAssertEqual(song.albumArtist, "Album Artist")
        }
        let snapshot = try f.repository.snapshot()
        XCTAssertTrue(LibrarySearchEngine.search("before", in: snapshot).albums.isEmpty)
        for term in ["ete 夜", "album artist", "summer", "2026", "%", "_"] { XCTAssertEqual(LibrarySearchEngine.search(term, in: snapshot).albums.map(\.id), [a.id]) }
        XCTAssertEqual(try f.repository.search("ete 夜", sort: .newest).count, 3)
    }
    func testReorderMoveAndRemovePreserveAudioLikesAndPlaylists() throws {
        let f = try LibraryFixture()
        let before = try f.storage.tracks.all(); let bytes = try (0..<4).map { try Data(contentsOf: f.file($0)) }
        let playlist = try f.repository.createPlaylist(name: "Keep")
        try f.repository.addTracks(f.ids, playlistID: playlist.id); try f.repository.setLiked(true, trackID: f.ids[0])
        let a = try f.repository.saveAlbum(draft: AlbumDraft(title: "A"), trackIDs: Array(f.ids.prefix(3)))
        let b = try f.repository.saveAlbum(draft: AlbumDraft(title: "B"))
        let reversed = Array(f.ids.prefix(3).reversed()); try f.repository.reorderAlbum(reversed, albumID: a.id)
        XCTAssertEqual(try order(f, a.id), reversed)
        try f.repository.addAlbumTracks([f.ids[0]], albumID: b.id)
        XCTAssertEqual(try order(f, a.id), [f.ids[2], f.ids[1]]); XCTAssertEqual(try order(f, b.id), [f.ids[0]])
        try f.repository.removeAlbumTrack(f.ids[1], albumID: a.id)
        XCTAssertNil(try f.storage.tracks.find(id: f.ids[1])?.albumID)
        XCTAssertNil(try f.storage.tracks.find(id: f.ids[1])?.albumArtist)
        XCTAssertEqual(try f.storage.playlists.tracks(playlistID: playlist.id).map(\.id), f.ids)
        XCTAssertTrue(try f.repository.snapshot().likedIDs.contains(f.ids[0]))
        for (index, id) in f.ids.enumerated() {
            let current = try XCTUnwrap(f.storage.tracks.find(id: id)); let original = try XCTUnwrap(before.first { $0.id == id })
            XCTAssertEqual(current.contentSHA256, original.contentSHA256); XCTAssertEqual(current.fileRelativePath, original.fileRelativePath)
            XCTAssertEqual(try Data(contentsOf: f.file(index)), bytes[index])
        }
        XCTAssertEqual(try f.foreignKeys(), 0)
    }
    func testDeleteRequiresConfirmationAndUnassignsWithoutChangingOtherCollections() throws {
        let f = try LibraryFixture()
        let a = try f.repository.saveAlbum(draft: AlbumDraft(title: "Delete"), trackIDs: Array(f.ids.prefix(3)))
        let b = try f.repository.saveAlbum(draft: AlbumDraft(title: "Keep"), trackIDs: [f.ids[3]])
        let p = try f.repository.createPlaylist(name: "Keep"); try f.repository.addTracks(f.ids, playlistID: p.id)
        try f.repository.setLiked(true, trackID: f.ids[0])
        XCTAssertThrowsError(try f.repository.deleteAlbum(id: a.id, confirmed: false))
        _ = try f.repository.deleteAlbum(id: a.id, confirmed: true)
        let snapshot = try f.repository.snapshot()
        XCTAssertFalse(snapshot.albums.contains { $0.id == a.id }); XCTAssertTrue(snapshot.albums.contains { $0.id == b.id })
        XCTAssertEqual(Set(snapshot.albumGroups.first { $0.id == LibrarySnapshot.unassignedAlbumID }?.trackIDs ?? []), Set(f.ids.prefix(3)))
        XCTAssertEqual(snapshot.playlistTracks(p.id).map(\.id), f.ids); XCTAssertTrue(snapshot.likedIDs.contains(f.ids[0]))
        XCTAssertEqual(Set(snapshot.tracks.map(\.id)), Set(f.ids))
        for i in 0..<4 { XCTAssertTrue(FileManager.default.fileExists(atPath: try f.file(i).path)) }
    }
    func testInvalidMutationRollsBackAssignmentsAndNewParentsAtomically() throws {
        let f = try LibraryFixture(); let a = try f.repository.saveAlbum(draft: AlbumDraft(title: "Keep"), trackIDs: [f.ids[0]])
        let before = try f.repository.snapshot()
        XCTAssertThrowsError(try f.repository.saveAlbum(id: a.id, draft: AlbumDraft(title: "Changed", artist: "Never Commit"), trackIDs: [f.ids[1], "missing"]))
        XCTAssertThrowsError(try f.repository.saveAlbum(draft: AlbumDraft(title: "Invalid", releaseYear: 0)))
        XCTAssertThrowsError(try f.repository.saveAlbum(draft: AlbumDraft(title: "Invalid"), trackIDs: [f.ids[0], f.ids[0]]))
        XCTAssertThrowsError(try f.repository.reorderAlbum([f.ids[1]], albumID: a.id))
        XCTAssertEqual(try f.repository.snapshot(), before)
    }
    func testMetadataTitleEditKeepsManagedAssignmentEvenWithDuplicateAlbumNames() throws {
        let f = try LibraryFixture(); let draft = AlbumDraft(title: "Same", artist: "Artist")
        let a = try f.repository.saveAlbum(draft: draft, trackIDs: [f.ids[0]])
        _ = try f.repository.saveAlbum(draft: draft)
        try f.repository.editMetadata(trackID: f.ids[0], draft: TrackMetadataDraft(title: "Changed", artist: "", album: "Same", albumArtist: "Artist"))
        XCTAssertEqual(try f.storage.tracks.find(id: f.ids[0])?.albumID, a.id)
        XCTAssertEqual(try order(f, a.id), [f.ids[0]])
        let noArtist = try f.repository.saveAlbum(draft: AlbumDraft(title: "No album artist"), trackIDs: [f.ids[1]])
        try f.repository.editMetadata(trackID: f.ids[1], draft: TrackMetadataDraft(title: "Renamed Song", artist: "Performer", album: "No album artist"))
        XCTAssertEqual(try f.storage.tracks.find(id: f.ids[1])?.albumID, noArtist.id)
    }
    func testImportedParentsAreEditableWithoutMergingManagedNamesOrRenamedIDs() throws {
        let f = try LibraryFixture()
        let imported = try f.storage.database.dbQueue.write { try LibraryRepository.resolveAlbum("Imported", artistID: nil, db: $0) }
        let originalID = try XCTUnwrap(imported)
        try f.repository.addAlbumTracks([f.ids[0]], albumID: originalID)
        _ = try f.repository.saveAlbum(id: originalID, draft: AlbumDraft(title: "Renamed", artist: "Album Artist"))
        let newImported = try f.storage.database.dbQueue.write { try LibraryRepository.resolveAlbum("Imported", artistID: nil, db: $0) }
        XCTAssertNotEqual(newImported, originalID)
        let same = try f.storage.database.dbQueue.write { try LibraryRepository.resolveAlbum("Imported", artistID: nil, db: $0) }
        XCTAssertEqual(same, newImported)
        XCTAssertEqual(try f.storage.tracks.find(id: f.ids[0])?.albumID, originalID)
    }
    func testRealTaggedAudioImportRetainsEditableAlbumAndUntypedImportIsUnassigned() async throws {
        let f = try LibraryFixture(count: 0); let folder = try f.sources()
        let source = folder.appendingPathComponent("source.wav"); try LibraryFixture.wav(seed: 2).write(to: source)
        let tagged = folder.appendingPathComponent("tagged.m4a")
        let export = try XCTUnwrap(AVAssetExportSession(asset: AVURLAsset(url: source), presetName: AVAssetExportPresetAppleM4A))
        export.outputURL = tagged; export.outputFileType = .m4a
        export.metadata = [(AVMetadataIdentifier.commonIdentifierAlbumName, "Tagged Album"), (.commonIdentifierArtist, "Tagged Artist")].map { key, value in
            let item = AVMutableMetadataItem(); item.identifier = key; item.value = value as NSString; return item
        }
        await withCheckedContinuation { continuation in export.exportAsynchronously { continuation.resume() } }
        XCTAssertEqual(export.status, .completed)
        let result = try await f.storage.importAudio(from: tagged)
        let albumID = try XCTUnwrap(result.track.albumID)
        XCTAssertEqual(try f.repository.snapshot().albums.first { $0.id == albumID }?.title, "Tagged Album")
        _ = try f.repository.saveAlbum(id: albumID, draft: AlbumDraft(title: "Edited Imported"))
        XCTAssertEqual(try f.storage.tracks.find(id: result.track.id)?.albumID, albumID)
        let unassigned = try await f.storage.importAudio(from: source)
        XCTAssertNil(unassigned.track.albumID)
        XCTAssertTrue(try f.repository.snapshot().albumGroups.first { $0.id == LibrarySnapshot.unassignedAlbumID }?.trackIDs.contains(unassigned.track.id) == true)
    }
    func testRestartPreservesEmptyAlbumDetailsOrderAndSearch() throws {
        let f = try LibraryFixture()
        let a = try f.repository.saveAlbum(draft: AlbumDraft(title: "Persist", artist: "Artist", releaseYear: 2001, description: "Saved"), trackIDs: Array(f.ids.prefix(3).reversed()))
        let empty = try f.repository.saveAlbum(draft: AlbumDraft(title: "Empty"))
        let reopened = try StorageCoordinator(paths: f.paths)
        let snapshot = try LibraryRepository(db: reopened.database.dbQueue).snapshot()
        XCTAssertEqual(snapshot.albumGroups.first { $0.id == a.id }?.trackIDs, Array(f.ids.prefix(3).reversed()))
        XCTAssertEqual(snapshot.albumGroups.first { $0.id == empty.id }?.count, 0)
        XCTAssertEqual(snapshot.albums.first { $0.id == a.id }?.releaseYear, 2001)
        XCTAssertEqual(LibrarySearchEngine.search("saved", in: snapshot).albums.map(\.id), [a.id])
    }
    @MainActor func testArtworkJPEGPNGReplacementRemovalAndDeleteAreRecoverable() async throws {
        let f = try LibraryFixture(); let (_, _, library) = f.services()
        let id = try await library.saveAlbum(draft: AlbumDraft(title: "Art"), artworkData: LibraryFixture.image())
        func path() throws -> String { try XCTUnwrap(f.repository.snapshot().albums.first { $0.id == id }?.artworkRelativePath) }
        let png = try path()
        _ = try await library.saveAlbum(id: id, draft: AlbumDraft(title: "Art"), artworkData: LibraryFixture.image(png: false))
        let jpeg = try path(); XCTAssertNotEqual(png, jpeg)
        XCTAssertFalse(FileManager.default.fileExists(atPath: try f.paths.artworkURL(relativePath: png).path))
        _ = try await library.saveAlbum(id: id, draft: AlbumDraft(title: "Art"), removeArtwork: true)
        XCTAssertNil(try f.repository.snapshot().albums.first { $0.id == id }?.artworkRelativePath)
        XCTAssertFalse(FileManager.default.fileExists(atPath: try f.paths.artworkURL(relativePath: jpeg).path))
        _ = try await library.saveAlbum(id: id, draft: AlbumDraft(title: "Art"), artworkData: LibraryFixture.image())
        let deleted = try path(); try await library.deleteAlbum(id: id, confirmed: true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: try f.paths.artworkURL(relativePath: deleted).path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: try f.paths.artworkURL(relativePath: ManagedLibraryFiles.thumbnailName(deleted)).path))
        let pendingCount = try await f.storage.database.dbQueue.read { try ManagedFileOperation.fetchAll($0).count }
        XCTAssertEqual(pendingCount, 0)
        // A prepared, uncommitted cover is removed on recovery; a committed cover stays.
        let pending = try ManagedLibraryFiles.stageArtwork(LibraryFixture.image(), ownerID: "interrupted", oldPath: nil, kind: "album-artwork", paths: f.paths, db: f.storage.database.dbQueue)
        try ManagedLibraryFiles.recover(paths: f.paths, db: f.storage.database.dbQueue)
        XCTAssertFalse(FileManager.default.fileExists(atPath: try f.paths.artworkURL(relativePath: pending.stagedPath).path))
    }
    @MainActor func testFailedAlbumArtworkSavePreservesOldCoverAndDoesNotLeakFiles() async throws {
        let f = try LibraryFixture(); let (_, _, library) = f.services()
        let id = try await library.saveAlbum(draft: AlbumDraft(title: "Keep"), artworkData: LibraryFixture.image())
        let before = try f.repository.snapshot()
        do { _ = try await library.saveAlbum(id: id, draft: AlbumDraft(title: "Changed"), trackIDs: ["missing"], artworkData: LibraryFixture.image(png: false)); XCTFail("Must reject missing song") } catch { }
        XCTAssertEqual(try f.repository.snapshot(), before)
        let files = try FileManager.default.contentsOfDirectory(atPath: f.paths.artwork.path)
        XCTAssertEqual(files.count, 2)
    }
    @MainActor func testAlbumPlaybackShuffleAndDeletionKeepCurrentItemQueueHistoryAndTimer() async throws {
        let f = try LibraryFixture(); let (player, transport, library) = f.services()
        let ids = Array(f.ids.prefix(3).reversed())
        let a = try f.repository.saveAlbum(draft: AlbumDraft(title: "Play"), trackIDs: ids)
        await libraryEventually { library.albumGroups.contains { $0.id == a.id } }
        await library.play(ids[0], ids: ids, kind: "album", sourceID: a.id, shuffle: false)
        XCTAssertEqual(player.queue.contextTrackIDs, ids); XCTAssertEqual(player.state.currentTrackID, ids[0])
        await player.next(); XCTAssertEqual(player.state.currentTrackID, ids[1])
        await library.play(ids[0], ids: ids, kind: "album", sourceID: a.id, shuffle: true)
        XCTAssertTrue(player.queue.shuffleEnabled); XCTAssertEqual(Set(player.queue.contextTrackIDs), Set(ids))
        player.queue.playNext(trackID: f.ids[3]); await player.seek(to: 0.5)
        player.sleepTimer.start(minutes: 5)
        let deadline = player.sleepTimer.deadline
        let generation = player.activeItemGeneration; let replacements = transport.replacements
        let history = try f.storage.playback.history(limit: 100).map(\.id)
        let queued = try f.storage.playback.queue().map(\.id)
        try await library.deleteAlbum(id: a.id, confirmed: true)
        await libraryEventually { !library.snapshot.albums.contains { $0.id == a.id } }
        XCTAssertTrue(transport.isPlaying); XCTAssertEqual(player.state.currentTrackID, ids[0])
        XCTAssertEqual(player.state.elapsedTime, 0.5); XCTAssertEqual(player.activeItemGeneration, generation); XCTAssertEqual(transport.replacements, replacements)
        XCTAssertEqual(player.queue.contextTrackIDs, ids)
        XCTAssertEqual(player.sleepTimer.deadline, deadline)
        XCTAssertEqual(try f.storage.playback.queue().map(\.id), queued)
        XCTAssertEqual(try f.storage.playback.history(limit: 100).map(\.id), history)
        await player.next(); XCTAssertEqual(player.state.currentTrackID, f.ids[3])
        player.stop()
    }
    @MainActor func testKeyboardHasOnlyOneSafeAreaOwner() {
        let controller = KeyboardSafeHostingController(content: Text("Test"))
        controller.loadViewIfNeeded()
        XCTAssertEqual(controller.hosting.safeAreaRegions, .container)
        XCTAssertEqual(controller.children.count, 1)
    }
}
