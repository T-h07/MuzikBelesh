import AVFoundation
import CoreGraphics
import Foundation
import GRDB
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import OFFLINE

final class LibraryFixture {
    let root: URL
    let paths: AppStoragePaths
    let storage: StorageCoordinator
    let repository: LibraryRepository
    var ids: [String] = []
    init(count: Int = 4) throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("Phase5-\(UUID().uuidString)")
        paths = try AppStoragePaths(root: root)
        storage = try StorageCoordinator(paths: paths)
        repository = LibraryRepository(db: storage.database.dbQueue)
        for index in 0..<count {
            let id = "song-\(index)"; let url = try paths.musicURL(relativePath: "\(id).wav")
            try Self.wav(seed: index).write(to: url)
            let date = Date(timeIntervalSince1970: 1_600_000_000 + Double(index))
            try storage.tracks.save(StoredTrack(id: id, title: "Song \(index)", artistID: nil, albumID: nil, durationMs: Int64(2000 + index * 50), fileRelativePath: url.lastPathComponent, fileExtension: "wav", fileSizeBytes: Int64(try Data(contentsOf: url).count), contentSHA256: try storage.audio.sha256(url: url), artworkRelativePath: nil, availability: .available, dateAdded: date, dateModified: date, originalFilename: url.lastPathComponent, metadataSource: "synthetic-test"))
            ids.append(id)
        }
    }
    deinit { try? FileManager.default.removeItem(at: root) }
    func file(_ index: Int) throws -> URL { try paths.musicURL(relativePath: "\(ids[index]).wav") }
    func sources() throws -> URL {
        let url = root.appendingPathComponent("Sources", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true); return url
    }
    func foreignKeys() throws -> Int { try storage.database.dbQueue.read { try Row.fetchAll($0, sql: "PRAGMA foreign_key_check").count } }
    static func wav(seed: Int, duration: Double = 2) -> Data {
        let samples = Int(duration * 8000) + seed * 400
        var result = Data()
        func le<T: FixedWidthInteger>(_ value: T) { var little = value.littleEndian; withUnsafeBytes(of: &little) { result.append(contentsOf: $0) } }
        result.append(contentsOf: "RIFF".utf8); le(UInt32(36 + samples * 2)); result.append(contentsOf: "WAVEfmt ".utf8)
        le(UInt32(16)); le(UInt16(1)); le(UInt16(1)); le(UInt32(8000)); le(UInt32(16000)); le(UInt16(2)); le(UInt16(16))
        result.append(contentsOf: "data".utf8); le(UInt32(samples * 2))
        for index in 0..<samples { le(Int16(sin(Double(index) * 2 * .pi * Double(100 + seed * 20) / 8000) * 100)) }
        return result
    }
    static func image(png: Bool = true, side: Int = 32) throws -> Data {
        let space = CGColorSpaceCreateDeviceRGB()
        let context = try XCTUnwrap(CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4, space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 0.3, green: 0.6, blue: 0.2, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: side, height: side))
        let image = try XCTUnwrap(context.makeImage()); let data = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(data, (png ? UTType.png.identifier : UTType.jpeg.identifier) as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil); XCTAssertTrue(CGImageDestinationFinalize(destination))
        return data as Data
    }
    @MainActor func services() -> (AudioPlayerService, LibraryTestTransport, MusicLibraryService) {
        let transport = LibraryTestTransport()
        let player = AudioPlayerService(storage: storage, player: transport, registerRemoteCommands: false, makeShuffle: { $0 })
        return (player, transport, MusicLibraryService(storage: storage, player: player))
    }
}

@MainActor final class LibraryTestTransport: PlaybackPlayer {
    var nativePlayer: AVPlayer? { nil }
    var isPlaying = false
    var replacements = 0
    var seeks: [Double] = []
    func play() { isPlaying = true }
    func pause() { isPlaying = false }
    func replaceCurrentItem(with item: AVPlayerItem?) { replacements += 1; isPlaying = false }
    func seek(to time: CMTime) async -> Bool { seeks.append(time.seconds); return true }
}

@MainActor func libraryEventually(_ predicate: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async {
    for _ in 0..<300 { if predicate() { return }; try? await Task.sleep(for: .milliseconds(10)) }
    XCTFail("Library observation did not reach the expected state within three seconds", file: file, line: line)
}
