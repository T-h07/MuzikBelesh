import Foundation
import GRDB

/// Persistence for Phase 10.6 orchestration. Occurrences, candidates, decisions,
/// checkpoints, acquisition links and download jobs stay owned by their existing
/// repositories; this type reads them through indexed aggregate queries and writes only
/// coordinator rows, plus the existing intent/control rows inside the same transaction
/// when a user command must change several of them atomically.
final class MigrationCoordinatorRepository: ProviderCooldownPersisting, @unchecked Sendable {
    let db: DatabaseQueue
    init(db: DatabaseQueue) { self.db = db }

    /// Checkpoint outcomes that are temporary and eligible for bounded automatic retry.
    static let temporaryOutcomes: Set<String> = ["discoveryFailed", "provider", "storageBusy", "changedRecords"]
    /// Outcomes that never retry automatically (they remain visible for review).
    static let permanentOutcomes: Set<String> = ["metadata"]

    /// Mirrors `claimMatchingEntry` for an ordinary resume (`retryFailed == false`): the
    /// claim remains the final authority; this is only an indexed, bounded pre-filter.
    static let ordinaryEligibility = """
        e.localTrackID IS NULL
        AND NOT EXISTS (SELECT 1 FROM migration_candidates x WHERE x.entryID = e.id AND x.decision = 'accepted')
        AND (e.status IN ('pending','matching')
             OR (e.status IN ('needsReview','unavailable','failed')
                 AND (c.entryID IS NULL OR c.algorithm != :algorithm OR c.outcome = 'discoveryDeferred')))
        """
    private static let unresolvedEntry = """
        e.localTrackID IS NULL AND e.status IN ('pending','matching','needsReview','unavailable','failed')
        AND NOT EXISTS (SELECT 1 FROM migration_candidates x WHERE x.entryID = e.id AND x.decision = 'accepted')
        """

    // MARK: Aggregate reads

    func overview(algorithm: String, now: Date) async throws -> [MigrationOverview] {
        try await db.read { db in try Self.overview(db, algorithm: algorithm, now: now) }
    }

