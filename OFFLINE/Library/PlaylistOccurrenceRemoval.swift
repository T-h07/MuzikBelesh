import Foundation
import GRDB

/// Remove from Playlist for imported (Spotify) occurrences. Additive only.
///
/// The occurrence row is *kept* — `verify()` requires every original source position to
/// exist, import history and diagnostics stay intact, and Undo can restore it — but it
/// is marked removed and moved to `skipped` with no local audio. Every existing matching,
/// acquisition, association and replacement guard already refuses `skipped`
/// occurrences, so a retry, resume, restart or late callback can never bring it back.
/// All occurrence reads (`GRDBPlaylistMigrationRepository.entries`) hide removed rows,
/// so playlist rows, counts, progress, matching work and issue reports follow the new
/// membership. No audio file or library track is touched.
enum PlaylistOccurrenceRemovalSchema {
    static let version = "v021_playlist_occurrence_removal"

    static func register(in migrator: inout DatabaseMigrator) {
        migrator.registerMigration(version) { db in
            try db.execute(sql: """
                ALTER TABLE migration_entries ADD COLUMN removedAt DATETIME;
                ALTER TABLE migration_entries ADD COLUMN removedStatus TEXT CHECK(removedStatus IS NULL OR length(removedStatus) BETWEEN 1 AND 40);
                ALTER TABLE migration_entries ADD COLUMN removedTrackID TEXT;
                CREATE INDEX migration_entries_removed ON migration_entries(migrationID, removedAt);
                """)
        }
    }
}

/// What a removal captured, for Undo.
struct RemovedPlaylistOccurrence: Equatable, Sendable {
    let entryID: UUID
    let playlistID: String
    let title: String
}

extension GRDBPlaylistMigrationRepository {
    /// Occurrences removed from one migration's playlist (they still exist as rows).
    static func removedCount(_ db: Database, migrationID: String) throws -> Int {
        try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM migration_entries WHERE migrationID = ? AND removedAt IS NOT NULL", arguments: [migrationID]) ?? 0
    }

    static func isRemoved(_ db: Database, entryID: String) throws -> Bool {
        try Bool.fetchOne(db, sql: "SELECT removedAt IS NOT NULL FROM migration_entries WHERE id = ?", arguments: [entryID]) ?? false
    }

    /// Removes exactly this occurrence from its imported playlist, in one transaction:
    /// marks it removed (remembering its state for Undo), detaches its local audio
    /// reference (the track and file stay in the library), drops its retry bookkeeping
    /// and any staged replacement, and closes its open issue records. Other occurrences of
    /// the same song, other playlists and shared downloads are unaffected; acquisition
    /// consumer accounting pauses a download only when no one else needs it.
    @discardableResult
    func removeOccurrence(entryID: UUID, playlistID: String) async throws -> RemovedPlaylistOccurrence {
        try await db.write { db in
            guard let row = try Row.fetchOne(db, sql: """
                SELECT e.id, e.title, e.status, e.localTrackID, e.removedAt, m.id AS migrationID, m.destinationPlaylistID
                FROM migration_entries e JOIN playlist_migrations m ON m.id = e.migrationID WHERE e.id = ?
                """, arguments: [entryID.uuidString]),
                  (row["destinationPlaylistID"] as String?) == playlistID else { throw LibraryError.notFound }
            let title: String = row["title"]
            let result = RemovedPlaylistOccurrence(entryID: entryID, playlistID: playlistID, title: title)
            if (row["removedAt"] as Date?) != nil { return result } // Idempotent.
            let now = Date(), id = entryID.uuidString, migrationID: String = row["migrationID"]
            try db.execute(sql: """
                UPDATE migration_entries SET removedAt = ?, removedStatus = status, removedTrackID = localTrackID,
                    status = 'skipped', localTrackID = NULL, updatedAt = ? WHERE id = ?
                """, arguments: [now, now, id])
            try db.execute(sql: "DELETE FROM migration_entry_retries WHERE entryID = ?", arguments: [id])
            try db.execute(sql: "DELETE FROM migration_replacements WHERE entryID = ?", arguments: [id])
            try db.execute(sql: """
                UPDATE migration_candidates SET updatedAt = ?,
                    evidence = json_set(evidence, '$.stagedReplacement', 'false', '$.replacementOutcome', 'removed')
                WHERE entryID = ? AND decision = 'pending' AND json_extract(evidence, '$.stagedReplacement') = 'true'
                """, arguments: [now, id])
            try db.execute(sql: """
                UPDATE migration_issues SET resolution = 'resolved', closeReason = 'userAction', resolvedAt = ?, updatedAt = ?
                WHERE entryID = ? AND resolution = 'open' AND code IN (\(MigrationIssueSchema.reportCodes))
                """, arguments: [now, now, id])
            try db.execute(sql: """
                INSERT INTO migration_issues (id, migrationID, entryID, code, message, technicalDetails, severity, resolution,
                    createdAt, updatedAt, resolvedAt, closeReason)
                VALUES (?, ?, ?, 'user.remove', 'Removed from the playlist by you.', NULL, 'information', 'resolved', ?, ?, ?, 'userAction')
                """, arguments: [UUID().uuidString, migrationID, id, now, now, now])
            try db.execute(sql: "UPDATE playlists SET dateModified = ? WHERE id = ?", arguments: [now, playlistID])
            return result
        }
    }

