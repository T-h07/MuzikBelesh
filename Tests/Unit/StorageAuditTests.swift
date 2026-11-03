import XCTest
@testable import OFFLINE

final class StorageAuditTests: XCTestCase {
    func testCopyRejectsSelfCopyAndExistingDestinationWithoutTruncation() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = try AppStoragePaths(root: root)
        let source = paths.imports.appendingPathComponent("source.wav")
        let target = paths.exports.appendingPathComponent("target.wav")
        let original = Data([1, 2, 3, 4])
        try original.write(to: source)
        try Data([5, 6]).write(to: target)
        let audio = AudioFileService()
        XCTAssertThrowsError(try audio.copyStreaming(from: source, to: source))
        XCTAssertThrowsError(try audio.copyStreaming(from: source, to: target))
        XCTAssertEqual(try Data(contentsOf: source), original)
        XCTAssertEqual(try Data(contentsOf: target), Data([5, 6]))
    }

    func testRelativePathRejectsSymbolicLinkOutsideManagedMusic() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = try AppStoragePaths(root: root)
        try FileManager.default.createSymbolicLink(at: paths.music.appendingPathComponent("escape"), withDestinationURL: paths.exports)
        XCTAssertThrowsError(try paths.musicURL(relativePath: "escape/audio.wav"))
    }

    func testInvalidImportLeavesNoTrackOrManagedAudio() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = try AppStoragePaths(root: root)
        let storage = try StorageCoordinator(paths: paths)
        let source = paths.imports.appendingPathComponent("空 audio.wav")
        try Data().write(to: source)
        do { _ = try await storage.importAudio(from: source); XCTFail("Empty audio must fail validation") }
        catch { XCTAssertEqual(try storage.tracks.all().count, 0) }
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: paths.music.path).isEmpty)
    }

    func testPlaybackSnapshotAndQueueRollbackTogetherOnForeignKeyFailure() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = try StorageCoordinator(paths: AppStoragePaths(root: root))
        var snapshot = StoredPlaybackState(scope: "default", currentTrackID: nil, positionMs: 42, shuffleEnabled: false, repeatMode: "all", dateModified: Date())
        try storage.playback.save(snapshot)
        snapshot.positionMs = 100
        XCTAssertThrowsError(try storage.playback.saveSnapshot(snapshot, queue: [StoredQueueEntry(id: "bad", trackID: "absent", position: 0, dateAdded: Date())]))
        XCTAssertEqual(try storage.playback.state()?.positionMs, 42)
        XCTAssertTrue(try storage.playback.queue().isEmpty)
    }
}