    static func overview(_ db: Database, algorithm: String, now: Date) throws -> [MigrationOverview] {
        let rows = try Row.fetchAll(db, sql: """
            SELECT m.id, m.status, m.createdAt, j.intent, COALESCE(ctl.userPaused, 0) AS downloadsPaused,
              (SELECT COUNT(*) FROM migration_entries e WHERE e.migrationID = m.id AND e.removedAt IS NULL) AS total,
              (SELECT COUNT(*) FROM migration_entries e WHERE e.migrationID = m.id AND e.status = 'ready' AND e.localTrackID IS NOT NULL) AS ready,
              (SELECT COUNT(*) FROM migration_entries e WHERE e.migrationID = m.id AND e.status IN ('pending','matching')) AS unmatched,
              (SELECT COUNT(*) FROM migration_entries e LEFT JOIN migration_matching_checkpoints c ON c.entryID = e.id
                 WHERE e.migrationID = m.id AND \(ordinaryEligibility)) AS eligible,
              (SELECT COUNT(*) FROM migration_entries e WHERE e.migrationID = m.id AND e.status = 'needsReview') AS review,
              (SELECT COUNT(*) FROM migration_entries e WHERE e.migrationID = m.id AND e.status = 'matched'
                 AND NOT EXISTS (SELECT 1 FROM migration_acquisitions a WHERE a.entryID = e.id)) AS confirmed,
              (SELECT COUNT(*) FROM migration_entries e WHERE e.migrationID = m.id AND e.status IN ('unavailable','failed')) AS issues,
              (SELECT COUNT(*) FROM migration_acquisitions a WHERE a.migrationID = m.id) AS links,
              (SELECT COUNT(*) FROM migration_acquisitions a WHERE a.migrationID = m.id AND a.state IN ('waiting','associating')) AS acquiringOpen,
              (SELECT COUNT(*) FROM migration_acquisitions a WHERE a.migrationID = m.id AND a.state IN ('failed','unsupported')) AS acquisitionIssues,
              (SELECT COUNT(*) FROM migration_acquisitions a LEFT JOIN download_jobs d ON d.id = a.downloadJobID
                 WHERE a.migrationID = m.id AND a.state = 'waiting' AND d.state IN ('resolving','downloading')) AS linkDownloading,
              (SELECT COUNT(*) FROM migration_acquisitions a LEFT JOIN download_jobs d ON d.id = a.downloadJobID
                 WHERE a.migrationID = m.id AND (a.state = 'associating' OR (a.state = 'waiting' AND d.state IN ('verifying','importing','completed')))) AS linkVerifying,
              (SELECT COUNT(*) FROM migration_entry_retries r JOIN migration_entries e ON e.id = r.entryID
                 WHERE r.migrationID = m.id AND r.eligible = 1 AND r.nextRetryAt IS NOT NULL AND r.nextRetryAt <= :now AND \(unresolvedEntry)) AS dueRetries,
              (SELECT COUNT(*) FROM migration_entry_retries r JOIN migration_entries e ON e.id = r.entryID
                 WHERE r.migrationID = m.id AND r.eligible = 1 AND r.category = 'explicitRetry' AND r.nextRetryAt IS NOT NULL
                 AND r.nextRetryAt <= :now AND \(unresolvedEntry)) AS explicitDue,
              (SELECT MIN(r.nextRetryAt) FROM migration_entry_retries r JOIN migration_entries e ON e.id = r.entryID
                 WHERE r.migrationID = m.id AND r.eligible = 1 AND r.nextRetryAt > :now AND \(unresolvedEntry)) AS nextRetryAt
            FROM playlist_migrations m
            LEFT JOIN migration_matching_jobs j ON j.migrationID = m.id
            LEFT JOIN migration_acquisition_controls ctl ON ctl.migrationID = m.id
            ORDER BY m.createdAt, m.id
            """, arguments: ["algorithm": algorithm, "now": now])
        let states = Dictionary(uniqueKeysWithValues: try CoordinatorStateRecord.fetchAll(db).map { ($0.migrationID, $0) })
        return rows.compactMap { row -> MigrationOverview? in
            let idText: String = row["id"]
            let statusText: String = row["status"]
            guard let id = UUID(uuidString: idText), let status = PlaylistMigrationStatus(rawValue: statusText) else { return nil }
            var value = MigrationOverview(migrationID: id, sessionStatus: status, createdAt: row["createdAt"], intent: row["intent"], state: states[idText])
            value.total = row["total"]; value.ready = row["ready"]; value.unmatched = row["unmatched"]; value.eligible = row["eligible"]
            value.review = row["review"]; value.confirmed = row["confirmed"]; value.issues = row["issues"]
            value.downloadsPaused = row["downloadsPaused"]; value.links = row["links"]; value.acquiringOpen = row["acquiringOpen"]
            value.acquisitionIssues = row["acquisitionIssues"]; value.linkDownloading = row["linkDownloading"]; value.linkVerifying = row["linkVerifying"]
            value.linkWaitingQueued = max(0, value.acquiringOpen - value.linkDownloading - value.linkVerifying)
            value.dueRetries = row["dueRetries"]; value.explicitDue = row["explicitDue"]; value.nextRetryAt = row["nextRetryAt"]
            return value
        }
    }

    /// Next ordinary matching slice of one pass, in source order, after the pass cursor.
    func nextSlice(migrationID: UUID, after cursor: Int, limit: Int, algorithm: String) async throws -> [(id: UUID, position: Int)] {
        try await db.read { db in
            try Row.fetchAll(db, sql: """
                SELECT e.id, e.sourcePosition FROM migration_entries e
                LEFT JOIN migration_matching_checkpoints c ON c.entryID = e.id
                WHERE e.migrationID = :migration AND e.sourcePosition > :cursor AND \(Self.ordinaryEligibility)
                ORDER BY e.sourcePosition LIMIT :limit
                """, arguments: ["migration": migrationID.uuidString, "cursor": cursor, "limit": limit, "algorithm": algorithm])
            .compactMap { row -> (id: UUID, position: Int)? in
                let id: String = row["id"], position: Int = row["sourcePosition"]
                return UUID(uuidString: id).map { ($0, position) }
            }
        }
    }

