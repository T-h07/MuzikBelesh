import Foundation
import XCTest
@testable import OFFLINE

final class PlaylistImportParserTests: XCTestCase {
    private typealias F = PlaylistImportFixtures

    func testAccountDataShapeMultiplePlaylistsEmptyAndRepeatedOccurrences() throws {
        let report = try F.parse(F.json([F.playlist(5), F.playlist(0, name: "Empty")]), filename: "Playlist1.json")
        XCTAssertEqual(report.validCount, 2)
        let source = try XCTUnwrap(report.candidates[0].source)
        XCTAssertEqual(source.source, .spotifyAccountExport)
        XCTAssertEqual(source.entries.map(\.title), ["Song 0", "Song 1", "Song 2", "Song 0", "Song 1"])
        XCTAssertEqual(source.entries.map(\.position), [0, 1, 2, 3, 4])
        XCTAssertEqual(Set(source.entries.map(\.id)).count, 5)
        XCTAssertTrue(source.entries.allSatisfy { $0.sourceURI == F.trackURI && $0.durationMs == nil })
        XCTAssertEqual(report.candidates[1].source?.entries.count, 0)
    }

    func testMissingOptionalJSONFieldsAreNilAndListeningTimeIsNotDuration() throws {
        let playlist: [String: Any] = ["name": "Minimal", "items": [["track": ["trackName": "Minimal", "msPlayed": 1234]]]]
        let report = try F.parse(F.json([playlist]), filename: "Playlist2.json")
        let entry = try XCTUnwrap(report.candidates.first?.source?.entries.first)
        XCTAssertNil(entry.primaryArtist); XCTAssertNil(entry.album); XCTAssertNil(entry.durationMs)
        XCTAssertNil(entry.sourceTrackID); XCTAssertNil(entry.sourceURI); XCTAssertNil(entry.artworkURL)
    }

    func testDocumentFailuresAreExplicit() throws {
        for value in ["{", "[]", "{}", "{\"items\":[]}", "[{\"msPlayed\":12}]", "{\"playlists\":null}"] {
            let report = try F.parse(Data(value.utf8), filename: "StreamingHistory0.json")
            XCTAssertEqual(report.validCount, 0); XCTAssertEqual(report.candidates.count, 1)
            XCTAssertTrue(report.candidates[0].diagnostics[0].contains("not imported"))
        }
    }

    func testInvalidPlaylistDoesNotDiscardValidSiblingOrRenumberOccurrences() throws {
        let badItems: [[String: Any]] = [
            ["track": ["artistName": "Artist"]], ["episode": ["episodeName": "Podcast"]],
            ["localTrack": ["trackName": "Local"]], ["track": NSNull()],
            ["track": ["trackName": "Song"], "position": 9],
            ["track": ["trackName": 123]], ["track": ["trackName": "Song", "durationMs": -1]],
            ["track": ["trackName": "Song", "durationMs": true]],
            ["track": ["trackName": "Song", "trackUri": "spotify:episode:0000000000000000000001"]]
        ]
        for badItem in badItems {
            let bad: [String: Any] = ["name": "Bad playlist", "items": [F.item(), badItem, F.item()]]
            let report = try F.parse(F.json([bad, F.playlist(2)]), filename: "Playlist1.json")
            XCTAssertNil(report.candidates[0].source); XCTAssertEqual(report.candidates[0].entryCount, 3)
            XCTAssertTrue(report.candidates[0].diagnostics[0].contains("items[1]"))
            XCTAssertEqual(report.candidates[1].source?.entries.map(\.position), [0, 1])
        }
        for bad in [["items": []] as [String: Any], ["name": "  ", "items": []], ["name": "No items"], F.playlist(10001)] {
            XCTAssertEqual(try F.parse(F.json([bad]), filename: "Playlist1.json").validCount, 0)
        }
    }

    func testExplicitJSONOptionalMetadataAndSafeArtwork() throws {
        let track: [String: Any] = ["trackName": "Title", "artistName": "Lead", "additionalArtists": ["Guest"], "albumName": "Album", "durationMs": 123,
                                    "trackUri": F.trackURI, "artworkUrl": "https://example.invalid/art.png"]
        let value: [String: Any] = ["name": "Named", "playlistUri": "spotify:playlist:0000000000000000000003", "items": [["track": track, "position": 0]]]
        let source = try XCTUnwrap(F.parse(F.json([value]), filename: "Playlist1.json").candidates.first?.source)
        XCTAssertEqual(source.sourcePlaylistID, "0000000000000000000003")
        XCTAssertEqual(source.entries[0].additionalArtists, ["Guest"])
        XCTAssertEqual(source.entries[0].durationMs, 123)
        XCTAssertEqual(source.entries[0].artworkURL?.host, "example.invalid")
    }

