import Foundation
import GRDB

protocol TrackRepository {
    func all() throws -> [StoredTrack]
    func find(id: String) throws -> StoredTrack?
    func find(contentSHA256: String) throws -> StoredTrack?
    func save(_ track: StoredTrack) throws
    func updateAvailability(id: String, _ availability: StoredTrackAvailability) throws
    func delete(id: String) throws
}

protocol PlaylistRepository { func all() throws -> [StoredPlaylist]; func save(_ playlist: StoredPlaylist) throws; func setTracks(_ trackIDs: [String], playlistID: String) throws; func tracks(playlistID: String) throws -> [StoredTrack] }
protocol SettingsRepository { func string(for key: String, default defaultValue: String) throws -> String; func set(_ value: String, for key: String) throws }
protocol PlaybackRepository { func save(_ state: StoredPlaybackState) throws; func state() throws -> StoredPlaybackState?; func replaceQueue(_ entries: [StoredQueueEntry]) throws; func queue() throws -> [StoredQueueEntry]; func addHistory(_ entry: StoredHistoryEntry) throws; func history(limit: Int) throws -> [StoredHistoryEntry]; func completeHistory(id: String, completedAt: Date, durationMs: Int64) throws }
protocol DownloadJobRepository { func all() throws -> [StoredDownloadJob]; func save(_ job: StoredDownloadJob) throws; func markInterrupted() throws }

final class GRDBTrackRepository: TrackRepository {
    private let db: DatabaseQueue
    init(db: DatabaseQueue) { self.db = db }
    func all() throws -> [StoredTrack] { try db.read { try StoredTrack.order(Column("dateAdded").desc).fetchAll($0) } }
    func find(id: String) throws -> StoredTrack? { try db.read { try StoredTrack.fetchOne($0, key: id) } }
    func find(contentSHA256: String) throws -> StoredTrack? { try db.read { try StoredTrack.filter(Column("contentSHA256") == contentSHA256).fetchOne($0) } }
    func save(_ value: StoredTrack) throws {
        try db.write { db in
            var track = value
            track.normalizedTitle = LibraryIdentity.search(track.title)
            let artist = try track.artistID.flatMap { try StoredArtist.fetchOne(db, key: $0)?.name } ?? ""
            let album = try track.albumID.flatMap { try StoredAlbum.fetchOne(db, key: $0)?.title } ?? ""
            track.searchText = LibraryIdentity.search([track.title, artist, album, track.albumArtist ?? ""].joined(separator: " "))
            try track.save(db)
        }
    }
    func updateAvailability(id: String, _ availability: StoredTrackAvailability) throws { try db.write { database in try database.execute(sql: "UPDATE tracks SET availability = ?, dateModified = ? WHERE id = ?", arguments: [availability.rawValue, Date(), id]) } }
    func delete(id: String) throws { _ = try db.write { try StoredTrack.deleteOne($0, key: id) } }
}

final class GRDBPlaylistRepository: PlaylistRepository {
    private let db: DatabaseQueue
    init(db: DatabaseQueue) { self.db = db }
    func all() throws -> [StoredPlaylist] { try db.read { try StoredPlaylist.order(Column("dateAdded")).fetchAll($0) } }
    func save(_ playlist: StoredPlaylist) throws { try db.write { try playlist.save($0) } }
    func setTracks(_ trackIDs: [String], playlistID: String) throws { try db.write { try LibraryRepository.replaceMembership(trackIDs, playlistID: playlistID, db: $0) } }
    func tracks(playlistID: String) throws -> [StoredTrack] { try db.read { try StoredTrack.fetchAll($0, sql: "SELECT tracks.* FROM tracks JOIN playlist_tracks ON playlist_tracks.trackID = tracks.id WHERE playlist_tracks.playlistID = ? ORDER BY playlist_tracks.position", arguments: [playlistID]) } }
}

final class GRDBSettingsRepository: SettingsRepository {
    private let db: DatabaseQueue
    init(db: DatabaseQueue) { self.db = db }
    func string(for key: String, default defaultValue: String) throws -> String { try db.read { try StoredSetting.fetchOne($0, key: key)?.value ?? defaultValue } }
    func set(_ value: String, for key: String) throws { try db.write { try StoredSetting(key: key, value: value, valueType: "string", dateModified: Date()).save($0) } }
}

final class GRDBPlaybackRepository: PlaybackRepository {
    private let db: DatabaseQueue
    init(db: DatabaseQueue) { self.db = db }
    func save(_ state: StoredPlaybackState) throws { try db.write { try state.save($0) } }
    func saveSnapshot(_ state: StoredPlaybackState, queue: [StoredQueueEntry]) throws {
        try db.write { db in
            try state.save(db)
            try db.execute(sql: "DELETE FROM playback_queue_entries")
            for entry in queue { try entry.save(db) }
        }
    }
    func state() throws -> StoredPlaybackState? { try db.read { try StoredPlaybackState.fetchOne($0, key: "default") } }
    func replaceQueue(_ entries: [StoredQueueEntry]) throws { try db.write { db in try db.execute(sql: "DELETE FROM playback_queue_entries"); for entry in entries { try entry.save(db) } } }
    func queue() throws -> [StoredQueueEntry] { try db.read { try StoredQueueEntry.order(Column("position")).fetchAll($0) } }
    func addHistory(_ entry: StoredHistoryEntry) throws { try db.write { try entry.save($0) } }
    func history(limit: Int) throws -> [StoredHistoryEntry] { try db.read { try StoredHistoryEntry.order(Column("startedAt").desc).limit(limit).fetchAll($0) } }
    func completeHistory(id: String, completedAt: Date, durationMs: Int64) throws { try db.write { db in try db.execute(sql: "UPDATE playback_history SET completedAt = ?, durationListenedMs = ? WHERE id = ?", arguments: [completedAt, durationMs, id]) } }
}

final class GRDBDownloadJobRepository: DownloadJobRepository {
    private let db: DatabaseQueue
    init(db: DatabaseQueue) { self.db = db }
    func all() throws -> [StoredDownloadJob] { try db.read { try StoredDownloadJob.order(Column("dateAdded").desc).fetchAll($0) } }
    func save(_ job: StoredDownloadJob) throws { try db.write { try job.save($0) } }
    func swapPositions(_ first: StoredDownloadJob, _ second: StoredDownloadJob) throws {
        try db.write { db in
            try db.execute(sql: "UPDATE download_jobs SET position = ? WHERE id = ?", arguments: [second.position, first.id])
            try db.execute(sql: "UPDATE download_jobs SET position = ? WHERE id = ?", arguments: [first.position, second.id])
        }
    }
    func markInterrupted() throws { try db.write { database in try database.execute(sql: "UPDATE download_jobs SET state = 'interrupted', dateModified = ? WHERE position IS NULL AND state IN ('queued', 'interrupted')", arguments: [Date()]) } }
}
