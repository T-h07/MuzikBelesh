import XCTest
@testable import OFFLINE

final class Phase3AudioTests: XCTestCase {
    func testPlaybackContextHasPredictablePreviousAndNext() {
        let context = PlaybackContext(trackIDs: ["a", "b", "c"], currentIndex: 1)
        XCTAssertEqual(context.previousID, "a"); XCTAssertEqual(context.nextID, "c")
        XCTAssertNil(context.settingCurrent("missing").nextID)
    }

    func testPlaybackStateDoesNotAllowInvalidSeekValues() {
        var state = AudioPlaybackState(currentTrackID: "track", status: .paused, elapsedTime: 0, duration: 0)
        XCTAssertFalse(state.canSeek)
        state.duration = 120; XCTAssertTrue(state.canSeek)
    }

    func testAVPlayerLoadsManagedWAVAsset() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("MuzikBelesh-Audio-\(UUID().uuidString)", isDirectory: true)
        let paths = try AppStoragePaths(root: root); let storage = try StorageCoordinator(paths: paths); let url = try paths.musicURL(relativePath: "fixture.wav"); try makeWAV(seconds: 1).write(to: url)
        let now = Date(); try storage.tracks.save(StoredTrack(id: "fixture", title: "Fixture", artistID: nil, albumID: nil, durationMs: 1000, fileRelativePath: "fixture.wav", fileExtension: "wav", fileSizeBytes: Int64(try Data(contentsOf: url).count), contentSHA256: "fixture-hash", artworkRelativePath: nil, availability: .available, dateAdded: now, dateModified: now, originalFilename: "fixture.wav", metadataSource: "test"))
        let service = await MainActor.run { AudioPlayerService(storage: storage) }
        try await service.play(trackID: "fixture")
        let state = await MainActor.run { service.state }
        XCTAssertEqual(state.currentTrackID, "fixture")
        XCTAssertNotEqual(state.status, .failed(message: "Audio could not be loaded"))
    }

    private func makeWAV(seconds: Int) -> Data {
        let sampleRate: UInt32 = 8_000; let channels: UInt16 = 1; let bits: UInt16 = 16; let samples = Int(sampleRate) * seconds; let payloadSize = UInt32(samples * Int(channels) * Int(bits / 8)); var data = Data()
        data.append(contentsOf: Array("RIFF".utf8)); data.appendLittleEndian(UInt32(36) + payloadSize); data.append(contentsOf: Array("WAVEfmt ".utf8)); data.appendLittleEndian(UInt32(16)); data.appendLittleEndian(UInt16(1)); data.appendLittleEndian(channels); data.appendLittleEndian(sampleRate); data.appendLittleEndian(sampleRate * UInt32(channels) * UInt32(bits / 8)); data.appendLittleEndian(UInt16(channels * (bits / 8))); data.appendLittleEndian(bits); data.append(contentsOf: Array("data".utf8)); data.appendLittleEndian(payloadSize); data.append(Data(repeating: 0, count: Int(payloadSize))); return data
    }
}

private extension Data {
    mutating func appendLittleEndian<T: FixedWidthInteger>(_ value: T) { var value = value.littleEndian; Swift.withUnsafeBytes(of: &value) { append(contentsOf: $0) } }
}