    /// Due retry occurrences in source order. Automatic retries are excluded when
    /// `automatic` is false (e.g. matching is user-paused); explicit requests are not.
    func dueRetries(migrationID: UUID, now: Date, limit: Int, automatic: Bool) async throws -> [UUID] {
        try await db.read { db in
            try String.fetchAll(db, sql: """
                SELECT r.entryID FROM migration_entry_retries r JOIN migration_entries e ON e.id = r.entryID
                WHERE r.migrationID = :migration AND r.eligible = 1 AND r.nextRetryAt IS NOT NULL AND r.nextRetryAt <= :now
                  AND (:automatic = 1 OR r.category = 'explicitRetry') AND \(Self.unresolvedEntry)
                ORDER BY e.sourcePosition LIMIT :limit
                """, arguments: ["migration": migrationID.uuidString, "now": now, "automatic": automatic, "limit": limit])
            .compactMap(UUID.init(uuidString:))
        }
    }

    // MARK: Retry bookkeeping

    /// Leases due retries to one attempt: the deadline moves to `lease`, so a process
    /// death during the attempt is retried after that bounded delay, never lost.
    func claimRetries(_ entryIDs: [UUID], now: Date, lease: Date) async throws {
        guard !entryIDs.isEmpty else { return }
        try await db.write { db in
            for id in entryIDs {
                guard var record = try EntryRetryRecord.fetchOne(db, key: id.uuidString) else { continue }
                record.lastAttemptAt = now; record.nextRetryAt = lease; record.updatedAt = now
                try record.update(db)
            }
        }
    }

