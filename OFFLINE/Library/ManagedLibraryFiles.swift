import Foundation
import GRDB
import ImageIO
import UniformTypeIdentifiers

enum LibraryFileFault: Equatable, Sendable { case afterStage, beforeCommit, afterCommit }
struct LibraryDeletionResult: Sendable { let cleanupPending: Bool }

enum ManagedLibraryFiles {
    static func thumbnailName(_ path: String) -> String { (path as NSString).deletingPathExtension + ".thumb.jpg" }
    static func imageData(_ data: Data, pixels: Int) throws -> Data {
        guard !data.isEmpty, data.count <= 20 * 1024 * 1024,
              let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              let type = CGImageSourceGetType(source) as String?,
              UTType(type)?.conforms(to: .image) == true,
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceThumbnailMaxPixelSize: pixels, kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
        else { throw LibraryError.invalidImage }
        let result = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(result, UTType.jpeg.identifier as CFString, 1, nil) else { throw LibraryError.invalidImage }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw LibraryError.invalidImage }
        return result as Data
    }
    static func artworkReferences(_ path: String, db: Database) throws -> Int {
        var count = 0
        for table in ["tracks", "albums", "artists", "playlists"] {
            count += try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM \(table) WHERE artworkRelativePath = ?", arguments: [path]) ?? 0
        }
        return count
    }
    static func ownedArtwork(_ path: String) -> Bool {
        guard (path as NSString).lastPathComponent == path else { return false }
        let name = (path as NSString).deletingPathExtension.replacingOccurrences(of: "artwork-", with: "")
        return UUID(uuidString: name) != nil
    }
    static func cleanupArtwork(_ path: String?, paths: AppStoragePaths, db: DatabaseQueue) throws {
        guard let path, ownedArtwork(path) else { return }
        try db.write { database in
            // A thumbnail belongs to its full-size cover even when no row points
            // directly at the thumbnail. Keep both while that cover is shared.
            guard try artworkReferences(path, db: database) == 0 else { return }
            for candidate in [path, thumbnailName(path)] where try artworkReferences(candidate, db: database) == 0 {
                let url = try paths.artworkURL(relativePath: candidate)
                if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
            }
        }
    }
    static func stageArtwork(_ data: Data, ownerID: String, oldPath: String?, kind: String, paths: AppStoragePaths, db: DatabaseQueue) throws -> ManagedFileOperation {
        let full = try imageData(data, pixels: 1024)
        let thumb = try imageData(data, pixels: 256)
        let operation = ManagedFileOperation(id: UUID().uuidString, kind: kind, ownerID: ownerID, originalPath: oldPath, stagedPath: "artwork-\(UUID().uuidString).jpg", state: "prepared", dateUpdated: Date())
        try db.write { try operation.insert($0) }
        do {
            try full.write(to: paths.artworkURL(relativePath: operation.stagedPath), options: .atomic)
            try thumb.write(to: paths.artworkURL(relativePath: thumbnailName(operation.stagedPath)), options: .atomic)
            return operation
        } catch {
            // Keep the recovery record if cleanup itself fails.
            do {
                try cleanupArtwork(operation.stagedPath, paths: paths, db: db)
                _ = try db.write { try ManagedFileOperation.deleteOne($0, key: operation.id) }
            } catch { }
            throw LibraryError.operationFailed
        }
    }
    static func finishArtwork(_ operation: ManagedFileOperation, paths: AppStoragePaths, db: DatabaseQueue) throws {
        let referenced = try db.read { try artworkReferences(operation.stagedPath, db: $0) > 0 }
        try cleanupArtwork(referenced ? operation.originalPath : operation.stagedPath, paths: paths, db: db)
        _ = try db.write { try ManagedFileOperation.deleteOne($0, key: operation.id) }
    }
    static func removalArtworkOperation(ownerID: String, path: String, db: DatabaseQueue) throws -> ManagedFileOperation {
        let operation = ManagedFileOperation(id: UUID().uuidString, kind: "remove-artwork", ownerID: ownerID, originalPath: nil, stagedPath: path, state: "prepared", dateUpdated: Date())
        try db.write { try operation.insert($0) }
        return operation
    }

    static func removeFromPlayback(_ id: String, db: Database) throws {
        if var saved = try StoredPlaybackState.fetchOne(db, key: "default") {
            func ids(_ value: String?) -> [String] { value.flatMap { $0.data(using: .utf8) }.flatMap { try? JSONDecoder().decode([String].self, from: $0) } ?? [] }
            func json(_ values: [String]) -> String? { (try? JSONEncoder().encode(values)).flatMap { String(data: $0, encoding: .utf8) } }
            saved.contextTrackIDsJSON = json(ids(saved.contextTrackIDsJSON).filter { $0 != id })
            let shuffle = ids(saved.shuffleOrderJSON); let position = min(shuffle.count, max(0, saved.shufflePosition ?? 0))
            let consumed = shuffle.prefix(position).filter { $0 != id }
            saved.shuffleOrderJSON = json(consumed + shuffle.dropFirst(position).filter { $0 != id })
            saved.shufflePosition = consumed.count
            let history = ids(saved.navigationHistoryJSON)
            let before = history.prefix(max(0, min(history.count, (saved.navigationHistoryPosition ?? -1) + 1))).filter { $0 != id }
            let after = history.dropFirst(max(0, min(history.count, (saved.navigationHistoryPosition ?? -1) + 1))).filter { $0 != id }
            saved.navigationHistoryJSON = json(before + after); saved.navigationHistoryPosition = before.count - 1
            if saved.currentTrackID == id { saved.currentTrackID = nil; saved.positionMs = 0 }
            saved.dateModified = Date(); try saved.save(db)
        }
    }
    static func normalizePositions(_ db: Database) throws {
        for playlist in try StoredPlaylist.fetchAll(db) {
            let ids = try String.fetchAll(db, sql: "SELECT trackID FROM playlist_tracks WHERE playlistID = ? ORDER BY position, trackID", arguments: [playlist.id])
            for (position, id) in ids.enumerated() {
                try db.execute(sql: "UPDATE playlist_tracks SET position = ? WHERE playlistID = ? AND trackID = ?", arguments: [position, playlist.id, id])
            }
        }
        let entries = try StoredQueueEntry.order(Column("position"), Column("id")).fetchAll(db)
        for (position, entry) in entries.enumerated() { try db.execute(sql: "UPDATE playback_queue_entries SET position = ? WHERE id = ?", arguments: [position, entry.id]) }
    }
    static func deleteTrack(_ id: String, confirmed: Bool, paths: AppStoragePaths, db: DatabaseQueue, fault: ((LibraryFileFault) throws -> Void)? = nil) throws -> LibraryDeletionResult {
        guard confirmed else { throw LibraryError.confirmationRequired }
        let track = try db.read { try StoredTrack.fetchOne($0, key: id) }
        guard let track else { throw LibraryError.notFound }
        guard try db.read({ try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM library_file_operations WHERE ownerID = ? AND kind = 'delete-track'", arguments: [id]) ?? 0 }) == 0 else { throw LibraryError.deletionInProgress }
        let original = try paths.musicURL(relativePath: track.fileRelativePath)
        let operation = ManagedFileOperation(id: UUID().uuidString, kind: "delete-track", ownerID: id, originalPath: track.fileRelativePath, stagedPath: "\(UUID().uuidString).\(track.fileExtension)", state: "prepared", dateUpdated: Date(), artworkPath: track.artworkRelativePath)
        let staged = try paths.relativeURL(operation.stagedPath, in: paths.deletions)
        try db.write { try operation.insert($0) }
        var committed = false
        do {
            let shared = try db.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM tracks WHERE fileRelativePath = ? AND id != ?", arguments: [track.fileRelativePath, id]) ?? 0 }
            if shared == 0, FileManager.default.fileExists(atPath: original.path) { try FileManager.default.moveItem(at: original, to: staged) }
            try fault?(.afterStage)
            try db.write { database in
                // Re-read identity under the write lock before changing any relationships.
                guard let current = try StoredTrack.fetchOne(database, key: id), current.fileRelativePath == track.fileRelativePath else { throw LibraryError.notFound }
                if FileManager.default.fileExists(atPath: staged.path) {
                    guard try Int.fetchOne(database, sql: "SELECT COUNT(*) FROM tracks WHERE fileRelativePath = ? AND id != ?", arguments: [track.fileRelativePath, id]) == 0 else { throw LibraryError.operationFailed }
                }
                try removeFromPlayback(id, db: database)
                _ = try StoredTrack.deleteOne(database, key: id)
                try normalizePositions(database)
                try database.execute(sql: "UPDATE library_file_operations SET state = 'committed' WHERE id = ?", arguments: [operation.id])
                try fault?(.beforeCommit)
            }
            committed = true
            try fault?(.afterCommit)
            if FileManager.default.fileExists(atPath: staged.path) { try FileManager.default.removeItem(at: staged) }
            try cleanupArtwork(track.artworkRelativePath, paths: paths, db: db)
            _ = try db.write { try ManagedFileOperation.deleteOne($0, key: operation.id) }
            return LibraryDeletionResult(cleanupPending: false)
        } catch {
            if committed { return LibraryDeletionResult(cleanupPending: true) }
            if FileManager.default.fileExists(atPath: staged.path) {
                if !FileManager.default.fileExists(atPath: original.path) { try? FileManager.default.moveItem(at: staged, to: original) }
                // Never discard the recovery copy if restoration fails.
                if FileManager.default.fileExists(atPath: staged.path) { throw LibraryError.operationFailed }
            }
            _ = try? db.write { try ManagedFileOperation.deleteOne($0, key: operation.id) }
            throw error
        }
    }
    /// Runs before missing-file reconciliation so a prepared deletion is restored first.
    static func recover(paths: AppStoragePaths, db: DatabaseQueue) throws {
        for operation in try db.read({ try ManagedFileOperation.fetchAll($0) }) {
            if operation.kind != "delete-track" { try finishArtwork(operation, paths: paths, db: db); continue }
            guard UUID(uuidString: (operation.stagedPath as NSString).deletingPathExtension) != nil,
                  let relative = operation.originalPath else { throw LibraryError.operationFailed }
            let original = try paths.musicURL(relativePath: relative)
            let staged = try paths.relativeURL(operation.stagedPath, in: paths.deletions)
            let track = try db.read { try StoredTrack.fetchOne($0, key: operation.ownerID) }
            if let track {
                guard track.fileRelativePath == relative else { throw LibraryError.operationFailed }
                if FileManager.default.fileExists(atPath: staged.path) {
                    if FileManager.default.fileExists(atPath: original.path) {
                        guard try AudioFileService().sha256(url: original) == AudioFileService().sha256(url: staged) else { throw LibraryError.operationFailed }
                        try FileManager.default.removeItem(at: staged)
                    } else { try FileManager.default.moveItem(at: staged, to: original) }
                }
            } else if FileManager.default.fileExists(atPath: staged.path) { try FileManager.default.removeItem(at: staged) }
            if track == nil { try cleanupArtwork(operation.artworkPath, paths: paths, db: db) }
            _ = try db.write { try ManagedFileOperation.deleteOne($0, key: operation.id) }
        }
    }
}
