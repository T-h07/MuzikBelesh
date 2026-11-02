import AVFoundation
import CryptoKit
import Foundation

struct AudioMetadata: Equatable {
    var title: String
    var artist: String?
    var album: String?
    var durationMs: Int64?
    var artworkData: Data?
}

enum SupportedAudioFormat {
    static let extensions = Set(["m4a", "mp3", "wav", "aiff", "aif", "caf"])
    static func isSupported(_ url: URL) -> Bool { extensions.contains(url.pathExtension.lowercased()) }
}

final class AudioFileService {
    func validate(_ url: URL) async throws -> AudioMetadata {
        guard SupportedAudioFormat.isSupported(url) else { throw StorageError.unsupportedAudio }
        let asset = AVURLAsset(url: url)
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        guard !tracks.isEmpty else { throw StorageError.unsupportedAudio }
        let duration = try await asset.load(.duration)
        let metadata = try await asset.load(.commonMetadata)
        var title: String?
        var artist: String?
        var album: String?
        var artwork: Data?
        for item in metadata {
            guard let key = item.commonKey else { continue }
            switch key {
            case .commonKeyTitle: title = try? await item.load(.stringValue)
            case .commonKeyArtist: artist = try? await item.load(.stringValue)
            case .commonKeyAlbumName: album = try? await item.load(.stringValue)
            case .commonKeyArtwork: artwork = try? await item.load(.dataValue)
            default: break
            }
        }
        let fallback = url.deletingPathExtension().lastPathComponent
        return AudioMetadata(title: title?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false ? title! : fallback, artist: artist, album: album, durationMs: duration.isNumeric ? Int64(duration.seconds * 1000) : nil, artworkData: artwork)
    }

    func sha256(url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while autoreleasepool(invoking: { let data = try? handle.read(upToCount: 1024 * 1024); if let data, !data.isEmpty { hasher.update(data: data); return true }; return false }) { }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    func copyStreaming(from source: URL, to destination: URL) throws {
        let input = try FileHandle(forReadingFrom: source)
        defer { try? input.close() }
        FileManager.default.createFile(atPath: destination.path, contents: nil)
        let output = try FileHandle(forWritingTo: destination)
        defer { try? output.close() }
        while let data = try input.read(upToCount: 1024 * 1024), !data.isEmpty { try output.write(contentsOf: data) }
    }
}
