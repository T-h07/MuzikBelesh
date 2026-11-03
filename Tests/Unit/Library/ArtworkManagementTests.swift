import XCTest
import GRDB
import ImageIO
@testable import OFFLINE

final class ArtworkManagementTests: XCTestCase {
    @MainActor func testJPEGAndPNGArtworkPersistAndProduceThumbnails() async throws {
        for png in [false, true] {
            let f = try LibraryFixture(); let (_, _, library) = f.services()
            try await library.saveMetadata(trackID: f.ids[0], draft: TrackMetadataDraft(title: "Art", artist: "", album: ""), artworkData: LibraryFixture.image(png: png))
            let track = try XCTUnwrap(f.storage.tracks.find(id: f.ids[0])); let path = try XCTUnwrap(track.artworkRelativePath)
            XCTAssertTrue(FileManager.default.fileExists(atPath: try f.paths.artworkURL(relativePath: path).path))
            XCTAssertTrue(FileManager.default.fileExists(atPath: try f.paths.artworkURL(relativePath: ManagedLibraryFiles.thumbnailName(path)).path))
            XCTAssertEqual(try StorageCoordinator(paths: f.paths).tracks.find(id: f.ids[0])?.artworkRelativePath, path)
        }
    }
    @MainActor func testInvalidArtworkPreservesMetadataAndExistingImage() async throws {
        let f = try LibraryFixture(); let (_, _, library) = f.services()
        let draft = TrackMetadataDraft(title: "Keep", artist: "Artist", album: "Album")
        try await library.saveMetadata(trackID: f.ids[0], draft: draft, artworkData: LibraryFixture.image())
        let before = try XCTUnwrap(f.storage.tracks.find(id: f.ids[0])); let files = try FileManager.default.contentsOfDirectory(atPath: f.paths.artwork.path).sorted()
        do { try await library.saveMetadata(trackID: f.ids[0], draft: TrackMetadataDraft(title: "Discard", artist: "New", album: "New"), artworkData: Data([0, 1, 2])); XCTFail("Invalid image must fail") } catch { }
        XCTAssertEqual(try f.storage.tracks.find(id: f.ids[0]), before)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: f.paths.artwork.path).sorted(), files)
    }
    func testOversizedAndInvalidDataAreRejected() throws {
        XCTAssertThrowsError(try ManagedLibraryFiles.imageData(Data(repeating: 0, count: 20 * 1024 * 1024 + 1), pixels: 1024))
        XCTAssertThrowsError(try ManagedLibraryFiles.imageData(Data(), pixels: 1024))
    }
    func testLargeImageIsDownsampledToSafeBounds() throws {
        let data = try ManagedLibraryFiles.imageData(LibraryFixture.image(side: 2048), pixels: 1024)
        let source = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
        let properties = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
        XCTAssertLessThanOrEqual(properties[kCGImagePropertyPixelWidth] as? Int ?? .max, 1024)
        XCTAssertLessThanOrEqual(properties[kCGImagePropertyPixelHeight] as? Int ?? .max, 1024)
    }
    @MainActor func testReplacementPreservesSharedOldArtworkUntilLastReferenceDisappears() async throws {
        let f = try LibraryFixture(); let (_, _, library) = f.services()
        let draft = TrackMetadataDraft(title: "Art", artist: "", album: "")
        try await library.saveMetadata(trackID: f.ids[0], draft: draft, artworkData: LibraryFixture.image())
        let old = try XCTUnwrap(f.storage.tracks.find(id: f.ids[0])?.artworkRelativePath)
        var shared = try XCTUnwrap(f.storage.tracks.find(id: f.ids[1])); shared.artworkRelativePath = old; try f.storage.tracks.save(shared)
        try await library.saveMetadata(trackID: f.ids[0], draft: draft, artworkData: LibraryFixture.image(png: false))
        XCTAssertTrue(FileManager.default.fileExists(atPath: try f.paths.artworkURL(relativePath: old).path))
        try await library.saveMetadata(trackID: f.ids[1], draft: draft, artworkData: nil, removeArtwork: true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: try f.paths.artworkURL(relativePath: old).path))
        XCTAssertNotNil(try f.storage.tracks.find(id: f.ids[0])?.artworkRelativePath)
    }
    @MainActor func testFailedDatabaseUpdateRollsBackNewArtworkAndRetainsDraft() async throws {
        let f = try LibraryFixture(); let (_, _, library) = f.services(); let before = try f.repository.snapshot()
        try f.storage.database.dbQueue.write { try $0.execute(sql: "CREATE TRIGGER reject_art BEFORE UPDATE ON tracks BEGIN SELECT RAISE(ABORT, 'injected'); END") }
        let draft = TrackMetadataDraft(title: "Unsaved", artist: "New", album: "New"); let data = try LibraryFixture.image()
        do { try await library.saveMetadata(trackID: f.ids[0], draft: draft, artworkData: data); XCTFail("Injected failure must propagate") } catch { }
        XCTAssertEqual(draft.title, "Unsaved"); XCTAssertFalse(data.isEmpty)
        XCTAssertEqual(try f.repository.snapshot(), before)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: f.paths.artwork.path).isEmpty)
    }
    func testPreparedArtworkRecoveryRemovesOnlyUnreferencedNewFiles() throws {
        let f = try LibraryFixture()
        let operation = try ManagedLibraryFiles.stageArtwork(LibraryFixture.image(), ownerID: f.ids[0], oldPath: nil, kind: "track-artwork", paths: f.paths, db: f.storage.database.dbQueue)
        _ = try StorageCoordinator(paths: f.paths)
        XCTAssertFalse(FileManager.default.fileExists(atPath: try f.paths.artworkURL(relativePath: operation.stagedPath).path))
        XCTAssertEqual(try f.storage.tracks.all().count, 4)
    }
    func testCommittedArtworkRecoveryPreservesNewAndCleansOld() throws {
        let f = try LibraryFixture(); let draft = TrackMetadataDraft(title: "Art", artist: "", album: "")
        let old = try ManagedLibraryFiles.stageArtwork(LibraryFixture.image(), ownerID: f.ids[0], oldPath: nil, kind: "track-artwork", paths: f.paths, db: f.storage.database.dbQueue)
        try f.repository.editMetadata(trackID: f.ids[0], draft: draft, artworkPath: old.stagedPath, replaceArtwork: true, artworkOperation: old.id)
        try ManagedLibraryFiles.finishArtwork(old, paths: f.paths, db: f.storage.database.dbQueue)
        let next = try ManagedLibraryFiles.stageArtwork(LibraryFixture.image(), ownerID: f.ids[0], oldPath: old.stagedPath, kind: "track-artwork", paths: f.paths, db: f.storage.database.dbQueue)
        try f.repository.editMetadata(trackID: f.ids[0], draft: draft, artworkPath: next.stagedPath, replaceArtwork: true, artworkOperation: next.id)
        let reopened = try StorageCoordinator(paths: f.paths)
        XCTAssertEqual(try reopened.tracks.find(id: f.ids[0])?.artworkRelativePath, next.stagedPath)
        XCTAssertTrue(FileManager.default.fileExists(atPath: try f.paths.artworkURL(relativePath: next.stagedPath).path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: try f.paths.artworkURL(relativePath: old.stagedPath).path))
    }
    @MainActor func testPlaylistArtworkAndNameAreCommittedTogether() async throws {
        let f = try LibraryFixture(); let (_, _, library) = f.services()
        do { _ = try await library.savePlaylist(id: nil, name: "Not created", description: "", artworkData: Data()); XCTFail("Invalid artwork must reject creation") } catch { }
        XCTAssertTrue(try f.storage.playlists.all().isEmpty)
        let id = try await library.savePlaylist(id: nil, name: "Saved", description: "Cover", artworkData: LibraryFixture.image())
        let before = try XCTUnwrap(f.storage.playlists.all().first)
        do { _ = try await library.savePlaylist(id: id, name: "Discard", description: "Discard", artworkData: Data()); XCTFail("Invalid image must reject update") } catch { }
        XCTAssertEqual(try f.storage.playlists.all().first, before)
        XCTAssertNotNil(before.artworkRelativePath)
    }
    func testMissingArtworkAndUnsafeCleanupPathsDoNotDamageOtherFiles() throws {
        let f = try LibraryFixture(); let outside = f.root.appendingPathComponent("keep.jpg"); try Data([1, 2, 3]).write(to: outside)
        try ManagedLibraryFiles.cleanupArtwork("../keep.jpg", paths: f.paths, db: f.storage.database.dbQueue)
        try ManagedLibraryFiles.cleanupArtwork("artwork-\(UUID().uuidString).jpg", paths: f.paths, db: f.storage.database.dbQueue)
        XCTAssertEqual(try Data(contentsOf: outside), Data([1, 2, 3])); XCTAssertEqual(try f.storage.tracks.all().count, 4)
    }
}
