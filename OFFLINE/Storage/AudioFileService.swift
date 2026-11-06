import OSLog
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
    static let extensions = Set(["m4a", "mp3", "aac", "wav", "aiff", "aif", "caf"])
    static func isSupported(_ url: URL) -> Bool { extensions.contains(url.pathExtension.lowercased()) }
}

final class AudioFileService {
    func validate(_ url: URL) async throws -> AudioMetadata {
        guard SupportedAudioFormat.isSupported(url) else { throw StorageError.unsupportedAudio }
        let asset = AVURLAsset(url: url)
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        guard !tracks.isEmpty else { throw StorageError.unsupportedAudio }
        let duration = try await asset.load(.duration)
        guard duration.seconds.isFinite, duration.seconds > 0 else { throw StorageError.unsupportedAudio }
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
        let signposter = OSSignposter(subsystem: "com.th07.muzikbelesh", category: "Performance")
        let interval = signposter.beginInterval("AudioHash")
        defer { signposter.endInterval("AudioHash", interval) }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let data = try handle.read(upToCount: 1024 * 1024), !data.isEmpty { hasher.update(data: data) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    func copyStreaming(from source: URL, to destination: URL,
                       write: (FileHandle, Data) throws -> Void = { try $0.write(contentsOf: $1) }) throws {
        guard source.resolvingSymlinksInPath().standardizedFileURL != destination.resolvingSymlinksInPath().standardizedFileURL else { throw StorageError.invalidPath }
        let input = try FileHandle(forReadingFrom: source)
        defer { try? input.close() }
        guard !FileManager.default.fileExists(atPath: destination.path), FileManager.default.createFile(atPath: destination.path, contents: nil) else { throw StorageError.exportFailed }
        do {
            let output = try FileHandle(forWritingTo: destination)
            defer { try? output.close() }
            while let data = try input.read(upToCount: 1024 * 1024), !data.isEmpty {
                try Task.checkCancellation()
                try write(output, data)
            }
        } catch {
            try? FileManager.default.removeItem(at: destination)
            throw error
        }
    }
}
