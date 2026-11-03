import Foundation
import CryptoKit
import GRDB
import SwiftUI
import UniformTypeIdentifiers

struct ImportResult: Equatable { let track: StoredTrack; let duplicate: Bool }

final class StorageCoordinator: ObservableObject {
    let paths: AppStoragePaths
    let database: DatabaseManager
    let tracks: GRDBTrackRepository
    let playlists: GRDBPlaylistRepository
    let settings: GRDBSettingsRepository
    let playback: GRDBPlaybackRepository
    let downloads: GRDBDownloadJobRepository
    let audio = AudioFileService()
    @Published private(set) var library: [StoredTrack] = []
    @Published var lastError: String?

    init(paths: AppStoragePaths) throws {
        self.paths = paths
        database = try DatabaseManager.live(paths: paths)
        tracks = GRDBTrackRepository(db: database.dbQueue)
        playlists = GRDBPlaylistRepository(db: database.dbQueue)
        settings = GRDBSettingsRepository(db: database.dbQueue)
        playback = GRDBPlaybackRepository(db: database.dbQueue)
        downloads = GRDBDownloadJobRepository(db: database.dbQueue)
        try downloads.markInterrupted()
        try reconcileMissingFiles()
        reload()
    }

    func reload() { do { library = try tracks.all() } catch { lastError = "Local music could not be loaded." } }
    func artistName(for id: String?) -> String? { guard let id else { return nil }; return try? database.dbQueue.read { try String.fetchOne($0, sql: "SELECT name FROM artists WHERE id = ?", arguments: [id]) } }
    func albumTitle(for id: String?) -> String? { guard let id else { return nil }; return try? database.dbQueue.read { try String.fetchOne($0, sql: "SELECT title FROM albums WHERE id = ?", arguments: [id]) } }

    @discardableResult
    func importAudio(from source: URL) async throws -> ImportResult {
        guard source.startAccessingSecurityScopedResource() || source.isFileURL else { throw StorageError.invalidPath }
        defer { source.stopAccessingSecurityScopedResource() }
        let operationID = UUID().uuidString
        let ext = source.pathExtension.lowercased()
        let stagingName = "\(operationID).\(ext)"
        let stagingURL = paths.imports.appendingPathComponent(stagingName)
        let operation = StoredImportOperation(id: operationID, sourceFilename: source.lastPathComponent, stagingRelativePath: stagingName, state: "staging", errorMessage: nil, dateStarted: Date(), dateUpdated: Date())
        var destination: URL?
        var artworkURL: URL?
        do {
            try await database.dbQueue.write { try operation.save($0) }
            try Task.checkCancellation()
            let metadata = try await audio.validate(source)
            try audio.copyStreaming(from: source, to: stagingURL)
            let hash = try audio.sha256(url: stagingURL)
            if let existing = try tracks.find(contentSHA256: hash) {
                try? FileManager.default.removeItem(at: stagingURL)
                return ImportResult(track: existing, duplicate: true)
            }

            let id = operationID
            let relativeAudio = "\(id).\(ext)"
            destination = try paths.musicURL(relativePath: relativeAudio)
            let artworkRelative: String?
            if let artworkData = metadata.artworkData {
                let name = "\(id).jpg"
                artworkURL = try paths.artworkURL(relativePath: name)
                try artworkData.write(to: artworkURL!, options: .atomic)
                artworkRelative = name
            } else {
                artworkRelative = nil
            }

            let artistName = normalizedOptional(metadata.artist)
            let albumTitle = normalizedOptional(metadata.album)
            let artistID = try artistName.map { name in
                try database.dbQueue.read { db in try String.fetchOne(db, sql: "SELECT id FROM artists WHERE normalizedName = ? LIMIT 1", arguments: [name]) } ?? stableID(prefix: "artist", value: name)
            }
            let albumID = try albumTitle.map { title in
                try database.dbQueue.read { db in try String.fetchOne(db, sql: "SELECT id FROM albums WHERE normalizedTitle = ? AND artistID IS ? LIMIT 1", arguments: [title, artistID]) } ?? stableID(prefix: "album", value: "\(title)|\(artistName ?? "")")
            }
            let now = Date()
            let track = StoredTrack(id: id, title: metadata.title, artistID: artistID, albumID: albumID, durationMs: metadata.durationMs, fileRelativePath: relativeAudio, fileExtension: ext, fileSizeBytes: (try FileManager.default.attributesOfItem(atPath: stagingURL.path)[.size] as? NSNumber)?.int64Value ?? 0, contentSHA256: hash, artworkRelativePath: artworkRelative, availability: .available, dateAdded: now, dateModified: now, originalFilename: source.lastPathComponent, metadataSource: "local_import")

            try audio.copyStreaming(from: stagingURL, to: destination!)
            try Task.checkCancellation()
            try await database.dbQueue.write { db in
                try operation.save(db)
                if let artistName, let artistID {
                    try db.execute(sql: "INSERT OR IGNORE INTO artists (id, name, normalizedName, dateAdded, dateModified) VALUES (?, ?, ?, ?, ?)", arguments: [artistID, metadata.artist!, artistName, now, now])
                }
                if let albumTitle, let albumID {
                    try db.execute(sql: "INSERT OR IGNORE INTO albums (id, title, normalizedTitle, artistID, dateAdded, dateModified) VALUES (?, ?, ?, ?, ?, ?)", arguments: [albumID, metadata.album!, albumTitle, artistID, now, now])
                }
                // Parent rows must exist before SQLite validates the track foreign keys.
                try track.save(db)
                try db.execute(sql: "UPDATE import_operations SET state = 'committed', dateUpdated = ? WHERE id = ?", arguments: [now, operationID])
            }
            try? FileManager.default.removeItem(at: stagingURL)
            await MainActor.run { reload() }
            return ImportResult(track: track, duplicate: false)
        } catch {
            try? FileManager.default.removeItem(at: stagingURL)
            if let destination { try? FileManager.default.removeItem(at: destination) }
            if let artworkURL { try? FileManager.default.removeItem(at: artworkURL) }
            try? await database.dbQueue.write { db in try db.execute(sql: "UPDATE import_operations SET state = 'rolled_back', dateUpdated = ? WHERE id = ?", arguments: [Date(), operationID]) }
            throw error is StorageError ? error : StorageError.importIncomplete
        }
    }

