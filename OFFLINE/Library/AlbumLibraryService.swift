import Foundation
import GRDB

extension MusicLibraryService {
    func saveAlbum(id: String? = nil, draft: AlbumDraft, trackIDs: [String]? = nil, artworkData: Data? = nil, removeArtwork: Bool = false) async throws -> String {
        guard let storage else { throw LibraryError.operationFailed }
        return try await storage.mutations.withLock {
            try await Task.detached(priority: .userInitiated) {
                let db = storage.database.dbQueue
                let previous = try id.flatMap { id in try db.read { try StoredAlbum.fetchOne($0, key: id) } }
                if id != nil && previous == nil { throw LibraryError.notFound }
                let ownerID = id ?? UUID().uuidString
                var operation: ManagedFileOperation?
                do {
                    if let artworkData {
                        operation = try ManagedLibraryFiles.stageArtwork(artworkData, ownerID: ownerID, oldPath: previous?.artworkRelativePath, kind: "album-artwork", paths: storage.paths, db: db)
                    } else if removeArtwork, let path = previous?.artworkRelativePath {
                        operation = try ManagedLibraryFiles.removalArtworkOperation(ownerID: ownerID, path: path, db: db)
                    }
                    let album = try LibraryRepository(db: db).saveAlbum(id: id, draft: draft, trackIDs: trackIDs,
                        artworkPath: artworkData == nil ? nil : operation?.stagedPath,
                        replaceArtwork: operation != nil || removeArtwork, artworkOperation: operation?.id, createdID: ownerID)
                    if let operation { try? ManagedLibraryFiles.finishArtwork(operation, paths: storage.paths, db: db) }
                    return album.id
                } catch {
                    if let operation { try? ManagedLibraryFiles.finishArtwork(operation, paths: storage.paths, db: db) }
                    throw error
                }
            }.value
        }
    }
    func addAlbumTracks(_ ids: [String], albumID: String) throws {
        guard let repository else { throw LibraryError.operationFailed }
        try repository.addAlbumTracks(ids, albumID: albumID)
    }
    func removeAlbumTrack(_ id: String, albumID: String) throws {
        guard let repository else { throw LibraryError.operationFailed }
        try repository.removeAlbumTrack(id, albumID: albumID)
    }
    func reorderAlbum(_ ids: [String], albumID: String) throws {
        guard let repository else { throw LibraryError.operationFailed }
        try repository.reorderAlbum(ids, albumID: albumID)
    }
    func deleteAlbum(id: String, confirmed: Bool) async throws {
        guard confirmed else { throw LibraryError.confirmationRequired }
        guard let storage else { throw LibraryError.operationFailed }
        try await storage.mutations.withLock {
            try await Task.detached(priority: .userInitiated) {
                let db = storage.database.dbQueue
                guard let album = try db.read({ try StoredAlbum.fetchOne($0, key: id) }) else { throw LibraryError.notFound }
                let operation = try album.artworkRelativePath.map { try ManagedLibraryFiles.removalArtworkOperation(ownerID: id, path: $0, db: db) }
                do { _ = try LibraryRepository(db: db).deleteAlbum(id: id, confirmed: true) }
                catch { if let operation { try? ManagedLibraryFiles.finishArtwork(operation, paths: storage.paths, db: db) }; throw error }
                if let operation { try? ManagedLibraryFiles.finishArtwork(operation, paths: storage.paths, db: db) }
            }.value
        }
    }
}
