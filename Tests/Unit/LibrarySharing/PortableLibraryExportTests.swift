import Foundation
import GRDB
import XCTest
@testable import OFFLINE

/// Phase 11.4 export: visible order, repeats, scopes, atomic file output and the privacy
/// allowlist (release blocker).
final class PortableLibraryExportTests: XCTestCase {
    private typealias F = PortableFixtures

    private func fixture(_ count: Int = 4) throws -> LibraryFixture {
        let value = try LibraryFixture(count: count)
        retainUntilTeardown(value)
        return value
    }

    private func exporter(_ fixture: LibraryFixture) -> PortableLibraryExporter {
        PortableLibraryExporter(db: fixture.storage.database.dbQueue, appVersion: "test")
    }

    func testOrdinaryPlaylistExportKeepsVisibleOrderAndValidates() async throws {
        let fixture = try fixture()
        let playlist = try fixture.repository.createPlaylist(name: "Road Trip")
        try fixture.repository.addTracks([fixture.ids[2], fixture.ids[0], fixture.ids[1]], playlistID: playlist.id)
        let plan = try await exporter(fixture).plan(.playlist(playlist.id))
        let songs = Dictionary(uniqueKeysWithValues: plan.document.collection.songs.map { ($0.id, $0) })
        XCTAssertEqual(plan.document.scope, .playlist)
        XCTAssertEqual(plan.document.collection.playlists.count, 1)
        XCTAssertEqual(plan.document.collection.playlists[0].occurrences.map { songs[$0.songRef]?.title }, ["Song 2", "Song 0", "Song 1"])
        XCTAssertEqual(plan.summary.songs, 3)
        XCTAssertEqual(plan.suggestedFilename.hasSuffix(".mbelesh"), true)
        // The produced bytes are accepted by the importer's own validation.
        XCTAssertEqual(try PortableLibraryCodec.decode(plan.data).collection.playlists[0].occurrences.count, 3)
    }

    func testMigrationPlaylistExportKeepsRepeatsAndPlaceholdersInOrder() async throws {
        let fixture = try fixture()
        let source = PlaylistMigrationSourcePlaylist(source: .exportify, name: "Imported", entries: [
            PlaylistMigrationSourceTrack(position: 0, title: "Song 0", primaryArtist: nil, durationMs: 2000),
            PlaylistMigrationSourceTrack(position: 1, title: "Missing Song", primaryArtist: "Somebody", durationMs: 180_000),
            PlaylistMigrationSourceTrack(position: 2, title: "Song 0", primaryArtist: nil, durationMs: 2000)
        ])
        let session = try fixture.storage.playlistMigrations.createCommittedPlaylist(from: source, operationID: "export-test")
        let entries = try await fixture.storage.playlistMigrations.entries(migrationID: session.id)
        try await fixture.storage.playlistMigrations.associateVerifiedTrack(entryID: entries[0].id, trackID: fixture.ids[0])
        try await fixture.storage.playlistMigrations.associateVerifiedTrack(entryID: entries[2].id, trackID: fixture.ids[0])
        let playlistID = try XCTUnwrap(session.destinationPlaylistID)
        let plan = try await exporter(fixture).plan(.playlist(playlistID))
        let occurrences = plan.document.collection.playlists[0].occurrences
        let songs = Dictionary(uniqueKeysWithValues: plan.document.collection.songs.map { ($0.id, $0) })
        XCTAssertEqual(occurrences.count, 3)
        XCTAssertEqual(occurrences[0].songRef, occurrences[2].songRef, "Repeated occurrences reference one song")
        XCTAssertEqual(songs[occurrences[1].songRef]?.title, "Missing Song")
        XCTAssertEqual(songs[occurrences[1].songRef]?.artist, "Somebody")
        XCTAssertEqual(occurrences.map(\.position), [0, 1, 2])
        XCTAssertEqual(plan.summary.songs, 2)
    }

    func testLibraryScopeIncludesSongsInNoPlaylistAndSelectedScopeExcludesOthers() async throws {
        let fixture = try fixture()
        let first = try fixture.repository.createPlaylist(name: "First")
        try fixture.repository.addTracks([fixture.ids[0]], playlistID: first.id)
        let second = try fixture.repository.createPlaylist(name: "Second")
        try fixture.repository.addTracks([fixture.ids[1]], playlistID: second.id)
        let library = try await exporter(fixture).plan(.library)
        XCTAssertEqual(library.summary.songs, 4)
        XCTAssertEqual(library.summary.unassignedSongs, 2)
        XCTAssertEqual(library.summary.playlists, 2)
        let selected = try await exporter(fixture).plan(.playlists([second.id]))
        XCTAssertEqual(selected.document.collection.playlists.map(\.name), ["Second"])
        XCTAssertEqual(selected.summary.songs, 1)
    }

