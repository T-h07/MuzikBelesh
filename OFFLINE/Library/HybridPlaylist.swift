import Foundation
import GRDB

/// Independent local occurrence. Source positions and migration entries never
/// represent these records. Repeated track IDs intentionally remain distinct.
struct LocalPlaylistOccurrence: Codable, FetchableRecord, PersistableRecord, Identifiable, Equatable, Sendable {
    static let databaseTableName = "playlist_local_occurrences"
    var id: String
    var playlistID: String
    var trackID: String
    var position: Int
    var createdAt: Date
    var playbackID: String { "local:" + id }
}
struct LocalPlaylistRow: Identifiable, Equatable, Sendable {
    let occurrence: LocalPlaylistOccurrence
    let track: StoredTrack
    let available: Bool
    var id: String { occurrence.id }
    var playbackOccurrence: MigrationPlaybackOccurrence? {
        available ? MigrationPlaybackOccurrence(id: occurrence.playbackID, trackID: track.id) : nil
    }
}

extension LibraryRepository {
    static func appendManualOccurrences(_ ids: [String], playlistID: String, db: Database) throws {
        guard try MigrationSessionRecord.filter(Column("destinationPlaylistID") == playlistID).fetchOne(db) != nil else { throw LibraryError.notFound }
        var position = (try Int.fetchOne(db, sql: "SELECT MAX(position) FROM playlist_local_occurrences WHERE playlistID = ?", arguments: [playlistID]) ?? -1) + 1
        for id in ids {
            guard let track = try StoredTrack.fetchOne(db, key: id), track.availability == .available,
                  try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM library_file_operations WHERE kind = 'delete-track' AND ownerID = ?", arguments: [id]) == 0 else { throw LibraryError.notFound }
            try LocalPlaylistOccurrence(id: UUID().uuidString, playlistID: playlistID, trackID: id, position: position, createdAt: Date()).insert(db)
            position += 1
        }
        try db.execute(sql: "UPDATE playlists SET dateModified = ? WHERE id = ?", arguments: [Date(), playlistID])
    }
    func removeManualOccurrence(_ id: String, playlistID: String) throws {
        try db.write { db in
            guard let occurrence = try LocalPlaylistOccurrence.fetchOne(db, key: id), occurrence.playlistID == playlistID else { throw LibraryError.notFound }
            try occurrence.delete(db)
            try db.execute(sql: "UPDATE playlists SET dateModified = ? WHERE id = ?", arguments: [Date(), playlistID])
        }
    }
    static func manualRows(_ db: Database, playlistID: String, paths: AppStoragePaths) throws -> [LocalPlaylistRow] {
        try LocalPlaylistOccurrence.filter(Column("playlistID") == playlistID).order(Column("position"), Column("id")).fetchAll(db).compactMap { occurrence in
            guard let track = try StoredTrack.fetchOne(db, key: occurrence.trackID) else { return nil }
            return LocalPlaylistRow(occurrence: occurrence, track: track, available: MigrationLocalAudio.isAvailable(track, paths: paths))
        }
    }
}

extension GRDBPlaylistMigrationRepository {
    func hybridPlaybackOccurrences(playlistID: String) throws -> [MigrationPlaybackOccurrence] {
        try db.read { db in
            try Self.rows(db, playlistID: playlistID, paths: paths).playbackOccurrences
                + LibraryRepository.manualRows(db, playlistID: playlistID, paths: paths).compactMap(\.playbackOccurrence)
        }
    }
}
