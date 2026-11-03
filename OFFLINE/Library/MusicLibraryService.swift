import Foundation
import GRDB
import SwiftUI

@MainActor final class MusicLibraryService: ObservableObject {
    @Published private(set) var snapshot = LibrarySnapshot()
    @Published private(set) var artistGroups: [LibraryGroup] = []
    @Published private(set) var albumGroups: [LibraryGroup] = []
    @Published private(set) var revision = 0
    @Published var error: String?
    private(set) var tracksByID: [String: StoredTrack] = [:]
    private var artistNames: [String: String] = [:]
    private var albumNames: [String: String] = [:]
    let storage: StorageCoordinator?
    private weak var player: AudioPlayerService?
    private var observation: (any DatabaseCancellable)?
    var repository: LibraryRepository? { storage.map { LibraryRepository(db: $0.database.dbQueue) } }

    init(storage: StorageCoordinator?, player: AudioPlayerService?) {
        self.storage = storage; self.player = player
        guard let storage else { error = "Local library storage is unavailable."; return }
        error = storage.lastError
        observation = ValueObservation.tracking(LibraryRepository.snapshot).start(in: storage.database.dbQueue, scheduling: .immediate, onError: { [weak self] _ in
            self?.error = "Library updates could not be read. Try refreshing."
        }, onChange: { [weak self] value in self?.apply(value) })
    }
    private func apply(_ value: LibrarySnapshot) {
        guard value != snapshot else { return }
        tracksByID = value.trackByID
        artistNames = Dictionary(uniqueKeysWithValues: value.artists.map { ($0.id, $0.name) })
        albumNames = Dictionary(uniqueKeysWithValues: value.albums.map { ($0.id, $0.title) })
        artistGroups = value.artistGroups; albumGroups = value.albumGroups
        snapshot = value; revision += 1
        player?.libraryDidChange()
    }
    func track(_ id: String?) -> StoredTrack? { id.flatMap { tracksByID[$0] } }
    func artistName(_ id: String?) -> String { id.flatMap { artistNames[$0] } ?? "Unknown Artist" }
    func albumTitle(_ id: String?) -> String { id.flatMap { albumNames[$0] } ?? "Unknown Album" }
    func tracks(_ ids: [String]) -> [StoredTrack] { ids.compactMap { tracksByID[$0] } }
    func playlistTracks(_ id: String) -> [StoredTrack] { snapshot.playlistTracks(id) }
    func report(_ error: Error) { self.error = Self.message(error) }
    static func message(_ error: Error) -> String { (error as? LibraryError)?.localizedDescription ?? (error as? StorageError)?.localizedDescription ?? LibraryError.operationFailed.localizedDescription }
    func perform(_ operation: () throws -> Void) { do { try operation(); error = nil } catch { report(error) } }
    private func requiredRepository() throws -> LibraryRepository { guard let repository else { throw LibraryError.operationFailed }; return repository }
    func setSort(_ sort: LibrarySort) throws { try requiredRepository().setSort(sort) }
    func setLiked(_ liked: Bool, trackID: String) throws { try requiredRepository().setLiked(liked, trackID: trackID) }
    func createPlaylist(name: String, description: String) throws -> StoredPlaylist { try requiredRepository().createPlaylist(name: name, description: description) }
    func updatePlaylist(id: String, name: String, description: String) throws { try requiredRepository().updatePlaylist(id: id, name: name, description: description) }
    func addTracks(_ ids: [String], playlistID: String) throws { try requiredRepository().addTracks(ids, playlistID: playlistID) }
    func removeTrack(_ id: String, playlistID: String) throws { try requiredRepository().removeTrack(id, playlistID: playlistID) }
    func reorder(_ ids: [String], playlistID: String) throws { try requiredRepository().reorder(ids, playlistID: playlistID) }
    func search(_ query: String) async throws -> [StoredTrack] {
        let repository = try requiredRepository(); let sort = snapshot.sort
        return try await Task.detached(priority: .userInitiated) { try repository.search(query, sort: sort) }.value
    }
    func play(_ trackID: String, ids: [String], kind: String, sourceID: String? = nil, shuffle: Bool? = nil) async {
        guard let player else { return }
        if let shuffle, player.queue.shuffleEnabled != shuffle { player.queue.toggleShuffle() }
        do { try await player.play(trackID: trackID, contextTrackIDs: ids, contextKind: kind, contextSourceID: sourceID) }
        catch { report(error) }
    }
    func saveMetadata(trackID: String, draft: TrackMetadataDraft, artworkData: Data?, removeArtwork: Bool = false) async throws {
        guard let storage else { throw LibraryError.operationFailed }
        try await storage.mutations.withLock {
            try await Task.detached(priority: .userInitiated) {
                let repository = LibraryRepository(db: storage.database.dbQueue)
                guard let track = try storage.tracks.find(id: trackID) else { throw LibraryError.notFound }
                var operation: ManagedFileOperation?
                do {
                    if let artworkData { operation = try ManagedLibraryFiles.stageArtwork(artworkData, ownerID: trackID, oldPath: track.artworkRelativePath, kind: "track-artwork", paths: storage.paths, db: storage.database.dbQueue) }
                    try repository.editMetadata(trackID: trackID, draft: draft, artworkPath: operation?.stagedPath, replaceArtwork: operation != nil || removeArtwork, artworkOperation: operation?.id)
                } catch {
                    if let operation { try? ManagedLibraryFiles.finishArtwork(operation, paths: storage.paths, db: storage.database.dbQueue) }
                    throw error
                }
                // Saving succeeded. Cleanup remains journaled if the filesystem is busy.
                if let operation { try? ManagedLibraryFiles.finishArtwork(operation, paths: storage.paths, db: storage.database.dbQueue) }
                else if removeArtwork { try? ManagedLibraryFiles.cleanupArtwork(track.artworkRelativePath, paths: storage.paths, db: storage.database.dbQueue) }
            }.value
        }
    }
    func savePlaylist(id: String?, name: String, description: String, artworkData: Data?) async throws -> String {
        guard let storage else { throw LibraryError.operationFailed }
        let name = try LibraryIdentity.validatedName(name)
        let playlistID = id ?? UUID().uuidString
        try await storage.mutations.withLock {
            try await Task.detached {
                let db = storage.database.dbQueue
                let previous = try db.read { try StoredPlaylist.fetchOne($0, key: playlistID) }
                if id != nil && previous == nil { throw LibraryError.notFound }
                var operation: ManagedFileOperation?
                do {
                    if let artworkData { operation = try ManagedLibraryFiles.stageArtwork(artworkData, ownerID: playlistID, oldPath: previous?.artworkRelativePath, kind: "playlist-artwork", paths: storage.paths, db: db) }
                    try db.write { db in
                        var playlist: StoredPlaylist
                        if id != nil {
                            guard let current = try StoredPlaylist.fetchOne(db, key: playlistID) else { throw LibraryError.notFound }
                            playlist = current
                        } else { playlist = StoredPlaylist(id: playlistID, name: name, description: nil, artworkRelativePath: nil, dateAdded: Date(), dateModified: Date()) }
                        playlist.name = name; playlist.description = String(description.prefix(2000)); playlist.dateModified = Date()
                        if let operation { playlist.artworkRelativePath = operation.stagedPath }
                        try playlist.save(db)
                        if let operation { try db.execute(sql: "UPDATE library_file_operations SET state = 'committed' WHERE id = ?", arguments: [operation.id]) }
                    }
                } catch { if let operation { try? ManagedLibraryFiles.finishArtwork(operation, paths: storage.paths, db: db) }; throw error }
                if let operation { try? ManagedLibraryFiles.finishArtwork(operation, paths: storage.paths, db: db) }
            }.value
        }
        return playlistID
    }
    func deletePlaylist(id: String, confirmed: Bool) async throws {
        guard let storage else { throw LibraryError.operationFailed }
        try await storage.mutations.withLock {
            try await Task.detached {
                let old = try LibraryRepository(db: storage.database.dbQueue).deletePlaylist(id: id, confirmed: confirmed)
                try? ManagedLibraryFiles.cleanupArtwork(old, paths: storage.paths, db: storage.database.dbQueue)
            }.value
        }
    }
    func deleteTrack(id: String, confirmed: Bool) async throws -> LibraryDeletionResult {
        guard confirmed else { throw LibraryError.confirmationRequired }
        guard let storage else { throw LibraryError.operationFailed }
        guard try storage.tracks.find(id: id) != nil else { throw LibraryError.notFound }
        try await player?.beginLibraryDeletion(id)
        do {
            let result = try await storage.mutations.withLock {
                try await Task.detached { try ManagedLibraryFiles.deleteTrack(id, confirmed: true, paths: storage.paths, db: storage.database.dbQueue) }.value
            }
            player?.finishLibraryDeletion(id)
            if result.cleanupPending { error = "Song removed. File cleanup will finish during recovery." }
            return result
        } catch { player?.finishLibraryDeletion(id); throw error }
    }
    func reconcileFiles() async {
        guard let storage else { return }
        do {
            try await storage.mutations.withLock {
                try await Task.detached { try ManagedLibraryFiles.recover(paths: storage.paths, db: storage.database.dbQueue); try storage.reconcileMissingFiles() }.value
            }
            error = nil; player?.libraryDidChange()
        } catch { report(error) }
    }
}