    func testYouTubeProvenanceBecomesARecordingReference() async throws {
        let fixture = try fixture()
        try F.addSource(fixture, trackID: fixture.ids[0], video: F.videoA)
        let plan = try await exporter(fixture).plan(.library)
        let song = try XCTUnwrap(plan.document.collection.songs.first { $0.title == "Song 0" })
        XCTAssertEqual(song.recordings, [PortableRecordingReference(provider: "youtube", videoId: F.videoA)])
        XCTAssertEqual(plan.summary.songsWithRecordings, 1)
    }

    func testEmptySelectionsAreRefused() async throws {
        let fixture = try fixture(0)
        do { _ = try await exporter(fixture).plan(.library); XCTFail("An empty library has nothing to export") }
        catch { XCTAssertEqual(error as? PortableLibraryError, .nothingToExport) }
    }

    /// Release blocker: private markers planted across the database never reach the file,
    /// and the file contains only allowlisted keys.
    func testPrivacyAllowlistExcludesEveryPrivateMarker() async throws {
        let fixture = try fixture()
        let db = fixture.storage.database.dbQueue
        let playlist = try fixture.repository.createPlaylist(name: "Shared Mix")
        try fixture.repository.addTracks(fixture.ids, playlistID: playlist.id)
        try fixture.repository.setLiked(true, trackID: fixture.ids[1])
        try fixture.storage.settings.set("https://PRIVATE-MARKER-SERVER.example:8443/search?token=PRIVATE-MARKER-TOKEN", for: "discovery.searxng.url")
        try await db.write { db in
            try db.execute(sql: "UPDATE tracks SET originalFilename = 'PRIVATE-MARKER-FILENAME.wav', metadataSource = 'PRIVATE-MARKER-SOURCE' WHERE id = ?", arguments: [fixture.ids[0]])
            try StoredTrackSource(id: "src-private", trackID: fixture.ids[2], sourceType: "youtube", sourceIdentifier: F.videoB,
                canonicalURL: "https://rr3---sn-PRIVATE.googlevideo.com/videoplayback?sig=PRIVATE-MARKER-SIGNED&cookie=PRIVATE-MARKER-COOKIE",
                dateRecorded: Date()).insert(db)
            try db.execute(sql: "INSERT INTO local_user_profile (slot, id, username, avatarRelativePath, createdAt, updatedAt) VALUES (1, ?, 'PRIVATE-MARKER-USERNAME', NULL, ?, ?)",
                           arguments: [UUID().uuidString, Date(), Date()])
        }
        let plan = try await exporter(fixture).plan(.library)
        let text = String(decoding: plan.data, as: UTF8.self)
        for marker in ["PRIVATE-MARKER", "googlevideo", "videoplayback", "sig=", "cookie", "token", "file://", fixture.root.path,
                       fixture.paths.music.path, ".wav", "song-0", playlist.id, "liked", "listening", "theme", "accent", "wifi",
                       "searxng", "server", "username", "avatar", "session", "jobID", "deviceID"] {
            XCTAssertFalse(text.localizedCaseInsensitiveContains(marker), "Export leaked “\(marker)”")
        }
        let json = try JSONSerialization.jsonObject(with: plan.data)
        let allowed: Set<String> = [
            "format", "schemaVersion", "requiredFeatures", "exportId", "createdAt", "generator", "generator.app", "generator.version", "scope",
            "collection", "collection.songs", "collection.playlists",
            "collection.songs[].id", "collection.songs[].title", "collection.songs[].artist", "collection.songs[].additionalArtists",
            "collection.songs[].album", "collection.songs[].album.title", "collection.songs[].album.artist",
            "collection.songs[].album.releaseYear", "collection.songs[].album.position", "collection.songs[].durationMs",
            "collection.songs[].recordings", "collection.songs[].recordings[].provider", "collection.songs[].recordings[].videoId",
            "collection.playlists[].id", "collection.playlists[].name", "collection.playlists[].description",
            "collection.playlists[].occurrences", "collection.playlists[].occurrences[].id",
            "collection.playlists[].occurrences[].position", "collection.playlists[].occurrences[].songRef"
        ]
        let present = F.keys(json)
        XCTAssertTrue(present.isSubset(of: allowed), "Keys outside the allowlist: \(present.subtracting(allowed).sorted())")
    }

    func testPreparedShareIsWrittenAtomicallyAndRemovedWithItsOwner() async throws {
        let fixture = try fixture()
        let plan = try await exporter(fixture).plan(.library)
        var share: PreparedLibraryShare? = try PreparedLibraryShare.write(plan, exports: fixture.paths.exports)
        let url = try XCTUnwrap(share?.url)
        XCTAssertEqual(try Data(contentsOf: url), plan.data)
        XCTAssertEqual(url.pathExtension, "mbelesh")
        let directory = url.deletingLastPathComponent()
        let siblings = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        XCTAssertEqual(siblings, [url.lastPathComponent], "No temporary or partial files remain")
        share = nil
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
    }

    func testFilenamesAreSafe() {
        XCTAssertFalse(PortableLibraryExporter.filename("../../Evil/Name:*?").contains("/"))
        XCTAssertTrue(PortableLibraryExporter.filename("Road Trip").hasSuffix(".mbelesh"))
    }
}
