#if DEBUG
import Foundation
import GRDB
import UIKit

/// Deterministic, offline Phase 11.5 artwork fixtures for UI tests (`--artwork-fixtures`).
/// Covers are generated locally as solid-colour JPEGs; nothing is downloaded.
///
/// - `artwork-five` "Five Covers": six songs, five distinct covers (songs 2 and 3 share one).
/// - `artwork-two` "Two Covers": two covers (partial mosaic).
/// - `artwork-empty` "Empty Mix": no songs (generic placeholder).
/// - `artwork-custom` "Custom Cover": four covers and a user-chosen cover (custom priority).
/// - "Mosaic Album": four songs, two of them sharing one cover (three distinct covers).
/// - 40 "Bulk Mix" playlists for scrolling a long list of mosaics.
enum ArtworkFixtureSeeder {
    static let playlistIDs = (five: "artwork-five", two: "artwork-two", empty: "artwork-empty", custom: "artwork-custom")
    static let customCover = "artwork-00000000-0000-4000-8000-0000000000c0.jpg"

    static func seed(_ storage: StorageCoordinator) throws {
        let colors: [UIColor] = [.systemRed, .systemOrange, .systemYellow, .systemGreen, .systemBlue, .systemPurple]
        func cover(_ name: String, _ color: UIColor) throws {
            let format = UIGraphicsImageRendererFormat(); format.scale = 1
            let data = UIGraphicsImageRenderer(size: CGSize(width: 96, height: 96), format: format).jpegData(withCompressionQuality: 0.9) { context in
                color.setFill(); context.fill(CGRect(x: 0, y: 0, width: 96, height: 96))
                UIColor.white.withAlphaComponent(0.35).setFill(); context.fill(CGRect(x: 0, y: 64, width: 96, height: 32))
            }
            try data.write(to: storage.paths.artworkURL(relativePath: name), options: .atomic)
            try ManagedLibraryFiles.imageData(data, pixels: 256).write(to: storage.paths.artworkURL(relativePath: ManagedLibraryFiles.thumbnailName(name)), options: .atomic)
        }
        for (index, color) in colors.enumerated() { try cover("artwork-fixture-\(index + 1).jpg", color) }
        try cover(customCover, .systemPink)

        let repository = LibraryRepository(db: storage.database.dbQueue)
        var trackIDs: [String] = []
        for index in 1...6 {
            let id = "art-track-\(index)"
            let url = try storage.paths.musicURL(relativePath: "\(id).wav")
            try LibraryFixtureAudio.wav(seed: index).write(to: url)
            let now = Date(timeIntervalSince1970: 1_600_000_100 + Double(index))
            let artwork = "artwork-fixture-\(index).jpg"
            try storage.tracks.save(StoredTrack(id: id, title: "Cover Song \(index)", artistID: nil, albumID: nil, durationMs: 500, fileRelativePath: url.lastPathComponent,
                                                fileExtension: "wav", fileSizeBytes: Int64(try Data(contentsOf: url).count), contentSHA256: try storage.audio.sha256(url: url),
                                                artworkRelativePath: artwork, availability: .available, dateAdded: now, dateModified: now,
                                                originalFilename: url.lastPathComponent, metadataSource: "ui-test"))
            try repository.editMetadata(trackID: id, draft: TrackMetadataDraft(title: "Cover Song \(index)", artist: "Mosaic Artist", album: index <= 4 ? "Mosaic Album" : ""))
            trackIDs.append(id)
        }
        // Songs 2 and 3 (both in the album) share one cover file.
        try storage.database.dbQueue.write { db in
            try db.execute(sql: "UPDATE tracks SET artworkRelativePath = 'artwork-fixture-2.jpg' WHERE id = 'art-track-3'")
        }
        try storage.database.dbQueue.write { db in
            func playlist(_ id: String, _ name: String, _ order: Int, songs: [String], cover: String? = nil) throws {
                let date = Date(timeIntervalSince1970: 1_500_000_000 + Double(order))
                try StoredPlaylist(id: id, name: name, description: nil, artworkRelativePath: cover, dateAdded: date, dateModified: date).insert(db)
                if !songs.isEmpty { try LibraryRepository.replaceMembership(songs, playlistID: id, db: db) }
            }
            try playlist(playlistIDs.five, "Five Covers", 0, songs: trackIDs)
            try playlist(playlistIDs.two, "Two Covers", 1, songs: ["art-track-2", "art-track-4"])
            try playlist(playlistIDs.empty, "Empty Mix", 2, songs: [])
            try playlist(playlistIDs.custom, "Custom Cover", 3, songs: Array(trackIDs.prefix(4)), cover: customCover)
            for index in 1...40 {
                let rotated = Array(trackIDs[(index % 6)...] + trackIDs[..<(index % 6)])
                try playlist(String(format: "artwork-bulk-%02d", index), String(format: "Bulk Mix %02d", index), 10 + index, songs: Array(rotated.prefix(4 + index % 3)))
            }
        }
        storage.reload()
    }
}

/// A tiny valid PCM WAV, so fixture songs are real local recordings.
enum LibraryFixtureAudio {
    static func wav(seed: Int) -> Data {
        let samples = 4000 + seed * 200
        var result = Data()
        func le<T: FixedWidthInteger>(_ value: T) { var little = value.littleEndian; withUnsafeBytes(of: &little) { result.append(contentsOf: $0) } }
        result.append(contentsOf: "RIFF".utf8); le(UInt32(36 + samples * 2)); result.append(contentsOf: "WAVEfmt ".utf8)
        le(UInt32(16)); le(UInt16(1)); le(UInt16(1)); le(UInt32(8000)); le(UInt32(16000)); le(UInt16(2)); le(UInt16(16))
        result.append(contentsOf: "data".utf8); le(UInt32(samples * 2))
        for index in 0..<samples { le(Int16(sin(Double(index) * 2 * .pi * Double(200 + seed * 40) / 8000) * 800)) }
        return result
    }
}
#endif