    /// Records the outcome of every occurrence whose checkpoint changed since `since`.
    /// Temporary failures schedule the next bounded retry; permanent ones are kept for
    /// review without retry; successes and deferrals clear the bookkeeping. Idempotent
    /// for a given attempt: it only reads checkpoints the attempt itself wrote.
    @discardableResult
    func recordOutcomes(migrationID: UUID, since: Date, policy: MigrationRetryPolicy, now: Date) async throws -> (scheduled: Int, exhausted: Int) {
        try await db.write { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT e.id, e.status, e.localTrackID, c.outcome, c.retryable, r.failures
                FROM migration_entries e JOIN migration_matching_checkpoints c ON c.entryID = e.id
                LEFT JOIN migration_entry_retries r ON r.entryID = e.id
                WHERE e.migrationID = ? AND c.updatedAt >= ?
                """, arguments: [migrationID.uuidString, since])
            var scheduled = 0, exhausted = 0
            for row in rows {
                let entryID: String = row["id"], status: String = row["status"], outcome: String = row["outcome"]
                let retryable: Bool = row["retryable"], previous: Int? = row["failures"]
                let unresolved = (row["localTrackID"] as String?) == nil && !["ready", "matched", "skipped"].contains(status)
                if unresolved && retryable && Self.temporaryOutcomes.contains(outcome) {
                    let failures = (previous ?? 0) + 1
                    let delay = policy.delay(afterFailure: failures)
                    if delay == nil { exhausted += 1 } else { scheduled += 1 }
                    try EntryRetryRecord(entryID: entryID, migrationID: migrationID.uuidString, failures: failures,
                        category: (MigrationFailureCategory.matching(outcome: outcome) ?? .providerTemporary).rawValue,
                        eligible: delay != nil, lastAttemptAt: now, nextRetryAt: delay.map { now.addingTimeInterval($0) }, updatedAt: now).save(db)
                } else if unresolved && Self.permanentOutcomes.contains(outcome) {
                    try EntryRetryRecord(entryID: entryID, migrationID: migrationID.uuidString, failures: (previous ?? 0) + 1,
                        category: MigrationFailureCategory.invalidMetadata.rawValue, eligible: false, lastAttemptAt: now, nextRetryAt: nil, updatedAt: now).save(db)
                } else if previous != nil {
                    _ = try EntryRetryRecord.deleteOne(db, key: entryID)
                }
            }
            return (scheduled, exhausted)
        }
    }

    /// Explicit user retry: resets the automatic budget and makes the occurrences due now.
    func scheduleExplicitRetry(_ entryIDs: [UUID], migrationID: UUID, now: Date) async throws {
        try await db.write { db in
            for id in entryIDs {
                guard try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM migration_entries WHERE id = ? AND migrationID = ?)",
                                        arguments: [id.uuidString, migrationID.uuidString]) == true else { continue }
                try EntryRetryRecord(entryID: id.uuidString, migrationID: migrationID.uuidString, failures: 0,
                    category: MigrationFailureCategory.explicitRetry.rawValue, eligible: true, lastAttemptAt: nil, nextRetryAt: now, updatedAt: now).save(db)
            }
        }
    }

    /// Occurrences an explicit "Retry songs that failed" covers (legacy `retryFailed`).
    func retryableFailures(migrationID: UUID) async throws -> [UUID] {
        try await db.read { db in
            try String.fetchAll(db, sql: """
                SELECT e.id FROM migration_entries e LEFT JOIN migration_matching_checkpoints c ON c.entryID = e.id
                WHERE e.migrationID = ? AND e.localTrackID IS NULL
                  AND NOT EXISTS (SELECT 1 FROM migration_candidates x WHERE x.entryID = e.id AND x.decision = 'accepted')
                  AND (e.status = 'failed' OR (e.status IN ('needsReview','unavailable') AND c.retryable = 1))
                ORDER BY e.sourcePosition
                """, arguments: [migrationID.uuidString]).compactMap(UUID.init(uuidString:))
        }
    }

    func retryRecord(entryID: UUID) async throws -> EntryRetryRecord? {
        try await db.read { db in try EntryRetryRecord.fetchOne(db, key: entryID.uuidString) }
    }

    // MARK: Coordinator state

    func states() async throws -> [String: CoordinatorStateRecord] {
        try await db.read { db in Dictionary(uniqueKeysWithValues: try CoordinatorStateRecord.fetchAll(db).map { ($0.migrationID, $0) }) }
    }

    func state(_ migrationID: UUID) async throws -> CoordinatorStateRecord? {
        try await db.read { db in try CoordinatorStateRecord.fetchOne(db, key: migrationID.uuidString) }
    }

    /// Merges only the fields `change` touches. A deleted migration is skipped.
    func updateState(_ migrationID: UUID, now: Date, _ change: @escaping @Sendable (inout CoordinatorStateRecord) -> Void) async throws {
        try await db.write { db in try Self.updateState(db, migrationID.uuidString, now: now, change) }
    }

    static func updateState(_ db: Database, _ migrationID: String, now: Date, _ change: (inout CoordinatorStateRecord) -> Void) throws {
        guard try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM playlist_migrations WHERE id = ?)", arguments: [migrationID]) == true else { return }
        let existing = try CoordinatorStateRecord.fetchOne(db, key: migrationID)
        var record = existing ?? .initial(migrationID, now: now)
        change(&record)
        guard existing == nil || record != existing else { return }
        record.updatedAt = now
        try record.save(db)
    }

    /// Derived lifecycle states for several migrations in one transaction. Only the
    /// state and reason change; leases and cursors are left to their owners.
    func setLifecycle(_ values: [UUID: (MigrationLifecycleState, String?)], now: Date) async throws {
        guard !values.isEmpty else { return }
        try await db.write { db in
            for (id, value) in values {
                try Self.updateState(db, id.uuidString, now: now) { record in record.state = value.0; record.reason = value.1 }
            }
        }
    }

    /// Opens a new execution generation for one unit of work.
    func beginRun(_ migrationID: UUID, generation: UUID, cursorReset: Bool, now: Date) async throws {
        try await updateState(migrationID, now: now) { record in
            record.state = .matching; record.generation = generation.uuidString
            record.lastScheduledAt = now; record.heartbeatAt = now; record.interruptedBySystem = false
            if cursorReset { record.cursorPosition = -1 }
            if record.waitUntil.map({ $0 <= now }) ?? false { record.waitUntil = nil }
        }
    }

    /// Closes a generation. Returns false (and writes nothing) when the generation is no
    /// longer current: a stale callback never overwrites a newer execution.
    func endRun(_ migrationID: UUID, generation: UUID, now: Date, _ change: @escaping @Sendable (inout CoordinatorStateRecord) -> Void) async throws -> Bool {
        try await db.write { db in
            guard let current = try CoordinatorStateRecord.fetchOne(db, key: migrationID.uuidString),
                  current.generation == generation.uuidString else { return false }
            try Self.updateState(db, migrationID.uuidString, now: now) { record in
                change(&record); record.generation = nil; record.heartbeatAt = now; record.lastCheckpointAt = now
            }
            return true
        }
    }

    /// Ordinary matching work still claimable for one migration.
    func eligibleCount(migrationID: UUID, algorithm: String) async throws -> Int {
        try await db.read { db in
            try Int.fetchOne(db, sql: """
                SELECT COUNT(*) FROM migration_entries e LEFT JOIN migration_matching_checkpoints c ON c.entryID = e.id
                WHERE e.migrationID = :migration AND \(Self.ordinaryEligibility)
                """, arguments: ["migration": migrationID.uuidString, "algorithm": algorithm]) ?? 0
        }
    }

    /// Connectivity returned: every connectivity wait is re-evaluated immediately.
    func clearNetworkWaits(now: Date) async throws -> Int {
        try await db.write { db in
            let waiting = try CoordinatorStateRecord.filter(Column("state") == MigrationLifecycleState.waitingForNetwork.rawValue).fetchAll(db)
            for record in waiting {
                try Self.updateState(db, record.migrationID, now: now) { $0.waitUntil = nil; $0.state = .pending }
            }
            return waiting.count
        }
    }

    // MARK: Launch recovery

    /// A row recorded as running does not prove it is executing. At launch no app-owned
    /// matching worker exists, so in-flight occurrences become unfinished again, the
    /// session revision is bumped (an old lease can never commit) and every open
    /// generation is closed. Background URLSession transfers are not touched: they are
    /// owned by `DownloadManager`, whose inventory reconciliation runs before this.
    @discardableResult
    func recoverAbandonedWork(now: Date) async throws -> [UUID] {
        try await db.write { db in
            var recovered: [UUID] = []
            for var entry in try MigrationEntryRecord.filter(Column("status") == PlaylistMigrationEntryStatus.matching.rawValue).fetchAll(db) {
                let saved = try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM migration_candidates WHERE entryID = ?)", arguments: [entry.id]) ?? false
                let next: PlaylistMigrationEntryStatus = saved ? .needsReview : .pending
                try PlaylistMigrationValidation.requireEntryTransition(entry.status, to: next)
                entry.status = next; entry.updatedAt = max(now, entry.updatedAt.addingTimeInterval(0.01)); try entry.update(db)
            }
            for var session in try MigrationSessionRecord.filter(Column("status") == PlaylistMigrationStatus.matching.rawValue).fetchAll(db) {
                try PlaylistMigrationValidation.requireSessionTransition(session.status, to: .paused)
                session.status = .paused; session.updatedAt = max(now, session.updatedAt.addingTimeInterval(0.01)); try session.update(db)
                if let id = UUID(uuidString: session.id) { recovered.append(id) }
            }
            let intents = Dictionary(uniqueKeysWithValues: try MatchingJobRecord.fetchAll(db).map { ($0.migrationID, $0.intent) })
            for record in try CoordinatorStateRecord.fetchAll(db) {
                let intent = intents[record.migrationID]
                try Self.updateState(db, record.migrationID, now: now) { value in
                    if value.generation != nil || value.state == .matching {
                        value.interruptedBySystem = true
                        if value.state == .matching { value.state = .systemSuspended }
                    }
                    if intent == "userCancelled" { value.state = .cancelled }
                    value.generation = nil; value.lastRecoveryAt = now
                }
            }
            for (migrationID, intent) in intents where ["running", "systemPaused"].contains(intent) {
                try Self.updateState(db, migrationID, now: now) { value in
                    value.lastRecoveryAt = now
                    if [.pending, .matching].contains(value.state) { value.state = .systemSuspended; value.interruptedBySystem = true }
                }
            }
            return recovered
        }
    }

    // MARK: User commands (atomic)

    /// Persists Pause for matching and acquisition before any new work may start.
    func pause(migrationID: UUID, now: Date) async throws {
        try await db.write { db in
            let id = migrationID.uuidString
            guard let session = try MigrationSessionRecord.fetchOne(db, key: id) else { throw PlaylistMigrationStorageError.notFound }
            guard session.status != .cancelled else { return }
            let intent = try MatchingJobRecord.fetchOne(db, key: id)?.intent
            if intent != "userCancelled" { try MatchingJobRecord(migrationID: id, intent: "userPaused", updatedAt: now).save(db) }
            var control = try AcquisitionControlRecord.fetchOne(db, key: id)
                ?? AcquisitionControlRecord(migrationID: id, userPaused: false, readyNotifiedAt: nil, partialNotifiedSummary: nil, updatedAt: now)
            control.userPaused = true; control.updatedAt = now; try control.save(db)
            try Self.updateState(db, id, now: now) { $0.state = .userPaused; $0.reason = "Paused by user" }
        }
    }

    /// Clears user Pause for matching and acquisition. Cooldowns and retry deadlines
    /// are preserved; only a connectivity wait is cleared so the state is re-evaluated.
    func resume(migrationID: UUID, now: Date) async throws {
        try await db.write { db in
            let id = migrationID.uuidString
            guard let session = try MigrationSessionRecord.fetchOne(db, key: id) else { throw PlaylistMigrationStorageError.notFound }
            guard !session.status.isTerminal else { return }
            let intent = try MatchingJobRecord.fetchOne(db, key: id)?.intent
            if ["userPaused", "systemPaused", "fatal"].contains(intent ?? "") {
                try MatchingJobRecord(migrationID: id, intent: "running", updatedAt: now).save(db)
            }
            if var control = try AcquisitionControlRecord.fetchOne(db, key: id), control.userPaused {
                control.userPaused = false; control.updatedAt = now; try control.save(db)
            }
            try Self.updateState(db, id, now: now) { value in
                let cooling = value.state == .coolingDown
                value.state = .pending; value.reason = nil; value.cursorPosition = -1
                if !cooling { value.waitUntil = nil }
            }
        }
    }

    /// One transaction: in-flight occurrences become unfinished, the session becomes
    /// `cancelled` (so acquisition stops creating work for it), matching intent becomes
    /// `userCancelled`, retry bookkeeping is removed. Tracks, files, the destination
    /// playlist and already verified occurrences are never touched.
    func cancel(migrationID: UUID, now: Date) async throws {
        try await db.write { db in
            let id = migrationID.uuidString
            guard var session = try MigrationSessionRecord.fetchOne(db, key: id) else { throw PlaylistMigrationStorageError.notFound }
            if session.status != .cancelled {
                guard session.status != .completed else { throw PlaylistMigrationFoundationError.illegalSessionTransition }
                for var entry in try MigrationEntryRecord.filter(Column("migrationID") == id && Column("status") == PlaylistMigrationEntryStatus.matching.rawValue).fetchAll(db) {
                    let saved = try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM migration_candidates WHERE entryID = ?)", arguments: [entry.id]) ?? false
                    let next: PlaylistMigrationEntryStatus = saved ? .needsReview : .pending
                    try PlaylistMigrationValidation.requireEntryTransition(entry.status, to: next)
                    entry.status = next; entry.updatedAt = max(now, entry.updatedAt.addingTimeInterval(0.01)); try entry.update(db)
                }
                try PlaylistMigrationValidation.requireSessionTransition(session.status, to: .cancelled)
                session.status = .cancelled; session.updatedAt = max(now, session.updatedAt.addingTimeInterval(0.01)); try session.update(db)
            }
            try MatchingJobRecord(migrationID: id, intent: "userCancelled", updatedAt: now).save(db)
            _ = try EntryRetryRecord.filter(Column("migrationID") == id).deleteAll(db)
            try Self.updateState(db, id, now: now) { value in
                value.state = .cancelled; value.reason = "Cancelled by user"; value.generation = nil; value.waitUntil = nil
            }
        }
    }

    // MARK: Provider cooldowns

    func providerCooldowns() async throws -> [String: PersistedProviderCooldown] {
        try await db.read { db in Dictionary(uniqueKeysWithValues: try PersistedProviderCooldown.fetchAll(db).map { ($0.provider, $0) }) }
    }
    func saveProviderCooldown(_ value: PersistedProviderCooldown) async throws {
        var value = value
        value.provider = String(value.provider.prefix(60)); value.reason = value.reason.map { String($0.prefix(300)) }
        guard !value.provider.isEmpty else { return }
        let stored = value
        try await db.write { db in try stored.save(db) }
        CoordinatorDiagnostics.event("providerCooldownActivated", ["provider": stored.provider, "probes": String(stored.probes),
            "seconds": String(Int(stored.expiresAt.timeIntervalSince(stored.updatedAt)))])
    }
    func clearProviderCooldown(_ provider: String) async throws {
        try await db.write { db in _ = try PersistedProviderCooldown.deleteOne(db, key: provider) }
        CoordinatorDiagnostics.event("providerCooldownCleared", ["provider": provider])
    }
}