    /// Undo: the occurrence returns at its original position with the state it had,
    /// re-validated: verified audio is re-associated only if it is still present and
    /// valid, in-flight work becomes unfinished, and a confirmed recording resumes
    /// acquisition. Nothing is downloaded or matched again that was already done.
    func restoreOccurrence(entryID: UUID, playlistID: String) async throws {
        try await db.write { [paths] db in
            guard let row = try Row.fetchOne(db, sql: """
                SELECT e.removedAt, e.removedStatus, e.removedTrackID, e.migrationID, m.destinationPlaylistID
                FROM migration_entries e JOIN playlist_migrations m ON m.id = e.migrationID WHERE e.id = ?
                """, arguments: [entryID.uuidString]),
                  (row["destinationPlaylistID"] as String?) == playlistID else { throw LibraryError.notFound }
            guard (row["removedAt"] as Date?) != nil else { return }
            let id = entryID.uuidString
            let previous = (row["removedStatus"] as String?).flatMap(PlaylistMigrationEntryStatus.init(rawValue:)) ?? .pending
            let accepted = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM migration_candidates WHERE entryID = ? AND decision = 'accepted'", arguments: [id]) ?? 0
            let pending = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM migration_candidates WHERE entryID = ? AND decision = 'pending'", arguments: [id]) ?? 0
            var track: String?
            if let trackID = row["removedTrackID"] as String?,
               try StoredTrack.fetchOne(db, key: trackID).map({ MigrationLocalAudio.isAvailable($0, paths: paths) }) == true { track = trackID }
            let status: PlaylistMigrationEntryStatus
            switch previous {
            case .ready, .verifying: status = track != nil ? .ready : .unavailable
            case .matching: status = pending > 0 ? .needsReview : .pending
            case .matched, .queued, .downloading: status = accepted > 0 ? .matched : (pending > 0 ? .needsReview : .pending)
            default: status = previous
            }
            if status != .ready { track = nil }
            let now = Date()
            try db.execute(sql: """
                UPDATE migration_entries SET removedAt = NULL, removedStatus = NULL, removedTrackID = NULL,
                    status = ?, localTrackID = ?, updatedAt = ? WHERE id = ?
                """, arguments: [status.rawValue, track, now, id])
            try db.execute(sql: """
                INSERT INTO migration_issues (id, migrationID, entryID, code, message, technicalDetails, severity, resolution,
                    createdAt, updatedAt, resolvedAt, closeReason)
                VALUES (?, ?, ?, 'user.restore-occurrence', 'Added back to the playlist by you.', NULL, 'information', 'resolved', ?, ?, ?, 'userAction')
                """, arguments: [UUID().uuidString, row["migrationID"] as String, id, now, now, now])
            try db.execute(sql: "UPDATE playlists SET dateModified = ? WHERE id = ?", arguments: [now, playlistID])
        }
    }
}

extension LibraryRepository {
    /// Undo for an ordinary playlist: the song returns at its previous index.
    func insertTrack(_ id: String, at index: Int, playlistID: String) throws {
        try db.write { db in
            var order = try String.fetchAll(db, sql: "SELECT trackID FROM playlist_tracks WHERE playlistID = ? ORDER BY position", arguments: [playlistID])
            guard !order.contains(id) else { return }
            order.insert(id, at: min(max(0, index), order.count))
            try Self.replaceMembership(order, playlistID: playlistID, db: db)
        }
    }

    /// Undo for a manually added song in an imported playlist: the same occurrence
    /// identity returns at its position (or at the end if that position was reused).
    func restoreManualOccurrence(_ occurrence: LocalPlaylistOccurrence) throws {
        try db.write { db in
            guard try LocalPlaylistOccurrence.fetchOne(db, key: occurrence.id) == nil else { return }
            guard try StoredTrack.fetchOne(db, key: occurrence.trackID) != nil else { throw LibraryError.notFound }
            var value = occurrence
            let taken = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM playlist_local_occurrences WHERE playlistID = ? AND position = ?",
                                         arguments: [value.playlistID, value.position]) ?? 0
            if taken > 0 {
                value.position = try Self.nextManualPosition(db, playlistID: value.playlistID)
            }
            try value.insert(db)
            try db.execute(sql: "UPDATE playlists SET dateModified = ? WHERE id = ?", arguments: [Date(), value.playlistID])
        }
    }
}

/// The last Remove from Playlist, for the Undo banner.
struct PlaylistRemovalUndo: Identifiable {
    enum Kind {
        case imported(UUID)
        case manual(LocalPlaylistOccurrence)
        case ordinary(trackID: String, index: Int)
    }
    let id = UUID()
    let playlistID: String
    let title: String
    let kind: Kind
}
