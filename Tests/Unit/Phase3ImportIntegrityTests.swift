import XCTest
import GRDB
@testable import OFFLINE

final class Phase3ImportIntegrityTests: XCTestCase {
    func testImportWithoutMetadataCommitsAndDuplicateIsDetected() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("MuzikBelesh-Import-\(UUID().uuidString)")
        let paths = try AppStoragePaths(root: root)
        let coordinator = try StorageCoordinator(paths: paths)
        let source = paths.imports.appendingPathComponent("voice-note.wav")
        try makeWAV().write(to: source)

        let first = try await coordinator.importAudio(from: source)
        XCTAssertFalse(first.duplicate)
        XCTAssertEqual(first.track.artistID, nil)
        XCTAssertEqual(first.track.albumID, nil)
        XCTAssertTrue(FileManager.default.fileExists(atPath: (try paths.musicURL(relativePath: first.track.fileRelativePath)).path))

        let duplicate = try await coordinator.importAudio(from: source)
        XCTAssertTrue(duplicate.duplicate)
        XCTAssertEqual(duplicate.track.id, first.track.id)
        XCTAssertEqual(try coordinator.tracks.all().count, 1)
        _ = try StorageCoordinator(paths: paths)
    }

    func testForeignKeyTransactionRollsBackTrackAndParentsTogether() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("MuzikBelesh-Rollback-\(UUID().uuidString)")
        let manager = try DatabaseManager.live(paths: AppStoragePaths(root: root))
        XCTAssertThrowsError(try manager.dbQueue.write { db in
            try db.execute(sql: "INSERT INTO tracks (id, title, artistID, albumID, durationMs, fileRelativePath, fileExtension, fileSizeBytes, contentSHA256, artworkRelativePath, availability, dateAdded, dateModified, originalFilename, metadataSource) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)", arguments: ["bad", "Bad", "missing-artist", nil, nil, "bad.wav", "wav", 1, "bad-hash", nil, "available", Date(), Date(), "bad.wav", "test"])
        })
        XCTAssertEqual(try manager.dbQueue.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM tracks") ?? 0 }, 0)
    }

    private func makeWAV() -> Data {
        let sampleRate: UInt32 = 8_000; let payloadSize: UInt32 = sampleRate * 2; var data = Data()
        data.append(contentsOf: Array("RIFF".utf8)); data.appendLE(36 + payloadSize); data.append(contentsOf: Array("WAVEfmt ".utf8)); data.appendLE(UInt32(16)); data.appendLE(UInt16(1)); data.appendLE(UInt16(1)); data.appendLE(sampleRate); data.appendLE(sampleRate * 2); data.appendLE(UInt16(2)); data.appendLE(UInt16(16)); data.append(contentsOf: Array("data".utf8)); data.appendLE(payloadSize); data.append(Data(repeating: 0, count: Int(payloadSize))); return data
    }
}

private extension Data {
    mutating func appendLE<T: FixedWidthInteger>(_ value: T) { var value = value.littleEndian; Swift.withUnsafeBytes(of: &value) { append(contentsOf: $0) } }
}
