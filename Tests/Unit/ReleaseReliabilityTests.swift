import AVFoundation
import MediaPlayer
import GRDB
import XCTest
@testable import OFFLINE

final class ReleaseReliabilityTests: XCTestCase {
    func testThermalAndPowerPoliciesKeepUserPreferenceAndRecover() {
        for thermal in [ProcessInfo.ThermalState.nominal, .fair, .serious, .critical] {
            for lowPower in [false, true] {
                let policy = ResourcePolicy(thermal: thermal, lowPower: lowPower)
                XCTAssertEqual(policy.downloadLimit(3), policy.defersNewWork ? 0 : (policy.conservesResources ? 1 : 3))
                XCTAssertEqual(policy.playbackInterval(foreground: false), 5)
                XCTAssertGreaterThanOrEqual(policy.playbackInterval(foreground: true), 0.5)
            }
        }
        XCTAssertEqual(ResourcePolicy().downloadLimit(3), 3)
    }

    @MainActor func testArtworkReusedAndPlaybackClockDoesNotRepublishMetadata() async throws {
        let fixture = try LibraryFixture(count: 1)
        let track = try XCTUnwrap(fixture.storage.tracks.find(id: fixture.ids[0]))
        let coordinator = NowPlayingInfoCoordinator()
        let data = try LibraryFixture.image()
        var state = AudioPlaybackState()
        state.currentTrackID = track.id
        state.status = .playing
        coordinator.update(state: state, track: track, artist: nil, album: nil, artworkData: data)
        let first = try XCTUnwrap(MPNowPlayingInfoCenter.default().nowPlayingInfo?[MPMediaItemPropertyArtwork] as? MPMediaItemArtwork)
        state.elapsedTime = 1
        coordinator.update(state: state, track: track, artist: nil, album: nil, artworkData: data)
        XCTAssertTrue(first === MPNowPlayingInfoCenter.default().nowPlayingInfo?[MPMediaItemPropertyArtwork] as? MPMediaItemArtwork)
        coordinator.clear()
        let transport = LibraryTestTransport()
        let player = AudioPlayerService(storage: fixture.storage, player: transport, registerRemoteCommands: false)
        try await player.play(trackID: track.id)
        let before = MPNowPlayingInfoCenter.default().nowPlayingInfo?[MPNowPlayingInfoPropertyElapsedPlaybackTime] as? Double
        for tick in 1...60 { player.samplePlaybackTime(Double(tick)) }
        XCTAssertEqual(MPNowPlayingInfoCenter.default().nowPlayingInfo?[MPNowPlayingInfoPropertyElapsedPlaybackTime] as? Double, before)
        player.pause()
        XCTAssertEqual(MPNowPlayingInfoCenter.default().nowPlayingInfo?[MPNowPlayingInfoPropertyElapsedPlaybackTime] as? Double, 60)
    }

    func testHistoryIsBoundedAndKeepsCurrentCursorAndDuplicateOrdering() {
        let engine = PlaybackNavigationEngine(makeShuffle: { $0 })
        engine.setContext(["a", "b", "a", "c"], currentID: "a")
        XCTAssertEqual(engine.context, ["a", "b", "c"])
        engine.setShuffleEnabled(true)
        for index in 0..<5000 { engine.didStart(index.isMultiple(of: 2) ? "a" : "b", direction: .forward) }
        XCTAssertEqual(engine.history.count, PlaybackNavigationEngine.historyLimit)
        XCTAssertEqual(engine.currentID, "b")
        XCTAssertEqual(engine.previous(), "a")
        let restored = engine.copy()
        XCTAssertEqual(restored.history, engine.history)
        XCTAssertEqual(restored.previous(), "a")
    }

    func testDiskFullCopyRemovesPartialOutputAndPreservesInput() throws {
        let fixture = try LibraryFixture(count: 1)
        let source = try fixture.file(0)
        let digest = try fixture.storage.audio.sha256(url: source)
        let destination = fixture.root.appendingPathComponent("partial.wav")
        XCTAssertThrowsError(try fixture.storage.audio.copyStreaming(from: source, to: destination) { handle, bytes in
            try handle.write(contentsOf: bytes.prefix(100))
            throw CocoaError(.fileWriteOutOfSpace)
        })
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        XCTAssertEqual(try fixture.storage.audio.sha256(url: source), digest)
        try fixture.storage.audio.copyStreaming(from: source, to: destination)
        XCTAssertEqual(try fixture.storage.audio.sha256(url: destination), digest)
    }

