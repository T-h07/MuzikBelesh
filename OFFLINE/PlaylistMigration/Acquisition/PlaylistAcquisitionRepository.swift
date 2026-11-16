import Foundation
import GRDB

/// Persistence for Phase 10.5 acquisition links and per-playlist controls.
/// Source occurrences, candidates and decisions remain owned by
/// `GRDBPlaylistMigrationRepository`; this type only reads them.
final class PlaylistAcquisitionRepository: @unchecked Sendable {
    let db: DatabaseQueue
    init(db: DatabaseQueue) { self.db = db }

    /// One consistent read of everything reconciliation needs.
    func plan() async throws -> AcquisitionPlan {
        try await db.read { db in try Self.plan(db) }
    }

    static func plan(_ db: Database) throws -> AcquisitionPlan {
        var plan = AcquisitionPlan()
        for row in try Row.fetchAll(db, sql: "SELECT id, destinationPlaylistID, sourcePlaylistName, status FROM playlist_migrations") {
            let id: String = row["id"]
            plan.playlists[id] = AcquisitionPlaylist(migrationID: id, playlistID: row["destinationPlaylistID"], name: row["sourcePlaylistName"],
                                                     cancelled: (row["status"] as String) == PlaylistMigrationStatus.cancelled.rawValue)
        }
        plan.links = try AcquisitionLinkRecord.order(Column("migrationID"), Column("entryID")).fetchAll(db)
        plan.controls = Dictionary(uniqueKeysWithValues: try AcquisitionControlRecord.fetchAll(db).map { ($0.migrationID, $0) })
        // Entries holding an accepted decision, plus any entry that already has a link
        // (its decision may since have changed, which makes the link stale).
        let rows = try Row.fetchAll(db, sql: """
            SELECT e.id AS entryID, e.migrationID, e.sourcePosition, e.status, e.localTrackID,
                   c.id AS candidateID, c.provider, c.providerTrackID, c.title, c.durationMs, c.evidence
            FROM migration_entries e
            LEFT JOIN migration_candidates c ON c.entryID = e.id AND c.decision = 'accepted'
            WHERE c.id IS NOT NULL OR e.id IN (SELECT entryID FROM migration_acquisitions)
            ORDER BY e.migrationID, e.sourcePosition
            """)
        var grouped: [String: [Row]] = [:]
        var order: [String] = []
        for row in rows {
            let id: String = row["entryID"]
            if grouped[id] == nil { order.append(id) }
            grouped[id, default: []].append(row)
        }
        for id in order {
            guard let group = grouped[id], let first = group.first,
                  let status = PlaylistMigrationEntryStatus(rawValue: first["status"]) else { continue }
            let accepted = group.filter { ($0["candidateID"] as String?) != nil }
            // Write paths make more than one accepted decision impossible; never guess.
            let candidate = accepted.count == 1 ? accepted[0] : nil
            let acceptedID: String? = candidate.map { $0["candidateID"] as String }
            plan.entries[id] = AcquisitionEntrySnapshot(status: status, localTrackID: first["localTrackID"] as String?, acceptedCandidateID: acceptedID)
            let migrationID: String = first["migrationID"]
            guard let candidate, status == .matched, (first["localTrackID"] as String?) == nil,
                  (candidate["provider"] as String?) == "youtube", let videoID = candidate["providerTrackID"] as String?,
                  plan.playlists[migrationID]?.cancelled == false else { continue }
            let evidence = (candidate["evidence"] as String?).flatMap { try? JSONDecoder().decode([String: String].self, from: Data($0.utf8)) } ?? [:]
            plan.demands.append(AcquisitionDemand(entryID: id, migrationID: migrationID, candidateID: candidate["candidateID"],
                videoID: videoID, title: candidate["title"], channel: evidence["channel"], durationMs: candidate["durationMs"],
                thumbnail: evidence["thumbnailURL"].flatMap(URL.init(string:)).flatMap { MatchingCandidateArtwork.safe($0) },
                position: first["sourcePosition"]))
        }
        plan.replacements = try RecordingReplacementRecord.order(Column("createdAt"), Column("entryID")).fetchAll(db)
        return plan
    }

    /// Inserts or replaces links. A link whose occurrence disappeared (playlist deleted)
    /// is skipped rather than failing the whole batch. Unknown job/track references are
    /// cleared instead of violating foreign keys.
    func save(_ links: [AcquisitionLinkRecord]) async throws {
        guard !links.isEmpty else { return }
        try await db.write { db in
            for var link in links {
                guard try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM migration_entries WHERE id = ? AND migrationID = ?)",
                                        arguments: [link.entryID, link.migrationID]) == true else { continue }
                if let job = link.downloadJobID, try StoredDownloadJob.fetchOne(db, key: job) == nil { link.downloadJobID = nil }
                if let track = link.trackID, try StoredTrack.fetchOne(db, key: track) == nil { link.trackID = nil; if link.state == .associating { link.state = .waiting } }
                try link.save(db)
            }
        }
    }

    func delete(entryIDs: [String]) async throws {
        guard !entryIDs.isEmpty else { return }
        try await db.write { db in
            _ = try AcquisitionLinkRecord.filter(keys: entryIDs).deleteAll(db)
        }
    }

    func links(migrationID: String) async throws -> [AcquisitionLinkRecord] {
        try await db.read { db in try AcquisitionLinkRecord.filter(Column("migrationID") == migrationID).fetchAll(db) }
    }

    /// Durable user intent. Survives relaunch; only an explicit Continue clears it.
    func setPaused(_ paused: Bool, migrationID: String) async throws {
        try await updateControl(migrationID) { $0.userPaused = paused }
    }

    /// Merges only the given fields, so concurrent intent (Pause) is never overwritten.
    func updateControl(_ migrationID: String, _ change: @escaping @Sendable (inout AcquisitionControlRecord) -> Void) async throws {
        try await db.write { db in
            guard try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM playlist_migrations WHERE id = ?)", arguments: [migrationID]) == true else {
                throw PlaylistMigrationStorageError.notFound
            }
            var record = try AcquisitionControlRecord.fetchOne(db, key: migrationID)
                ?? AcquisitionControlRecord(migrationID: migrationID, userPaused: false, readyNotifiedAt: nil, partialNotifiedSummary: nil, updatedAt: Date())
            change(&record)
            record.updatedAt = Date()
            try record.save(db)
        }
    }
}
