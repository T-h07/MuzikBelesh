import Foundation
import XCTest
@testable import OFFLINE

/// Phase 11.4 `.mbelesh` format: versioning, structural validation and hostile input.
final class PortableLibraryFormatTests: XCTestCase {
    private typealias F = PortableFixtures

    func testValidDocumentRoundTripsAndKeepsOrderAndRepeats() throws {
        let document = F.document(songs: [F.song("s1", "One", videos: [F.videoA]), F.song("s2", "Two")],
                                  playlists: [F.playlist("p1", "Mix", ["s1", "s2", "s1"])])
        let decoded = try PortableLibraryCodec.decode(try F.data(document))
        XCTAssertEqual(decoded.collection.playlists[0].occurrences.map(\.songRef), ["s1", "s2", "s1"])
        XCTAssertEqual(decoded.collection.songs[0].recordings, [PortableRecordingReference(provider: "youtube", videoId: F.videoA)])
        XCTAssertEqual(decoded.exportId, document.exportId.uppercased())
        let summary = PortableLibrarySummary(decoded)
        XCTAssertEqual(summary.songs, 2); XCTAssertEqual(summary.occurrences, 3)
        XCTAssertEqual(summary.songsWithRecordings, 1); XCTAssertEqual(summary.songsNeedingDiscovery, 1)
    }

