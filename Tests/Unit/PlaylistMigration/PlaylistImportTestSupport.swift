import Foundation
import XCTest
import ZIPFoundation
@testable import OFFLINE

enum PlaylistImportFixtures {
    static let trackURI = "spotify:track:0000000000000000000001"
    static let artistURI = "spotify:artist:0000000000000000000002"
    static func csv(_ count: Int, prefix: String = "Song") -> Data {
        Data(("Track Name,Artist Name(s),Album Name,Track Duration (ms),Track URI\n" + (0..<count).map {
            "\(prefix) \($0 % 3),Synthetic Artist,Synthetic Album,180000,\(trackURI)\n"
        }.joined()).utf8)
    }
    static func item(_ title: String = "Synthetic Song") -> [String: Any] {
        ["track": ["trackName": title, "artistName": "Synthetic Artist", "albumName": "Synthetic Album", "trackUri": trackURI], "episode": NSNull(), "localTrack": NSNull(), "addedDate": "2025-01-01"]
    }
    static func playlist(_ count: Int = 3, name: String = "Synthetic Playlist") -> [String: Any] {
        ["name": name, "lastModifiedDate": "2025-01-01", "description": "Synthetic fixture", "numberOfFollowers": 0, "items": (0..<count).map { item("Song \($0 % 3)") }]
    }
    static func json(_ playlists: [[String: Any]]) throws -> Data { try JSONSerialization.data(withJSONObject: ["playlists": playlists], options: [.sortedKeys]) }
    static func zip(_ files: [(String, Data)], compression: CompressionMethod = .deflate, type: Entry.EntryType = .file) throws -> Data {
        let archive = try Archive(data: Data(), accessMode: .create)
        for (path, bytes) in files {
            try archive.addEntry(with: path, type: type, uncompressedSize: Int64(bytes.count), compressionMethod: compression) { position, count in
                bytes.subdata(in: Int(position)..<(Int(position) + count))
            }
        }
        return try XCTUnwrap(archive.data)
    }
    static func importer(_ fixture: LibraryFixture) -> PlaylistMetadataFileImporter { .init(stagingRoot: fixture.paths.imports) }
    static func parse(_ bytes: Data, filename: String = "Synthetic.csv") throws -> PlaylistImportReport {
        try PlaylistMetadataFileImporter(stagingRoot: FileManager.default.temporaryDirectory).parse(bytes, filename: filename)
    }
    static func signature(_ bytes: Data, _ signature: [UInt8]) throws -> Int {
        let array = [UInt8](bytes)
        return try XCTUnwrap((0...max(0, array.count - signature.count)).first { Array(array[$0..<($0 + signature.count)]) == signature })
    }
    static func put(_ value: UInt32, in bytes: inout Data, at offset: Int, length: Int = 4) {
        for index in 0..<length { bytes[offset + index] = UInt8((value >> (index * 8)) & 255) }
    }
}
