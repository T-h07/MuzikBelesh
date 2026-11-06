import Foundation
import CryptoKit
import GRDB
import SwiftUI
import UniformTypeIdentifiers

struct ImportResult: Equatable, Sendable { let track: StoredTrack; let duplicate: Bool }

final class StorageCoordinator: ObservableObject {
    let paths: AppStoragePaths
    let database: DatabaseManager
    let tracks: GRDBTrackRepository
    let playlists: GRDBPlaylistRepository
    let settings: GRDBSettingsRepository
    let playback: GRDBPlaybackRepository
    let downloads: GRDBDownloadJobRepository
    let audio = AudioFileService()
    let mutations = LibraryMutationGate()
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
        try? PreparedAudioExport.cleanupAbandoned(in: paths.exports)
        do { try ManagedLibraryFiles.recover(paths: paths, db: database.dbQueue) }
        catch { lastError = "A pending file operation needs recovery. Existing recovery copies were retained." }
        try reconcileMissingFiles()
        reload()
    }

    func reload() { do { library = try tracks.all() } catch { lastError = "Local music could not be loaded." } }
    func artistName(for id: String?) -> String? { guard let id else { return nil }; return try? database.dbQueue.read { try String.fetchOne($0, sql: "SELECT name FROM artists WHERE id = ?", arguments: [id]) } }
    func albumTitle(for id: String?) -> String? { guard let id else { return nil }; return try? database.dbQueue.read { try String.fetchOne($0, sql: "SELECT title FROM albums WHERE id = ?", arguments: [id]) } }

    @discardableResult
    func importAudio(from source: URL, sourceType: String? = nil, sourceIdentifier: String? = nil, video: YouTubeVideo? = nil, artwork: Data? = nil) async throws -> ImportResult {
        try await mutations.withLock { try await self.performImport(from: source, sourceType: sourceType, sourceIdentifier: sourceIdentifier, video: video, artwork: artwork) }
    }

    private func beginImport(_ operation: StoredImportOperation) throws { try database.dbQueue.write { try operation.insert($0) } }
    private func finishImportJournal(_ id: String, state: String) {
        try? database.dbQueue.write { try $0.execute(sql: "UPDATE import_operations SET state = ?, dateUpdated = ? WHERE id = ?", arguments: [state, Date(), id]) }
    }
    private func performImport(from source: URL, sourceType: String?, sourceIdentifier: String?, video: YouTubeVideo?, artwork: Data?) async throws -> ImportResult {
        guard source.startAccessingSecurityScopedResource() || source.isFileURL else { throw StorageError.invalidPath }
        defer { source.stopAccessingSecurityScopedResource() }
        guard SupportedAudioFormat.isSupported(source) else { throw StorageError.unsupportedAudio }
        let id = UUID().uuidString
        let stagingName = "\(id).\(source.pathExtension.lowercased())"
        let staging = try paths.relativeURL(stagingName, in: paths.imports)
        let operation = StoredImportOperation(id: id, sourceFilename: source.lastPathComponent, stagingRelativePath: stagingName, state: "staging", errorMessage: nil, dateStarted: Date(), dateUpdated: Date())
        try beginImport(operation)
        do {
            try Task.checkCancellation()
            try audio.copyStreaming(from: source, to: staging)
            var metadata = try await audio.validate(staging)
            if let video {
                if let ms = metadata.durationMs, let timeline = try? await YouTubeAudioTimeline.inspect(staging, source: video.duration),
                   let corrected = timeline.correction(for: Double(ms) / 1000) {
                    metadata.durationMs = Int64((corrected * 1000).rounded())
                }
                metadata.title = video.title
                metadata.artist = metadata.artist ?? video.channel
                metadata.artworkData = metadata.artworkData ?? artwork
            }
            if metadata.title == id { metadata.title = source.deletingPathExtension().lastPathComponent }
            try Task.checkCancellation()
            let result = try commitImport(operation: operation, staging: staging, metadata: metadata, sourceType: sourceType, sourceIdentifier: sourceIdentifier)
            try? FileManager.default.removeItem(at: staging)
            await MainActor.run { self.reload() }
            return result
        } catch {
            try? FileManager.default.removeItem(at: staging)
            finishImportJournal(id, state: "rolled_back")
            if error is CancellationError { throw error }
            if (error as NSError).domain == NSCocoaErrorDomain && (error as NSError).code == NSFileWriteOutOfSpaceError {
                throw StorageError.insufficientStorage
            }
            throw error is StorageError || error is LibraryError ? error : StorageError.importIncomplete
        }
    }

    private func duplicate(hash: String, sourceType: String?, sourceIdentifier: String?, db: Database) throws -> StoredTrack? {
        if let sourceType, let sourceIdentifier, let existing = try LibraryRepository.sourceTrack(type: sourceType, identifier: sourceIdentifier, db: db) { return existing }
        return try StoredTrack.filter(Column("contentSHA256") == hash).fetchOne(db)
    }
    private func useDuplicate(_ existing: StoredTrack, hash: String, staging: URL, sourceType: String?, sourceIdentifier: String?, db: Database) throws -> StoredTrack {
        var existing = existing
        let pending = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM library_file_operations WHERE kind = 'delete-track' AND ownerID = ?", arguments: [existing.id]) ?? 0
        guard pending == 0 else { throw LibraryError.deletionInProgress }
        let url = try paths.musicURL(relativePath: existing.fileRelativePath)
        // Restore an exact missing file without changing identity or edited metadata.
        // A different encoding with the same source ID never overwrites stored bytes.
        if existing.contentSHA256 == hash, !FileManager.default.fileExists(atPath: url.path) {
            try audio.copyStreaming(from: staging, to: url)
            existing.availability = .available; existing.dateModified = Date(); try existing.update(db)
        }
        if FileManager.default.fileExists(atPath: url.path) {
            let valid = try audio.sha256(url: url) == existing.contentSHA256
            let availability: StoredTrackAvailability = valid ? .available : .modified
            if existing.availability != availability { existing.availability = availability; try existing.update(db) }
        } else if existing.availability != .missing { existing.availability = .missing; try existing.update(db) }
        try LibraryRepository.recordSource(trackID: existing.id, type: sourceType, identifier: sourceIdentifier, db: db)
        return existing
    }
    private func commitImport(operation: StoredImportOperation, staging: URL, metadata: AudioMetadata, sourceType: String?, sourceIdentifier: String?) throws -> ImportResult {
        let type = sourceType.map { LibraryIdentity.display($0).lowercased() }
        let identifier = sourceIdentifier?.trimmingCharacters(in: .whitespacesAndNewlines)
        if type != nil || identifier != nil {
            guard let type, let identifier else { throw LibraryError.operationFailed }
            guard !type.isEmpty, !identifier.isEmpty, type.count <= 100, identifier.count <= 500 else { throw LibraryError.operationFailed }
        }
        let hash = try audio.sha256(url: staging)
        if let existing = try database.dbQueue.read({ try duplicate(hash: hash, sourceType: type, sourceIdentifier: identifier, db: $0) }) {
            let reused = try database.dbQueue.write { db in try useDuplicate(existing, hash: hash, staging: staging, sourceType: type, sourceIdentifier: identifier, db: db) }
            finishImportJournal(operation.id, state: "duplicate")
            return ImportResult(track: reused, duplicate: true)
        }
        let ext = staging.pathExtension
        let destination = try paths.musicURL(relativePath: "\(operation.id).\(ext)")
        let artworkName = metadata.artworkData == nil ? nil : "\(operation.id).jpg"
        do {
            if let data = metadata.artworkData, let artworkName {
                // Invalid embedded artwork does not invalidate otherwise playable audio.
                if let processed = try? ManagedLibraryFiles.imageData(data, pixels: 1024) {
                    try processed.write(to: paths.artworkURL(relativePath: artworkName), options: .atomic)
                    let thumbnail = try ManagedLibraryFiles.imageData(data, pixels: 256)
                    try thumbnail.write(to: paths.artworkURL(relativePath: ManagedLibraryFiles.thumbnailName(artworkName)), options: .atomic)
                }
            }
            try audio.copyStreaming(from: staging, to: destination)
            try Task.checkCancellation()
            let result = try database.dbQueue.write { db -> ImportResult in
                // Recheck under the write lock: separate coordinators cannot create
                // duplicate rows or physical copies after concurrent preparation.
                if let existing = try duplicate(hash: hash, sourceType: type, sourceIdentifier: identifier, db: db) {
                    let reused = try useDuplicate(existing, hash: hash, staging: staging, sourceType: type, sourceIdentifier: identifier, db: db)
                    try db.execute(sql: "UPDATE import_operations SET state = 'duplicate', dateUpdated = ? WHERE id = ?", arguments: [Date(), operation.id])
                    return ImportResult(track: reused, duplicate: true)
                }
                let artistID = try LibraryRepository.resolveArtist(metadata.artist ?? "", db: db)
                let albumID = try LibraryRepository.resolveAlbum(metadata.album ?? "", artistID: artistID, db: db)
                let now = Date()
                let validArtwork = try artworkName.flatMap { name -> String? in FileManager.default.fileExists(atPath: try paths.artworkURL(relativePath: name).path) ? name : nil }
                var track = StoredTrack(id: operation.id, title: metadata.title, artistID: artistID, albumID: albumID, durationMs: metadata.durationMs, fileRelativePath: destination.lastPathComponent, fileExtension: ext, fileSizeBytes: (try FileManager.default.attributesOfItem(atPath: staging.path)[.size] as? NSNumber)?.int64Value ?? 0, contentSHA256: hash, artworkRelativePath: validArtwork, availability: .available, dateAdded: now, dateModified: now, originalFilename: operation.sourceFilename, metadataSource: type == "youtube" ? "youtube" : "local_import")
                if let albumID { track.albumPosition = (try Int.fetchOne(db, sql: "SELECT MAX(albumPosition) FROM tracks WHERE albumID = ?", arguments: [albumID]) ?? -1) + 1 }
                track.normalizedTitle = LibraryIdentity.search(track.title)
                track.searchText = LibraryIdentity.search([track.title, metadata.artist ?? "", metadata.album ?? ""].joined(separator: " "))
                try track.insert(db)
                try LibraryRepository.recordSource(trackID: track.id, type: type, identifier: identifier, db: db)
                try db.execute(sql: "UPDATE import_operations SET state = 'committed', dateUpdated = ? WHERE id = ?", arguments: [now, operation.id])
                return ImportResult(track: track, duplicate: false)
            }
            if result.duplicate {
                try? FileManager.default.removeItem(at: destination)
                if let artworkName { try? ManagedLibraryFiles.cleanupArtwork(artworkName, paths: paths, db: database.dbQueue) }
            }
            return result
        } catch {
            try? FileManager.default.removeItem(at: destination)
            if let artworkName { try? ManagedLibraryFiles.cleanupArtwork(artworkName, paths: paths, db: database.dbQueue) }
            throw error
        }
    }

    func prepareExport(trackID: String) async throws -> PreparedAudioExport {
        try await mutations.withLock {
            try await Task.detached(priority: .userInitiated) { [self] in
                guard let track = try tracks.find(id: trackID), track.availability == .available else { throw StorageError.missingFile }
                let source = try paths.musicURL(relativePath: track.fileRelativePath)
                let directory = paths.exports.appendingPathComponent("Export-" + UUID().uuidString, isDirectory: true)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                let filename = safeFilename(String(track.title.prefix(100)), fileExtension: track.fileExtension)
                let export = PreparedAudioExport(directory: directory, url: directory.appendingPathComponent(filename))
                try audio.copyStreaming(from: source, to: export.url)
                guard try audio.sha256(url: export.url) == track.contentSHA256 else { throw StorageError.exportFailed }
                return export
            }.value
        }
    }

    func exportData(trackID: String) async throws -> Data {
        try await Task.detached(priority: .userInitiated) { [self] in
            guard let track = try tracks.find(id: trackID), track.availability == .available else { throw StorageError.missingFile }
            let url = try paths.musicURL(relativePath: track.fileRelativePath)
            guard try audio.sha256(url: url) == track.contentSHA256 else { throw StorageError.exportFailed }
            return try Data(contentsOf: url, options: .mappedIfSafe)
        }.value
    }

    func exportAudio(track: StoredTrack, to destination: URL) throws {
        let source = try paths.musicURL(relativePath: track.fileRelativePath)
        guard FileManager.default.fileExists(atPath: source.path) else { throw StorageError.missingFile }
        let target = destination.hasDirectoryPath ? destination.appendingPathComponent(safeFilename(track.title, fileExtension: track.fileExtension)) : destination
        try audio.copyStreaming(from: source, to: target)
        guard try audio.sha256(url: source) == audio.sha256(url: target) else { throw StorageError.exportFailed }
    }

    func reconcileMissingFiles() throws {
        let interrupted = try database.dbQueue.read { try StoredImportOperation.filter(["staging", "duplicate", "rolled_back"].contains(Column("state"))).fetchAll($0) }
        for operation in interrupted where UUID(uuidString: operation.id) != nil {
            guard try tracks.find(id: operation.id) == nil else { continue }
            let ext = URL(fileURLWithPath: operation.stagingRelativePath).pathExtension
            guard SupportedAudioFormat.extensions.contains(ext) else { continue }
            let audio = try paths.musicURL(relativePath: "\(operation.id).\(ext)")
            let artwork = try paths.artworkURL(relativePath: "\(operation.id).jpg")
            let thumbnail = try paths.artworkURL(relativePath: ManagedLibraryFiles.thumbnailName("\(operation.id).jpg"))
            let referenced = try database.dbQueue.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM tracks WHERE fileRelativePath = ?", arguments: [audio.lastPathComponent]) ?? 0 }
            if referenced == 0, FileManager.default.fileExists(atPath: audio.path) { try FileManager.default.removeItem(at: audio) }
            _ = artwork; _ = thumbnail
            try ManagedLibraryFiles.cleanupArtwork("\(operation.id).jpg", paths: paths, db: database.dbQueue)
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
