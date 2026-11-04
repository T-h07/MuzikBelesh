import XCTest
import GRDB
import AVFoundation
@testable import OFFLINE

final class FullLocalLibraryIntegrationTests: XCTestCase {
    @MainActor func testTenTrackOfflineLibrarySurvivesFullServiceRecreation() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Phase5-Integration-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = try AppStoragePaths(root: root)
        let sources = root.appendingPathComponent("Sources", isDirectory: true); try FileManager.default.createDirectory(at: sources, withIntermediateDirectories: true)
        var storage: StorageCoordinator? = try StorageCoordinator(paths: paths)
        var repository: LibraryRepository? = LibraryRepository(db: storage!.database.dbQueue)
        var transport: LibraryTestTransport? = LibraryTestTransport()
        var player: AudioPlayerService? = AudioPlayerService(storage: storage, player: transport, registerRemoteCommands: false, makeShuffle: { $0 })
        var library: MusicLibraryService? = MusicLibraryService(storage: storage, player: player)
        var ids: [String] = []; var hashes: [String: String] = [:]
        for index in 0..<10 {
            let source = sources.appendingPathComponent(String(format: "Local %02d.wav", index))
            try LibraryFixture.wav(seed: index).write(to: source)
            let imported = try await storage!.importAudio(from: source)
            XCTAssertFalse(imported.duplicate); ids.append(imported.track.id); hashes[imported.track.id] = imported.track.contentSHA256
            XCTAssertTrue(try paths.musicURL(relativePath: imported.track.fileRelativePath).path.hasPrefix(paths.music.path + "/"))
            var deterministic = imported.track; deterministic.dateAdded = Date(timeIntervalSince1970: 1_600_000_000 + Double(index)); try storage!.tracks.save(deterministic)
        }
        XCTAssertEqual(Set(ids).count, 10)
        for index in 0..<3 {
            try repository!.editMetadata(trackID: ids[index], draft: TrackMetadataDraft(title: "Changed \(index)", artist: index < 2 ? "Offline Artist \(index)" : "", album: index == 2 ? "Edited Album" : ""))
        }
        for index in 0..<2 {
            let track = try XCTUnwrap(storage!.tracks.find(id: ids[index]))
            try await library!.saveMetadata(trackID: track.id, draft: TrackMetadataDraft(title: track.title, artist: storage!.artistName(for: track.artistID) ?? "", album: storage!.albumTitle(for: track.albumID) ?? ""), artworkData: LibraryFixture.image(png: index == 0))
        }
        let a = try repository!.createPlaylist(name: "Playlist A", description: "Custom order")
        let b = try repository!.createPlaylist(name: "Playlist B")
        try repository!.addTracks(Array(ids.prefix(5)), playlistID: a.id)
        try repository!.addTracks([ids[2], ids[3], ids[5], ids[6]], playlistID: b.id)
        try repository!.removeTrack(ids[1], playlistID: a.id)
        XCTAssertTrue(FileManager.default.fileExists(atPath: try paths.musicURL(relativePath: storage!.tracks.find(id: ids[1])!.fileRelativePath).path))
        let order = [ids[4], ids[0], ids[3], ids[2]]; try repository!.reorder(order, playlistID: a.id)
        for id in [ids[0], ids[1], ids[6]] { try repository!.setLiked(true, trackID: id) }
        XCTAssertEqual(try repository!.search("Changed 0", sort: .newest).map(\.id), [ids[0]])
        XCTAssertEqual(Set(try repository!.search("Offline Artist", sort: .newest).map(\.id)), Set(ids.prefix(2)))
        XCTAssertEqual(try repository!.search("Edited Album", sort: .newest).map(\.id), [ids[2]])
        XCTAssertEqual(try repository!.search("", sort: .nameAscending).map(\.id), ids)
        XCTAssertEqual(try repository!.search("", sort: .oldest).map(\.id), ids)
        XCTAssertEqual(try repository!.search("", sort: .shortest).map(\.id), ids)
        try repository!.setSort(.longest)
        await libraryEventually { library!.snapshot.tracks.count == 10 && library!.snapshot.likedIDs.count == 3 }
        try await player!.play(trackID: order[0], contextTrackIDs: order, contextKind: "playlist", contextSourceID: a.id)
        await player!.seek(to: 0.5)
        let generation = player!.activeItemGeneration; let replacements = transport!.replacements
        let finalOrder = Array(order.reversed()); try repository!.reorder(finalOrder, playlistID: a.id)
        try repository!.editMetadata(trackID: order[0], draft: TrackMetadataDraft(title: "Live Edited", artist: "Live Artist", album: "Live Album"))
        await libraryEventually { library!.playlistTracks(a.id).map(\.id) == finalOrder && library!.track(order[0])?.title == "Live Edited" }
        XCTAssertEqual(player!.queue.contextTrackIDs, order); XCTAssertEqual(player!.activeItemGeneration, generation)
        XCTAssertEqual(transport!.replacements, replacements); XCTAssertEqual(player!.state.elapsedTime, 0.5)
        for id in order.dropFirst() { await player!.next(); XCTAssertEqual(player!.state.currentTrackID, id); XCTAssertTrue(transport!.isPlaying) }
        try await player!.play(trackID: order[0], contextTrackIDs: order, contextKind: "playlist", contextSourceID: a.id)
        player!.queue.playNext(trackID: ids[9]); await player!.next(); XCTAssertEqual(player!.state.currentTrackID, ids[9])
        await player!.next(); XCTAssertEqual(player!.state.currentTrackID, order[1], "Queued outside song resumes the active collection")
        await player!.seek(to: 0.5); player!.pause()
        weak var oldStorage = storage
        library = nil; player = nil; transport = nil; repository = nil; storage = nil
        await libraryEventually { oldStorage == nil }