    func testFullDatabaseRollsBackWithoutChangingExistingTrack() throws {
        let fixture = try LibraryFixture(count: 1)
        let original = try XCTUnwrap(fixture.storage.tracks.find(id: fixture.ids[0]))
        try fixture.storage.database.dbQueue.writeWithoutTransaction { db in
            let pages = try XCTUnwrap(Int.fetchOne(db, sql: "PRAGMA page_count"))
            _ = try Int.fetchOne(db, sql: "PRAGMA max_page_count = \(pages)")
        }
        XCTAssertThrowsError(try fixture.storage.database.dbQueue.write { db in
            try db.execute(sql: "UPDATE tracks SET title = ? WHERE id = ?", arguments: [String(repeating: "x", count: 4_000_000), original.id])
        })
        XCTAssertEqual(try fixture.storage.tracks.find(id: original.id), original)
        try fixture.storage.database.dbQueue.writeWithoutTransaction { db in
            _ = try Int.fetchOne(db, sql: "PRAGMA max_page_count = 1073741823")
        }
        try fixture.repository.setLiked(true, trackID: original.id)
        XCTAssertTrue(try fixture.repository.snapshot().likedIDs.contains(original.id))
    }

    func testExportUsesIndependentVerifiedFileAndCleansUpOnDismissal() async throws {
        let fixture = try LibraryFixture(count: 1)
        let source = try fixture.file(0)
        var export: PreparedAudioExport? = try await fixture.storage.prepareExport(trackID: fixture.ids[0])
        let url = try XCTUnwrap(export?.url)
        XCTAssertNotEqual(url, source)
        XCTAssertEqual(try fixture.storage.audio.sha256(url: url), try fixture.storage.audio.sha256(url: source))
        export = nil
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
        let unrelated = fixture.paths.exports.appendingPathComponent("keep.txt")
        try Data("keep".utf8).write(to: unrelated)
        try PreparedAudioExport.cleanupAbandoned(in: fixture.paths.exports)
        XCTAssertTrue(FileManager.default.fileExists(atPath: unrelated.path))
    }

    @MainActor func testRepeatedTrackChangesReleasePlayerAndItsObservers() async throws {
        let fixture = try LibraryFixture(count: 2)
        var player: AudioPlayerService? = AudioPlayerService(storage: fixture.storage, player: LibraryTestTransport(), registerRemoteCommands: false)
        weak var reference = player
        for index in 0..<200 { try await player?.play(trackID: fixture.ids[index % 2]) }
        player?.stop()
        player = nil
        await libraryEventually { reference == nil }
    }

    func testTenThousandRecordSQLiteSearchMembershipAndReopen() throws {
        let fixture = try LibraryFixture(count: 1)
        let original = try XCTUnwrap(fixture.storage.tracks.find(id: fixture.ids[0]))
        try fixture.storage.database.dbQueue.write { db in
            for index in 1..<10000 {
                var track = original
                track.id = "stress-\(index)"
                track.title = "Synthetic Song \(index)"
                track.normalizedTitle = LibraryIdentity.normalized(track.title)
                track.searchText = LibraryIdentity.search(track.title)
                track.contentSHA256 = "synthetic-\(index)"
                try track.insert(db)
            }
        }
        let start = ProcessInfo.processInfo.systemUptime
        let snapshot = try fixture.repository.snapshot()
        let result = try fixture.repository.search("Synthetic Song 999", sort: .nameAscending)
        print("PHASE9 sqlite10000 snapshotAndSearchSeconds=\(ProcessInfo.processInfo.systemUptime - start)")
        XCTAssertEqual(snapshot.tracks.count, 10000)
        XCTAssertEqual(result.count, 11)
        let playlist = try fixture.repository.createPlaylist(name: "Stress")
        try fixture.repository.addTracks(Array(snapshot.tracks.prefix(1000).map(\.id)), playlistID: playlist.id)
        XCTAssertEqual(try fixture.repository.snapshot().playlistTracks(playlist.id).count, 1000)
        let reopened = try DatabaseManager(url: fixture.paths.database)
        XCTAssertEqual(try reopened.dbQueue.read { try StoredTrack.fetchCount($0) }, 10000)
        XCTAssertEqual(try fixture.foreignKeys(), 0)
    }
}
