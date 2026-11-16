import Foundation
import GRDB

/// Songs added to a playlist by YouTube link ("Add Songs → From YouTube Links").
///
/// A link becomes a playlist entry immediately, before any audio exists: one durable row
/// per submitted link records the playlist, the video, the submitted order and its slot.
/// Audio is acquired through the single shared `DownloadManager` job for that video (an
/// existing or completed job is reused, never duplicated). When the verified track
/// exists, the row turns into an ordinary playlist occurrence — a membership in an
/// ordinary playlist, or a manual occurrence in an imported playlist — at the reserved
/// slot, in one transaction. Failures keep the entry with Retry and Remove.
/// Additive only (`v022_playlist_link_downloads`); no existing table changes meaning.
enum PlaylistLinkDownloadSchema {
    static let version = "v022_playlist_link_downloads"

    static func register(in migrator: inout DatabaseMigrator) {
        migrator.registerMigration(version) { db in
            try db.execute(sql: """
                CREATE TABLE playlist_link_downloads (
                    id TEXT PRIMARY KEY NOT NULL,
                    playlistID TEXT NOT NULL REFERENCES playlists(id) ON DELETE CASCADE,
                    videoID TEXT NOT NULL CHECK(length(videoID) = 11),
                    batchID TEXT NOT NULL,
                    sequence INTEGER NOT NULL CHECK(sequence >= 0),
                    slot INTEGER NOT NULL CHECK(slot >= 0),
                    downloadJobID TEXT REFERENCES download_jobs(id) ON DELETE SET NULL,
                    createdJob BOOLEAN NOT NULL DEFAULT 0,
                    state TEXT NOT NULL CHECK(state IN ('waiting','failed','added')),
                    failure TEXT,
                    retries INTEGER NOT NULL DEFAULT 0 CHECK(retries >= 0),
                    trackID TEXT REFERENCES tracks(id) ON DELETE SET NULL,
                    createdAt DATETIME NOT NULL,
                    updatedAt DATETIME NOT NULL
                );
                CREATE INDEX playlist_link_downloads_playlist ON playlist_link_downloads(playlistID, state, createdAt, sequence);
                CREATE INDEX playlist_link_downloads_job ON playlist_link_downloads(downloadJobID);
                """)
        }
    }
}

enum PlaylistLinkDownloadState: String, Codable, DatabaseValueConvertible, Sendable {
    /// Queued, downloading or verifying in the shared job.
    case waiting
    /// Could not be acquired; the entry stays with Retry and Remove.
    case failed
    /// Converted into an ordinary playlist occurrence (kept as history).
    case added
}

struct PlaylistLinkDownloadRecord: Codable, FetchableRecord, PersistableRecord, Identifiable, Equatable, Sendable {
    static let databaseTableName = "playlist_link_downloads"
    var id: String
    var playlistID: String
    var videoID: String
    var batchID: String
    /// Order within the submitted batch.
    var sequence: Int
    /// Ordinary playlists: membership index at submission. Imported playlists: the reserved
    /// manual-occurrence position.
    var slot: Int
    var downloadJobID: String?
    var createdJob: Bool
    var state: PlaylistLinkDownloadState
    var failure: String?
    var retries: Int
    var trackID: String?
    var createdAt: Date
    var updatedAt: Date
}

/// Result of submitting links.
struct PlaylistLinkSubmissionResult: Equatable, Sendable {
    var accepted: [PlaylistLinkDownloadRecord] = []
    /// Videos refused because an ordinary playlist already contains them (set semantics).
    var alreadyInPlaylist: [String] = []
}

extension LibraryRepository {
    static func isImportedPlaylist(_ db: Database, playlistID: String) throws -> Bool {
        try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM playlist_migrations WHERE destinationPlaylistID = ?", arguments: [playlistID]) ?? 0 > 0
    }

    /// Next free manual-occurrence position in an imported playlist, counting positions
    /// reserved by pending link entries so a later addition never takes their slot.
    static func nextManualPosition(_ db: Database, playlistID: String) throws -> Int {
        let local = try Int.fetchOne(db, sql: "SELECT MAX(position) FROM playlist_local_occurrences WHERE playlistID = ?", arguments: [playlistID]) ?? -1
        let reserved = try Int.fetchOne(db, sql: "SELECT MAX(slot) FROM playlist_link_downloads WHERE playlistID = ? AND state != 'added'",
                                        arguments: [playlistID]) ?? -1
        return max(local, reserved) + 1
    }