        let reopened = try StorageCoordinator(paths: paths)
        let reopenedRepository = LibraryRepository(db: reopened.database.dbQueue)
        let snapshot = try reopenedRepository.snapshot()
        XCTAssertEqual(snapshot.tracks.count, 10); XCTAssertEqual(snapshot.playlistTracks(a.id).map(\.id), finalOrder)
        XCTAssertEqual(snapshot.playlistTracks(b.id).map(\.id), [ids[2], ids[3], ids[5], ids[6]])
        XCTAssertEqual(snapshot.likedIDs, Set([ids[0], ids[1], ids[6]])); XCTAssertEqual(snapshot.sort, .longest)
        XCTAssertEqual(snapshot.trackByID[ids[0]]?.title, "Changed 0"); XCTAssertEqual(snapshot.trackByID[ids[2]]?.title, "Changed 2")
        XCTAssertEqual(snapshot.albumTitle(snapshot.trackByID[ids[2]]?.albumID), "Edited Album")
        for index in 0..<2 {
            let path = try XCTUnwrap(snapshot.trackByID[ids[index]]?.artworkRelativePath)
            XCTAssertTrue(FileManager.default.fileExists(atPath: try paths.artworkURL(relativePath: path).path))
        }
        let restoredTransport = LibraryTestTransport()
        let restoredPlayer = AudioPlayerService(storage: reopened, player: restoredTransport, registerRemoteCommands: false)
        let restoredLibrary = MusicLibraryService(storage: reopened, player: restoredPlayer)
        await libraryEventually { restoredTransport.replacements > 0 && restoredPlayer.state.status == .paused }
        XCTAssertEqual(restoredPlayer.state.currentTrackID, order[1]); XCTAssertEqual(restoredPlayer.state.elapsedTime, 0.5, accuracy: 0.01)
        for track in snapshot.tracks {
            let url = try paths.musicURL(relativePath: track.fileRelativePath)
            XCTAssertTrue(url.isFileURL); XCTAssertEqual(try reopened.audio.sha256(url: url), hashes[track.id])
            let validated = try await reopened.audio.validate(url); XCTAssertGreaterThan(validated.durationMs ?? 0, 0)
            await restoredLibrary.play(track.id, ids: snapshot.tracks.map(\.id), kind: "library")
            XCTAssertEqual(restoredPlayer.state.currentTrackID, track.id); XCTAssertTrue(restoredTransport.isPlaying)
        }
        restoredPlayer.stop()
        let native = NativePlaybackPlayer(); let realPlayer = AudioPlayerService(storage: reopened, player: native, registerRemoteCommands: false)
        try await realPlayer.play(trackID: ids[0])
        await libraryEventually { native.isPlaying }
        XCTAssertEqual(native.player.currentItem?.status, .readyToPlay); XCTAssertTrue(native.player.currentItem?.asset is AVURLAsset)
        realPlayer.stop()
        let violations = try await reopened.database.dbQueue.read { try Row.fetchAll($0, sql: "PRAGMA foreign_key_check").count }
        XCTAssertEqual(violations, 0)
    }

    @MainActor func testReactiveObservationTracksRapidRepositoryChangesWithoutManualReload() async throws {
        let f = try LibraryFixture(); let (player, _, library) = f.services()
        for index in 0..<20 {
            let p = try f.repository.createPlaylist(name: "Playlist \(index)")
            try f.repository.addTracks([f.ids[index % f.ids.count]], playlistID: p.id)
            try f.repository.setLiked(index % 2 == 0, trackID: f.ids[index % f.ids.count])
        }
        await libraryEventually { library.snapshot.playlists.count == 20 && library.snapshot.memberships.count == 20 }
        try await player.play(trackID: f.ids[0]); await player.seek(to: 0.5)
        let generation = player.activeItemGeneration
        try f.repository.editMetadata(trackID: f.ids[0], draft: TrackMetadataDraft(title: "Visible Everywhere", artist: "Live", album: "Live"))
        await libraryEventually { library.track(f.ids[0])?.title == "Visible Everywhere" }
        XCTAssertEqual(player.activeItemGeneration, generation); XCTAssertEqual(player.state.elapsedTime, 0.5)
        XCTAssertEqual(library.artistGroups.first { $0.title == "Live" }?.trackIDs, [f.ids[0]])
    }

    @MainActor func testDeletingActivePlaylistPreservesCurrentItemAndSnapshotOrder() async throws {
        let f = try LibraryFixture(); let (player, transport, library) = f.services(); let p = try f.repository.createPlaylist(name: "A")
        let order = [f.ids[2], f.ids[0], f.ids[3]]; try f.repository.addTracks(order, playlistID: p.id)
        try await player.play(trackID: order[0], contextTrackIDs: order, contextKind: "playlist", contextSourceID: p.id)
        await player.seek(to: 0.5); let generation = player.activeItemGeneration
        try await library.deletePlaylist(id: p.id, confirmed: true)
        await libraryEventually { library.snapshot.playlists.isEmpty }
        XCTAssertEqual(player.activeItemGeneration, generation); XCTAssertEqual(player.state.elapsedTime, 0.5)
        XCTAssertTrue(transport.isPlaying); XCTAssertEqual(player.queue.contextTrackIDs, order)
        await player.next(); XCTAssertEqual(player.state.currentTrackID, order[1])
        XCTAssertEqual(try f.storage.tracks.all().count, 4)
    }
}