    func testVersioningAndRequiredFeatures() throws {
        XCTAssertThrowsError(try PortableLibraryCodec.decode(F.json(F.minimalJSON(schemaVersion: 2)))) {
            XCTAssertEqual($0 as? PortableLibraryError, .newerVersion(2))
        }
        XCTAssertThrowsError(try PortableLibraryCodec.decode(F.json(F.minimalJSON(schemaVersion: 0)))) {
            XCTAssertEqual($0 as? PortableLibraryError, .unsupportedVersion)
        }
        XCTAssertThrowsError(try PortableLibraryCodec.decode(F.json(F.minimalJSON(extra: #","requiredFeatures":["future-thing"]"#)))) {
            guard case .unsupportedFeatures = $0 as? PortableLibraryError else { return XCTFail("\($0)") }
        }
        // Unknown optional fields from a newer minor writer are ignored.
        XCTAssertNoThrow(try PortableLibraryCodec.decode(F.json(F.minimalJSON(extra: #","futureOptional":{"a":1}"#))))
        XCTAssertThrowsError(try PortableLibraryCodec.decode(F.json(F.minimalJSON(format: "spotify-export")))) {
            XCTAssertEqual($0 as? PortableLibraryError, .notALibraryFile)
        }
    }

    func testHostileBytesAreRejectedBeforeDecoding() throws {
        XCTAssertThrowsError(try PortableLibraryCodec.decode(Data([0xff, 0xfe, 0x00]))) { XCTAssertEqual($0 as? PortableLibraryError, .notUTF8) }
        XCTAssertThrowsError(try PortableLibraryCodec.decode(F.json("{\"format\":"))) { XCTAssertEqual($0 as? PortableLibraryError, .malformedJSON) }
        XCTAssertThrowsError(try PortableLibraryCodec.decode(F.json("[]"))) { XCTAssertNotNil($0 as? PortableLibraryError) }
        XCTAssertThrowsError(try PortableLibraryCodec.decode(Data(count: PortableLibraryLimits.inputBytes + 1))) {
            XCTAssertEqual($0 as? PortableLibraryError, .fileTooLarge)
        }
        let deep = String(repeating: "[", count: 40) + String(repeating: "]", count: 40)
        XCTAssertThrowsError(try PortableLibraryCodec.decode(F.json(#"{"format":"muzik-belesh-library","x":"# + deep + "}"))) {
            XCTAssertEqual($0 as? PortableLibraryError, .nestingTooDeep)
        }
    }

    func testDuplicateKeysAreRejectedIncludingEscapedSpellings() throws {
        let plain = F.minimalJSON().replacingOccurrences(of: #""scope":"library""#, with: #""scope":"library","scope":"playlist""#)
        XCTAssertThrowsError(try PortableLibraryCodec.decode(F.json(plain))) {
            guard case .duplicateKey = $0 as? PortableLibraryError else { return XCTFail("\($0)") }
        }
        let escaped = F.minimalJSON().replacingOccurrences(of: #""title":"One""#, with: #""title":"One","title":"Other""#)
        XCTAssertThrowsError(try PortableLibraryCodec.decode(F.json(escaped))) {
            guard case .duplicateKey = $0 as? PortableLibraryError else { return XCTFail("\($0)") }
        }
    }

    func testStructuralValidation() throws {
        func rejects(_ document: PortableLibraryDocument, file: StaticString = #filePath, line: UInt = #line) {
            XCTAssertThrowsError(try PortableLibraryCodec.decode(try F.data(document)), file: file, line: line)
        }
        // Missing song reference.
        rejects(F.document(songs: [F.song("s1", "One")], playlists: [F.playlist("p1", "Mix", ["s2"])]))
        // Duplicate song identity.
        rejects(F.document(songs: [F.song("s1", "One"), F.song("s1", "Two")], playlists: []))
        // Positions must equal order.
        var shuffled = F.playlist("p1", "Mix", ["s1", "s1"])
        shuffled.occurrences[1].position = 5
        rejects(F.document(songs: [F.song("s1", "One")], playlists: [shuffled]))
        // Invalid YouTube identity.
        rejects(F.document(songs: [F.song("s1", "One", videos: ["not-a-video"])], playlists: []))
        // Neither title nor recording.
        rejects(F.document(songs: [F.song("s1", nil)], playlists: []))
        // Control characters and over-long text.
        rejects(F.document(songs: [F.song("s1", "Bad\u{0007}Title")], playlists: []))
        rejects(F.document(songs: [F.song("s1", String(repeating: "x", count: 301))], playlists: []))
        // Identifier syntax.
        rejects(F.document(songs: [F.song("../etc", "One")], playlists: []))
        // Durations are bounded.
        rejects(F.document(songs: [F.song("s1", "One", duration: -1)], playlists: []))
    }

    func testUnknownProvidersAreIgnoredAndReferencesDeduplicated() throws {
        var song = F.song("s1", "One", videos: [F.videoA, F.videoA])
        song.recordings?.append(PortableRecordingReference(provider: "future-service", videoId: "anything"))
        let decoded = try PortableLibraryCodec.decode(try F.data(F.document(songs: [song], playlists: [])))
        XCTAssertEqual(decoded.collection.songs[0].recordings, [PortableRecordingReference(provider: "youtube", videoId: F.videoA)])
    }

    func testContentFingerprintIgnoresNamesAndIdentifiersButNotOrderOrRepeats() {
        let songs = ["a": F.song("a", "One"), "b": F.song("b", "Two"), "x": F.song("x", "One"), "y": F.song("y", "Two")]
        let base = PortableFingerprint.playlist(F.playlist("p1", "Mix", ["a", "b"]), songs: songs)
        XCTAssertEqual(base, PortableFingerprint.playlist(F.playlist("p9", "Renamed", ["x", "y"]), songs: songs))
        XCTAssertNotEqual(base, PortableFingerprint.playlist(F.playlist("p1", "Mix", ["b", "a"]), songs: songs))
        XCTAssertNotEqual(base, PortableFingerprint.playlist(F.playlist("p1", "Mix", ["a", "b", "b"]), songs: songs))
    }

    func testLargeDocumentAtTheDocumentedLimitsDecodes() throws {
        let songs = (0..<PortableLibraryLimits.occurrencesPerPlaylist).map { F.song("s\($0)", "Song \($0)", videos: $0 % 2 == 0 ? [F.videoA] : []) }
        let document = F.document(songs: songs, playlists: [F.playlist("p1", "Big", songs.map(\.id))])
        let data = try F.data(document)
        let started = Date()
        let decoded = try PortableLibraryCodec.decode(data)
        // Recorded for the delivery report; not a pass/fail threshold.
        print("PERF portable decode \(songs.count) songs, \(data.count) bytes: \(Date().timeIntervalSince(started))s")
        XCTAssertEqual(decoded.collection.playlists[0].occurrences.count, PortableLibraryLimits.occurrencesPerPlaylist)
        var tooMany = document
        tooMany.collection.playlists[0] = F.playlist("p1", "Big", songs.map(\.id) + ["s0"])
        XCTAssertThrowsError(try PortableLibraryCodec.decode(try F.data(tooMany)))
    }
}