    /// YouTube videos whose audio already plays in this playlist (for duplicate warnings).
    func youtubeVideoIDs(inPlaylist playlistID: String) throws -> Set<String> {
        try db.read { db in
            let tracks = try String.fetchAll(db, sql: """
                SELECT trackID FROM playlist_tracks WHERE playlistID = ?
                UNION SELECT trackID FROM playlist_local_occurrences WHERE playlistID = ?
                UNION SELECT e.localTrackID FROM migration_entries e JOIN playlist_migrations m ON m.id = e.migrationID
                    WHERE m.destinationPlaylistID = ? AND e.localTrackID IS NOT NULL AND e.removedAt IS NULL
                """, arguments: [playlistID, playlistID, playlistID])
            var ids = Set(try String.fetchAll(db, sql: "SELECT videoID FROM playlist_link_downloads WHERE playlistID = ? AND state != 'added'",
                                               arguments: [playlistID]))
            for chunk in stride(from: 0, to: tracks.count, by: 500) {
                let part = Array(tracks[chunk..<min(tracks.count, chunk + 500)])
                let marks = Array(repeating: "?", count: part.count).joined(separator: ",")
                ids.formUnion(try String.fetchAll(db, sql: """
                    SELECT sourceIdentifier FROM track_sources WHERE sourceType = 'youtube' AND sourceIdentifier IS NOT NULL AND trackID IN (\(marks))
                    """, arguments: StatementArguments(part)))
            }
            return ids
        }
    }

