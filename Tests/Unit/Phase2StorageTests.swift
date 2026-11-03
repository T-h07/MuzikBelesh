import XCTest
import GRDB
@testable import OFFLINE

final class Phase2StorageTests: XCTestCase {
    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("MuzikBelesh-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    func testFreshDatabaseMigratesAllVersionsAndReopens() throws {
        let root = try temporaryDirectory()
        let paths = try AppStoragePaths(root: root)
        let first = try DatabaseManager.live(paths: paths)
        let tables = try first.dbQueue.read { db in try String.fetchAll(db, sql: "SELECT name FROM sqlite_master WHERE type = 'table'") }
        XCTAssertTrue(tables.contains("tracks")); XCTAssertTrue(tables.contains("import_operations")); XCTAssertTrue(tables.contains("settings"))
        _ = try DatabaseManager.live(paths: paths)
        let migrated = try first.dbQueue.read { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM grdb_migrations") ?? 0 }
        XCTAssertEqual(migrated, 7)
    }

    func testTrackRepositoryPersistsStableTrackAndDetectsHash() throws {
        let root = try temporaryDirectory(); let paths = try AppStoragePaths(root: root); let manager = try DatabaseManager.live(paths: paths); let repo = GRDBTrackRepository(db: manager.dbQueue); let now = Date()
        let track = StoredTrack(id: "track-stable", title: "Imported Song", artistID: nil, albumID: nil, durationMs: 1000, fileRelativePath: "track-stable.m4a", fileExtension: "m4a", fileSizeBytes: 12, contentSHA256: "abc", artworkRelativePath: nil, availability: .available, dateAdded: now, dateModified: now, originalFilename: "song.m4a", metadataSource: "local_import")
        try repo.save(track)
        let saved = try XCTUnwrap(try repo.find(id: "track-stable"))
        XCTAssertEqual(saved.id, track.id); XCTAssertEqual(saved.title, track.title); XCTAssertEqual(saved.contentSHA256, track.contentSHA256); XCTAssertEqual(saved.fileRelativePath, track.fileRelativePath)
        XCTAssertEqual(try repo.find(contentSHA256: "abc")?.id, "track-stable")
        try repo.updateAvailability(id: track.id, .missing)
        XCTAssertEqual(try repo.find(id: track.id)?.availability, .missing)
    }

    func testPathManagerRejectsTraversalAndSeparatesDatabase() throws {
        let paths = try AppStoragePaths(root: try temporaryDirectory())
        XCTAssertThrowsError(try paths.musicURL(relativePath: "../outside.m4a"))
        XCTAssertFalse(paths.database.path.hasPrefix(paths.documents.path))
        XCTAssertTrue(paths.music.path.hasSuffix("Documents\\Music") || paths.music.path.hasSuffix("Documents/Music"))
    }

    func testStreamingHashIsDeterministic() throws {
        let paths = try AppStoragePaths(root: try temporaryDirectory()); let source = paths.imports.appendingPathComponent("sample.bin"); try Data(repeating: 7, count: 4096).write(to: source)
        let service = AudioFileService(); let hash = try service.sha256(url: source)
        XCTAssertEqual(hash.count, 64); XCTAssertEqual(hash, try service.sha256(url: source))
    }

    func testExportPreservesManagedFileBytesAcrossCoordinatorReopen() throws {
        let root = try temporaryDirectory(); let paths = try AppStoragePaths(root: root); let coordinator = try StorageCoordinator(paths: paths); let bytes = Data((0..<4096).map { UInt8($0 % 251) }); let managed = try paths.musicURL(relativePath: "stable.m4a"); try bytes.write(to: managed)
        let now = Date(); let track = StoredTrack(id: "export-track", title: "Export Me", artistID: nil, albumID: nil, durationMs: nil, fileRelativePath: "stable.m4a", fileExtension: "m4a", fileSizeBytes: Int64(bytes.count), contentSHA256: try coordinator.audio.sha256(url: managed), artworkRelativePath: nil, availability: .available, dateAdded: now, dateModified: now, originalFilename: "source.m4a", metadataSource: "local_import")
        try coordinator.tracks.save(track)
        let reopened = try StorageCoordinator(paths: paths); let destination = paths.exports.appendingPathComponent("roundtrip.m4a"); try reopened.exportAudio(track: track, to: destination)
        XCTAssertEqual(try Data(contentsOf: destination), bytes)
        XCTAssertEqual(reopened.library.first?.id, "export-track")
    }

    func testPlaylistMembershipPreservesOrderAndSettingsPersist() throws {
        let paths = try AppStoragePaths(root: try temporaryDirectory()); let manager = try DatabaseManager.live(paths: paths); let playlistRepo = GRDBPlaylistRepository(db: manager.dbQueue); let settings = GRDBSettingsRepository(db: manager.dbQueue); let now = Date()
        try playlistRepo.save(StoredPlaylist(id: "p1", name: "Road", description: nil, artworkRelativePath: nil, dateAdded: now, dateModified: now))
        try settings.set("High", for: "audioQuality")
        XCTAssertEqual(try settings.string(for: "audioQuality", default: "Standard"), "High")
        XCTAssertEqual(try playlistRepo.all().map(\.id), ["p1"])
    }
}
