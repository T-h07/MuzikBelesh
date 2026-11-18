import Foundation
import GRDB

extension MusicLibraryService {
    /// Sets (`artworkData`) or removes (`nil`) the user-chosen cover of a playlist or album.
    ///
    /// Only `artworkRelativePath` changes. The existing managed-file workflow is reused exactly:
    /// staged files and a journaled operation, one atomic database commit, then reference-aware
    /// cleanup (a cover still used by a song or another collection is never deleted) with
    /// startup recovery for anything left behind. Names, descriptions, album artists, songs,
    /// order, audio files and playback are untouched.
    func setCollectionCover(_ identity: CollectionArtworkIdentity, artworkData: Data?) async throws {
        guard let storage else { throw LibraryError.operationFailed }
        let table: String, kind: String
        switch identity.kind {
        case .playlist: table = "playlists"; kind = "playlist-artwork"
        case .album: table = "albums"; kind = "album-artwork"
        case .artist, .unassigned: throw CollectionArtworkPreferenceError.unsupportedCollection
        }
        let id = identity.id
        try await storage.mutations.withLock {
            try await Task.detached(priority: .userInitiated) {
                let db = storage.database.dbQueue
                // `table` is one of two fixed names; identifiers are always bound.
                guard let row = try db.read({ try Row.fetchOne($0, sql: "SELECT artworkRelativePath FROM \(table) WHERE id = ?", arguments: [id]) })
                else { throw LibraryError.notFound }
                let previous: String? = row["artworkRelativePath"]
                let operation: ManagedFileOperation
                if let artworkData {
                    operation = try ManagedLibraryFiles.stageArtwork(artworkData, ownerID: id, oldPath: previous, kind: kind, paths: storage.paths, db: db)
                } else if let previous {
                    operation = try ManagedLibraryFiles.removalArtworkOperation(ownerID: id, path: previous, db: db)
                } else { return }
                let newPath: String? = artworkData == nil ? nil : operation.stagedPath
                do {
                    try db.write { db in
                        try db.execute(sql: "UPDATE \(table) SET artworkRelativePath = ?, dateModified = ? WHERE id = ?", arguments: [newPath, Date(), id])
                        guard db.changesCount == 1 else { throw LibraryError.notFound }
                        try db.execute(sql: "UPDATE library_file_operations SET state = 'committed' WHERE id = ?", arguments: [operation.id])
                    }
                } catch {
                    try? ManagedLibraryFiles.finishArtwork(operation, paths: storage.paths, db: db)
                    throw error
                }
                // Saved. Cleanup stays journaled (and is retried at launch) if the filesystem is busy.
                try? ManagedLibraryFiles.finishArtwork(operation, paths: storage.paths, db: db)
            }.value
        }
    }
}