    /// Accepts validated video IDs as playlist entries in submitted order, in one
    /// transaction. Imported (hybrid) playlists accept repeated videos as separate
    /// occurrences; ordinary playlists keep one membership per song, so a video already
    /// present (or repeated in the batch) is reported instead of silently dropped.
    func submitLinks(_ videoIDs: [String], playlistID: String, now: Date = Date()) throws -> PlaylistLinkSubmissionResult {
        try db.write { db in
            guard try StoredPlaylist.fetchOne(db, key: playlistID) != nil else { throw LibraryError.notFound }
            let imported = try Self.isImportedPlaylist(db, playlistID: playlistID)
            var result = PlaylistLinkSubmissionResult()
            var present = Set<String>()
            if !imported {
                present = Set(try String.fetchAll(db, sql: """
                    SELECT s.sourceIdentifier FROM playlist_tracks p JOIN track_sources s ON s.trackID = p.trackID
                    WHERE p.playlistID = ? AND s.sourceType = 'youtube' AND s.sourceIdentifier IS NOT NULL
                    UNION SELECT videoID FROM playlist_link_downloads WHERE playlistID = ? AND state != 'added'
                    """, arguments: [playlistID, playlistID]))
            }
            let batch = UUID().uuidString
            let base: Int
            if imported { base = try Self.nextManualPosition(db, playlistID: playlistID) }
            else { base = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM playlist_tracks WHERE playlistID = ?", arguments: [playlistID]) ?? 0 }
            var sequence = 0
            for videoID in videoIDs {
                guard YouTubeURLValidator.isValidID(videoID) else { throw LibraryError.invalidMetadata }
                if !imported {
                    guard present.insert(videoID).inserted else { result.alreadyInPlaylist.append(videoID); continue }
                }
                let record = PlaylistLinkDownloadRecord(id: UUID().uuidString, playlistID: playlistID, videoID: videoID, batchID: batch,
                    sequence: sequence, slot: base + (imported ? sequence : 0), downloadJobID: nil, createdJob: false, state: .waiting,
                    failure: nil, retries: 0, trackID: nil, createdAt: now, updatedAt: now)
                try record.insert(db)
                result.accepted.append(record)
                sequence += 1
            }
            if !result.accepted.isEmpty {
                try db.execute(sql: "UPDATE playlists SET dateModified = ? WHERE id = ?", arguments: [now, playlistID])
            }
            return result
        }
    }

    /// Entries still waiting or failed, in submission order (shown after the songs).
    static func pendingLinks(_ db: Database, playlistID: String) throws -> [PlaylistLinkDownloadRecord] {
        try PlaylistLinkDownloadRecord.fetchAll(db, sql: """
            SELECT * FROM playlist_link_downloads WHERE playlistID = ? AND state != 'added' ORDER BY createdAt, batchID, sequence
            """, arguments: [playlistID])
    }

    /// Saves acquisition bookkeeping only while the entry still exists and is not added.
    @discardableResult
    func updateLink(_ value: PlaylistLinkDownloadRecord) throws -> Bool {
        try db.write { db in
            guard let current = try PlaylistLinkDownloadRecord.fetchOne(db, key: value.id), current.state != .added else { return false }
            var stored = value
            if let job = stored.downloadJobID, try StoredDownloadJob.fetchOne(db, key: job) == nil { stored.downloadJobID = nil }
            stored.createdAt = current.createdAt
            try stored.update(db)
            return true
        }
    }

    /// The verified track becomes an ordinary occurrence at the entry's slot, in one
    /// transaction. A removed entry, an entry already added, or a track that is not
    /// present managed audio changes nothing (stale callbacks are harmless).
    enum LinkCompletion: Equatable, Sendable { case added, gone, invalidAudio }

    @discardableResult
    func completeLink(id: String, trackID: String, paths: AppStoragePaths, now: Date = Date()) throws -> LinkCompletion {
        try db.write { db in
            guard var link = try PlaylistLinkDownloadRecord.fetchOne(db, key: id), link.state != .added,
                  try StoredPlaylist.fetchOne(db, key: link.playlistID) != nil else { return .gone }
            guard let track = try StoredTrack.fetchOne(db, key: trackID), MigrationLocalAudio.isAvailable(track, paths: paths) else { return .invalidAudio }
            if try Self.isImportedPlaylist(db, playlistID: link.playlistID) {
                var position = link.slot
                let taken = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM playlist_local_occurrences WHERE playlistID = ? AND position = ?",
                                             arguments: [link.playlistID, position]) ?? 0
                if taken > 0 { position = try Self.nextManualPosition(db, playlistID: link.playlistID) }
                try LocalPlaylistOccurrence(id: UUID().uuidString, playlistID: link.playlistID, trackID: trackID, position: position, createdAt: now).insert(db)
            } else {
                var order = try String.fetchAll(db, sql: "SELECT trackID FROM playlist_tracks WHERE playlistID = ? ORDER BY position", arguments: [link.playlistID])
                if !order.contains(trackID) {
                    // Keep the submitted order: after earlier songs of the same batch that were added.
                    let earlier = try Int.fetchOne(db, sql: """
                        SELECT COUNT(*) FROM playlist_link_downloads l JOIN playlist_tracks p ON p.playlistID = l.playlistID AND p.trackID = l.trackID
                        WHERE l.playlistID = ? AND l.batchID = ? AND l.state = 'added' AND l.sequence < ?
                        """, arguments: [link.playlistID, link.batchID, link.sequence]) ?? 0
                    order.insert(trackID, at: min(order.count, link.slot + earlier))
                    try Self.replaceMembership(order, playlistID: link.playlistID, db: db)
                }
            }
            link.state = .added; link.trackID = trackID; link.failure = nil; link.updatedAt = now
            try link.update(db)
            try db.execute(sql: "UPDATE playlists SET dateModified = ? WHERE id = ?", arguments: [now, link.playlistID])
            return .added
        }
    }

    /// Remove from Playlist for an entry whose audio is not ready yet.
    @discardableResult
    func removeLink(id: String) throws -> PlaylistLinkDownloadRecord? {
        try db.write { db in
            guard let link = try PlaylistLinkDownloadRecord.fetchOne(db, key: id), link.state != .added else { return nil }
            _ = try link.delete(db)
            try db.execute(sql: "UPDATE playlists SET dateModified = ? WHERE id = ?", arguments: [Date(), link.playlistID])
            return link
        }
    }

    /// Explicit Retry: the bounded automatic budget starts again.
    func resetLink(id: String) throws {
        try db.write { db in
            guard var link = try PlaylistLinkDownloadRecord.fetchOne(db, key: id), link.state == .failed else { return }
            link.state = .waiting; link.retries = 0; link.failure = nil; link.updatedAt = Date()
            try link.update(db)
        }
    }
}
