import XCTest
import GRDB
@testable import OFFLINE

/// Phase 10.9 final hardening: untrusted audio metadata and import resource handling.
/// Every test uses an isolated temporary storage root, never the user's library.
final class ReleaseHardeningTests: XCTestCase {
    private var roots: [URL] = []

    override func tearDown() {
        roots.forEach { try? FileManager.default.removeItem(at: $0) }
        roots = []
        super.tearDown()
    }

    func testMetadataSanitizerBoundsTextAndReplacesControlCharacters() {
        let long = String(repeating: "é", count: 5_000)
        let metadata = AudioMetadata(title: "  Song\u{0}\nTitle  ", artist: "Band\u{7}  Name", album: long, durationMs: 1_000, artworkData: nil)
        let clean = metadata.sanitizedForLibrary(fallbackTitle: "file")
        XCTAssertEqual(clean.title, "Song  Title")
        XCTAssertEqual(clean.artist, "Band Name")
        XCTAssertEqual(clean.album?.count, AudioMetadata.libraryTextLimit)
        XCTAssertEqual(clean.durationMs, 1_000)

        let empty = AudioMetadata(title: "\u{0}\u{1} ", artist: " \n", album: "", durationMs: nil, artworkData: nil)
            .sanitizedForLibrary(fallbackTitle: "voice-note")
        XCTAssertEqual(empty.title, "voice-note")
        XCTAssertNil(empty.artist)
        XCTAssertNil(empty.album)
        XCTAssertEqual(AudioMetadata(title: "", artist: nil, album: nil, durationMs: nil, artworkData: nil)
            .sanitizedForLibrary(fallbackTitle: "").title, "Untitled")

        // Ordinary metadata is unchanged.
        let ordinary = AudioMetadata(title: "Neon  Afterglow", artist: "Luna Vale", album: "City Lights", durationMs: 214_000, artworkData: nil)
        XCTAssertEqual(ordinary.sanitizedForLibrary(fallbackTitle: "x"), ordinary)
    }

    /// Before the fix, an artist (channel) name over 300 characters made the whole import
    /// fail with `LibraryError.invalidMetadata`, and an unbounded title was stored.
    func testOverlongProviderMetadataStillImportsWithBoundedText() async throws {
        let (paths, coordinator) = try makeStorage()
        let source = paths.imports.appendingPathComponent("long-metadata.wav")
        try makeWAV().write(to: source)
        let video = YouTubeVideo(id: "abcdefghijk", title: String(repeating: "T", count: 5_000) + "\u{0}",
                                 channel: String(repeating: "C", count: 400), thumbnailURL: nil, duration: nil)

        let result = try await coordinator.importAudio(from: source, sourceType: "youtube", sourceIdentifier: video.id, video: video)

        XCTAssertFalse(result.duplicate)
        XCTAssertEqual(result.track.title.count, AudioMetadata.libraryTextLimit)
        XCTAssertNil(result.track.title.rangeOfCharacter(from: .controlCharacters))
        let (artist, foreignKeyViolations) = try databaseFacts(coordinator, artistID: result.track.artistID)
        XCTAssertEqual(artist?.count, AudioMetadata.libraryTextLimit)
        XCTAssertTrue(FileManager.default.fileExists(atPath: try paths.musicURL(relativePath: result.track.fileRelativePath).path))
        XCTAssertEqual(foreignKeyViolations, 0)
        // No staging copy is left behind.
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: paths.imports.path).filter { $0 != "long-metadata.wav" }
        XCTAssertEqual(leftovers, [])
    }

    func testOrdinaryLocalImportKeepsFilenameTitleWithoutTags() async throws {
        let (paths, coordinator) = try makeStorage()
        let source = paths.imports.appendingPathComponent("My Voice Note.wav")
        try makeWAV().write(to: source)
        let result = try await coordinator.importAudio(from: source)
        XCTAssertEqual(result.track.title, "My Voice Note")
        XCTAssertNil(result.track.artistID)
        XCTAssertNil(result.track.albumID)
    }

    // MARK: Helpers

    /// Synchronous reads: inside an async test, `read` would resolve to GRDB's async overload.
    private func databaseFacts(_ coordinator: StorageCoordinator, artistID: String?) throws -> (String?, Int) {
        try coordinator.database.dbQueue.read { db in
            (try String.fetchOne(db, sql: "SELECT name FROM artists WHERE id = ?", arguments: [artistID]),
             try Row.fetchAll(db, sql: "PRAGMA foreign_key_check").count)
        }
    }

    private func makeStorage() throws -> (AppStoragePaths, StorageCoordinator) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("MuzikBelesh-Hardening-\(UUID().uuidString)")
        roots.append(root)
        let paths = try AppStoragePaths(root: root)
        return (paths, try StorageCoordinator(paths: paths))
    }

    /// One second of 8 kHz mono 16-bit silence.
    private func makeWAV() -> Data {
        let sampleRate: UInt32 = 8_000, payload: UInt32 = sampleRate * 2
        var data = Data()
        func append<T: FixedWidthInteger>(_ value: T) { var value = value.littleEndian; withUnsafeBytes(of: &value) { data.append(contentsOf: $0) } }
        data.append(contentsOf: Array("RIFF".utf8)); append(36 + payload)
        data.append(contentsOf: Array("WAVEfmt ".utf8)); append(UInt32(16)); append(UInt16(1)); append(UInt16(1))
        append(sampleRate); append(sampleRate * 2); append(UInt16(2)); append(UInt16(16))
        data.append(contentsOf: Array("data".utf8)); append(payload)
        data.append(Data(repeating: 0, count: Int(payload)))
        return data
    }
}
