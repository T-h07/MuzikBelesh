import Foundation
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

    func reload() { library = (try? tracks.all()) ?? [] }
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
        let metadata = try await audio.validate(source)
        try audio.copyStreaming(from: source, to: stagingURL)
        let hash = try audio.sha256(url: stagingURL)
        if let existing = try tracks.find(contentSHA256: hash) { try? FileManager.default.removeItem(at: stagingURL); return ImportResult(track: existing, duplicate: true) }
        let id = UUID().uuidString
        let relativeAudio = "\(id).\(ext)"
        let destination = try paths.musicURL(relativePath: relativeAudio)
        let artworkRelative: String?
        if let artworkData = metadata.artworkData {
            let name = "\(id).jpg"
            try artworkData.write(to: try paths.artworkURL(relativePath: name), options: .atomic)
            artworkRelative = name
        } else { artworkRelative = nil }
        let artistID = metadata.artist.map { stableID(prefix: "artist", value: $0) }
        let albumID = metadata.album.map { stableID(prefix: "album", value: "\($0)|\(metadata.artist ?? "")") }
        let now = Date()
        let track = StoredTrack(id: id, title: metadata.title, artistID: artistID, albumID: albumID, durationMs: metadata.durationMs, fileRelativePath: relativeAudio, fileExtension: ext, fileSizeBytes: (try FileManager.default.attributesOfItem(atPath: stagingURL.path)[.size] as? NSNumber)?.int64Value ?? 0, contentSHA256: hash, artworkRelativePath: artworkRelative, availability: .available, dateAdded: now, dateModified: now, originalFilename: source.lastPathComponent, metadataSource: "local_import")
        try audio.copyStreaming(from: stagingURL, to: destination)
        try await database.dbQueue.write { db in
            try operation.save(db)
            try track.save(db)
            if let artist = metadata.artist { try db.execute(sql: "INSERT OR IGNORE INTO artists (id, name, normalizedName, dateAdded, dateModified) VALUES (?, ?, ?, ?, ?)", arguments: [artistID!, artist, normalized(artist), now, now]) }
            if let album = metadata.album { try db.execute(sql: "INSERT OR IGNORE INTO albums (id, title, normalizedTitle, artistID, dateAdded, dateModified) VALUES (?, ?, ?, ?, ?, ?)", arguments: [albumID!, album, normalized(album), artistID, now, now]) }
            try db.execute(sql: "UPDATE import_operations SET state = 'committed', dateUpdated = ? WHERE id = ?", arguments: [now, operationID])
        }
        try? FileManager.default.removeItem(at: stagingURL)
        reload()
        return ImportResult(track: track, duplicate: false)
    }

    func exportAudio(track: StoredTrack, to destination: URL) throws {
        let source = try paths.musicURL(relativePath: track.fileRelativePath)
        guard FileManager.default.fileExists(atPath: source.path) else { throw StorageError.missingFile }
        let target = destination.hasDirectoryPath ? destination.appendingPathComponent(safeFilename(track.title, fileExtension: track.fileExtension)) : destination
        try audio.copyStreaming(from: source, to: target)
        guard try audio.sha256(url: source) == audio.sha256(url: target) else { throw StorageError.exportFailed }
    }

    func reconcileMissingFiles() throws {
        for track in try tracks.all() { let url = try paths.musicURL(relativePath: track.fileRelativePath); if !FileManager.default.fileExists(atPath: url.path) { try tracks.updateAvailability(id: track.id, .missing) } }
        for file in (try? FileManager.default.contentsOfDirectory(at: paths.imports, includingPropertiesForKeys: nil)) ?? [] { try? FileManager.default.removeItem(at: file) }
    }

    private func stableID(prefix: String, value: String) -> String { "\(prefix)-" + normalized(value).data(using: .utf8)!.map { String(format: "%02x", $0) }.joined().prefix(32) }
    private func normalized(_ value: String) -> String { value.trimmingCharacters(in: .whitespacesAndNewlines).folding(options: .diacriticInsensitive, locale: .current).lowercased() }
    private func safeFilename(_ title: String, fileExtension: String) -> String { let clean = title.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: "\\", with: "-"); return "\(clean).\(fileExtension)" }
}

extension UTType {
    static var supportedAudio: UTType { UTType(filenameExtension: "m4a") ?? .audio }
}