    func testRFC4180BOMReorderingUnknownFieldsEscapedQuotesAndMultiline() throws {
        let csv = "\u{feff}Extra,Album Name,Track Name,Artist Name(s),Track Duration (ms),Track URI\r\n" +
            "ignored,,\"Hello, \"\"World\"\"\r\nAgain\",\"Earth, Wind & Fire\",,\(F.trackURI)\r\n"
        let source = try XCTUnwrap(F.parse(Data(csv.utf8), filename: "  Road Trip .csv").candidates.first?.source)
        XCTAssertEqual(source.name, "Road Trip")
        XCTAssertEqual(source.entries[0].title, "Hello, \"World\"\r\nAgain")
        XCTAssertEqual(source.entries[0].primaryArtist, "Earth, Wind & Fire")
        XCTAssertEqual(source.entries[0].additionalArtists, [])
        XCTAssertNil(source.entries[0].album); XCTAssertNil(source.entries[0].durationMs)
        XCTAssertNil(source.sourcePlaylistID)
    }

    func testExportifyArtistEscapesRequireMatchingURIList() throws {
        let raw = "AC\\, DC, Guest"
        let artists = try ExportifyCSVParser.artists(raw, uris: "\(F.artistURI), \(F.artistURI)", location: "record 2")
        XCTAssertEqual(artists, ["AC, DC", "Guest"])
        XCTAssertEqual(try ExportifyCSVParser.artists(raw, uris: nil, location: "record 2"), [raw])
        XCTAssertEqual(try ExportifyCSVParser.artists("Artist & Friend; Jr.", uris: nil, location: "record 2"), ["Artist & Friend; Jr."])
    }

    func testCSVInvalidHeadersRecordsAndDurationsRejectWholePlaylist() throws {
        let invalid = [
            "Artist Name(s)\nArtist\n", "Track Name, track name \nA,B\n",
            "Track Name\n\"unclosed", "Track Name\n\"closed\"extra", "Track Name\nquote\"bad",
            "Track Name\nA,B", "Track Name\nA\rB", "Track Name\nA\n\nB",
            "Track Name\n   ", "Track Name,Track Duration (ms)\nA,-1", "Track Name,Track Duration (ms)\nA,1.5",
            "Track Name,Track Duration (ms)\nA,9223372036854775808", "Track Name,Track Duration (ms)\nA,+1",
            "Track Name,Track Duration (ms)\nA, 1", "Track Name,Track URI\nA,spotify:local:Artist:Album:Title:5"
        ]
        for csv in invalid {
            let report = try F.parse(Data(csv.utf8))
            XCTAssertEqual(report.validCount, 0)
            XCTAssertNil(report.candidates[0].source)
            XCTAssertTrue(report.candidates[0].diagnostics[0].contains("Synthetic.csv"))
        }
        let report = try F.parse(Data("Track Name,Track Duration (ms)\nA,0\nB,9223372036854775807\n".utf8))
        XCTAssertEqual(report.candidates[0].source?.entries.map(\.durationMs), [0, Int64.max])
    }

    func testUTF8FieldColumnAndOccurrenceLimits() throws {
        for bytes in [Data([0xff, 0xfe]), Data(("Track Name\n" + String(repeating: "a", count: 16385)).utf8), F.csv(10001),
                      Data(("Track Name," + (0..<128).map { "Column\($0)" }.joined(separator: ",")).utf8)] {
            XCTAssertEqual(try F.parse(bytes).validCount, 0)
        }
        XCTAssertThrowsError(try F.parse(Data(repeating: 0, count: PlaylistImportLimits.inputBytes + 1)))
        let deep = Data((String(repeating: "[", count: 65) + "0" + String(repeating: "]", count: 65)).utf8)
        XCTAssertEqual(try F.parse(deep, filename: "Deep.json").validCount, 0)
    }

    func testCSVEmptyAndDuplicatesArePreservedWithoutAudioOrUnsafeArtwork() throws {
        XCTAssertEqual(try F.parse(Data("Track Name\n".utf8)).candidates.first?.source?.entries.count, 0)
        let csv = "Track Name,Track URI,Album Image URL,Track Preview URL\nA,\(F.trackURI),https://example.invalid/art?token=synthetic,https://example.invalid/audio\nA,\(F.trackURI),,\n"
        let candidate = try XCTUnwrap(F.parse(Data(csv.utf8)).candidates.first)
        let entries = try XCTUnwrap(candidate.source?.entries)
        XCTAssertEqual(entries.count, 2); XCTAssertNotEqual(entries[0].id, entries[1].id)
        XCTAssertEqual(entries.map(\.position), [0, 1]); XCTAssertTrue(entries.allSatisfy { $0.artworkURL == nil })
        XCTAssertTrue(candidate.diagnostics.contains { $0.contains("artwork was discarded") })
    }
}