    func exportAudio(track: StoredTrack, to destination: URL) throws {
        let source = try paths.musicURL(relativePath: track.fileRelativePath)
        guard FileManager.default.fileExists(atPath: source.path) else { throw StorageError.missingFile }
        let target = destination.hasDirectoryPath ? destination.appendingPathComponent(safeFilename(track.title, fileExtension: track.fileExtension)) : destination
        try audio.copyStreaming(from: source, to: target)
        guard try audio.sha256(url: source) == audio.sha256(url: target) else { throw StorageError.exportFailed }
    }

    func reconcileMissingFiles() throws {
        let interrupted = try database.dbQueue.read { try StoredImportOperation.filter(Column("state") == "staging").fetchAll($0) }
        for operation in interrupted where UUID(uuidString: operation.id) != nil {
            guard try tracks.find(id: operation.id) == nil else { continue }
            let ext = URL(fileURLWithPath: operation.stagingRelativePath).pathExtension
            guard SupportedAudioFormat.extensions.contains(ext) else { continue }
            let audio = try paths.musicURL(relativePath: "\(operation.id).\(ext)")
            let artwork = try paths.artworkURL(relativePath: "\(operation.id).jpg")
            for file in [audio, artwork] where FileManager.default.fileExists(atPath: file.path) { try FileManager.default.removeItem(at: file) }
            try database.dbQueue.write { db in try db.execute(sql: "UPDATE import_operations SET state = 'rolled_back', dateUpdated = ? WHERE id = ?", arguments: [Date(), operation.id]) }
        }
        for track in try tracks.all() { let url = try paths.musicURL(relativePath: track.fileRelativePath); if !FileManager.default.fileExists(atPath: url.path) { try tracks.updateAvailability(id: track.id, .missing) } }
        for file in (try? FileManager.default.contentsOfDirectory(at: paths.imports, includingPropertiesForKeys: nil)) ?? [] { try? FileManager.default.removeItem(at: file) }
    }

    private func stableID(prefix: String, value: String) -> String { "\(prefix)-" + SHA256.hash(data: Data(normalized(value).utf8)).map { String(format: "%02x", $0) }.joined() }
    private func normalized(_ value: String) -> String { value.trimmingCharacters(in: .whitespacesAndNewlines).folding(options: .diacriticInsensitive, locale: .current).lowercased() }
    private func normalizedOptional(_ value: String?) -> String? {
        guard let value else { return nil }
        let result = normalized(value)
        return result.isEmpty ? nil : result
    }
    private func safeFilename(_ title: String, fileExtension: String) -> String { let clean = title.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: "\\", with: "-"); return "\(clean).\(fileExtension)" }
}

extension UTType {
    static var supportedAudio: UTType { UTType(filenameExtension: "m4a") ?? .audio }
}
