import Foundation
import GRDB

/// Durable Phase 10.7 notification event (one per migration and processing cycle).
struct MigrationReportEvent: Equatable, Sendable {
    enum Kind: String, Sendable { case fullyReady, needsAttention }
    enum Delivery: String, Sendable { case delivered, notPermitted, coalesced, superseded, abandoned }
    let migrationID: UUID
    let cycle: Int
    let kind: Kind
    let revision: String
    let batchAtSettle: Int?
    let delivery: Delivery?
    let attempts: Int
    let lastAttemptAt: Date?
    let createdAt: Date
}

/// Per-migration report bookkeeping (processing cycle and in-app presentation).
struct MigrationReportState: Equatable, Sendable {
    var cycle: Int
    var settled: Bool
    var outcome: String?
    var settledAt: Date?
    var presentedCycle: Int
}

/// Everything one reconciliation produced for one migration.
struct MigrationIssueReconciliation: Equatable, Sendable {
    let report: MigrationIssueReport
    let state: MigrationReportState
    /// The current cycle's undelivered aggregate event, if any.
    let pendingEvent: MigrationReportEvent?
    /// Acquisition (Phase 10.5) facts the notification policy coordinates with.
    let acquisitionLinks: Int
    let acquisitionBatchPending: Bool
    let resolvedBatch: Int?
    let batchDelivered: Bool
    let opened: Int
    let closed: Int
}

/// Persistence for Phase 10.7. Occurrences, candidates, decisions, checkpoints, retry
/// bookkeeping, acquisition links and download jobs are only *read*; the writes are
/// limited to `migration_issues` report records, the report ledger tables, and the two
/// explicit user transitions Skip/Restore (validated against the occurrence state
/// machine inside one transaction).
final class MigrationIssueRepository: @unchecked Sendable {
    let db: DatabaseQueue
    let paths: AppStoragePaths
    init(db: DatabaseQueue, paths: AppStoragePaths) { self.db = db; self.paths = paths }

    static let maximumDeliveryAttempts = 3

    // MARK: Reads

    func migrationIDs() async throws -> [UUID] {
        try await db.read { db in
            try String.fetchAll(db, sql: "SELECT id FROM playlist_migrations ORDER BY createdAt, id").compactMap(UUID.init(uuidString:))
        }
    }

    func migrationID(playlistID: String) async throws -> UUID? {
        try await db.read { db in
            try String.fetchOne(db, sql: "SELECT id FROM playlist_migrations WHERE destinationPlaylistID = ?", arguments: [playlistID]).flatMap(UUID.init(uuidString:))
        }
    }

    /// Read-only report (no issue records are written). Used for on-demand screens.
    func report(migrationID: UUID, now: Date, capacity: Int64?) async throws -> MigrationIssueReport? {
        try await db.read { [paths] db in try Self.build(db, migrationID: migrationID, paths: paths, now: now, capacity: capacity)?.report }
    }

    func state(migrationID: UUID) async throws -> MigrationReportState? {
        try await db.read { db in try Self.state(db, migrationID.uuidString) }
    }

    func events(migrationID: UUID) async throws -> [MigrationReportEvent] {
        try await db.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM migration_report_events WHERE migrationID = ? ORDER BY cycle", arguments: [migrationID.uuidString])
                .compactMap(Self.event)
        }
    }

    /// All Phase 10.7 issue records (open and closed) of one migration, oldest first.
    func issueRows(migrationID: UUID) async throws -> [MigrationIssueRow] {
        try await db.read { db in
            try Row.fetchAll(db, sql: """
                SELECT * FROM migration_issues WHERE migrationID = ? AND code IN (\(MigrationIssueSchema.reportCodes))
                ORDER BY createdAt, id
                """, arguments: [migrationID.uuidString]).compactMap(Self.issueRow)
        }
    }

    // MARK: Reconciliation (one write transaction)

    /// Classifies every original occurrence from committed state, brings the open issue
    /// records in line (create, keep, supersede, resolve — never delete), and advances
    /// the processing cycle. Reading and writing share the transaction, so a stale
    /// callback or an older snapshot can never reopen or resolve a newer outcome.
    /// Idempotent: a second run with unchanged state writes nothing.
    func reconcile(migrationID: UUID, now: Date, capacity: Int64?) async throws -> MigrationIssueReconciliation? {
        try await db.write { [paths] db in
            guard let built = try Self.build(db, migrationID: migrationID, paths: paths, now: now, capacity: capacity) else { return nil }
            var opened = 0, closed = 0
            for occurrence in built.report.occurrences {
                let result = try Self.reconcileIssues(db, migrationID: migrationID, occurrence: occurrence, open: built.open[occurrence.id] ?? [], now: now)
                opened += result.opened; closed += result.closed
            }
            let state = try Self.advanceCycle(db, migrationID: migrationID, summary: built.report.summary, control: built.control, now: now)
            let pending = try Row.fetchOne(db, sql: """
                SELECT * FROM migration_report_events WHERE migrationID = ? AND cycle = ? AND delivery IS NULL
                """, arguments: [migrationID.uuidString, state.cycle]).flatMap(Self.event)
            // Rebuild the per-occurrence history counts after writes.
            var report = built.report
            if opened + closed > 0, let rebuilt = try Self.build(db, migrationID: migrationID, paths: paths, now: now, capacity: capacity) {
                report = rebuilt.report
            }
            let control = built.control
            return MigrationIssueReconciliation(report: report, state: state, pendingEvent: pending, acquisitionLinks: built.links,
                acquisitionBatchPending: control.map { $0.currentBatch > 0 && $0.resolvedBatch != $0.currentBatch } ?? false,
                resolvedBatch: control?.resolvedBatch, batchDelivered: control?.batchOutcome == .delivered, opened: opened, closed: closed)
        }
    }

    private struct Built {
        let report: MigrationIssueReport
        let open: [UUID: [MigrationIssueRow]]
        let control: AcquisitionControlRecord?
        let links: Int
    }

    private static func build(_ db: Database, migrationID: UUID, paths: AppStoragePaths, now: Date, capacity: Int64?) throws -> Built? {
        let id = migrationID.uuidString
        guard let session = try Row.fetchOne(db, sql: """
            SELECT m.destinationPlaylistID, m.sourcePlaylistName, m.expectedEntryCount, m.status, j.intent, s.state AS lifecycle, s.waitUntil
            FROM playlist_migrations m
            LEFT JOIN migration_matching_jobs j ON j.migrationID = m.id
            LEFT JOIN migration_coordinator_state s ON s.migrationID = m.id
            WHERE m.id = ?
            """, arguments: [id]) else { return nil }
        let control = try AcquisitionControlRecord.fetchOne(db, key: id)
        let status = PlaylistMigrationStatus(rawValue: session["status"] as String) ?? .failed
        let intent: String? = session["intent"]
        var context = MigrationIssueContext()
        context.matchingIntent = intent
        context.cancelled = status == .cancelled || intent == "userCancelled"
        context.downloadsPaused = control?.userPaused ?? false
        context.waitUntil = session["waitUntil"]
        context.lifecycle = (session["lifecycle"] as String?).flatMap(MigrationLifecycleState.init(rawValue:))
        context.availableCapacity = capacity
        context.now = now

        let entries = try GRDBPlaylistMigrationRepository.entries(db, migrationID: id)
        let rows = try Row.fetchAll(db, sql: """
            SELECT e.id,
                   c.outcome AS checkpointOutcome, c.retryable AS checkpointRetryable,
                   r.failures AS retryFailures, r.category AS retryCategory, r.eligible AS retryEligible,
                   r.lastAttemptAt AS retryLastAttemptAt, r.nextRetryAt AS retryNextAt,
                   a.state AS linkState, a.failure AS linkFailure, a.retries AS linkRetries,
                   a.nextRetryAt AS linkNextRetryAt, a.updatedAt AS linkUpdatedAt,
                   d.state AS jobState, d.errorMessage AS jobError, d.expected AS jobExpected,
                   (SELECT x.provider FROM migration_candidates x WHERE x.entryID = e.id AND x.decision = 'accepted' LIMIT 1) AS acceptedProvider,
                   (SELECT COUNT(*) FROM migration_candidates x WHERE x.entryID = e.id AND x.decision = 'pending') AS pendingCandidates,
                   (SELECT COUNT(*) FROM migration_candidates x WHERE x.entryID = e.id AND x.decision = 'rejected') AS rejectedCandidates
            FROM migration_entries e
            LEFT JOIN migration_matching_checkpoints c ON c.entryID = e.id
            LEFT JOIN migration_entry_retries r ON r.entryID = e.id
            LEFT JOIN migration_acquisitions a ON a.entryID = e.id
            LEFT JOIN download_jobs d ON d.id = a.downloadJobID
            WHERE e.migrationID = ?
            """, arguments: [id])
        var facts: [String: MigrationOccurrenceFacts] = [:]
        for row in rows {
            var value = MigrationOccurrenceFacts(status: .pending)
            value.checkpointOutcome = row["checkpointOutcome"]
            value.checkpointRetryable = (row["checkpointRetryable"] as Bool?) ?? false
            value.retryFailures = row["retryFailures"]
            value.retryCategory = row["retryCategory"]
            value.retryEligible = (row["retryEligible"] as Bool?) ?? false
            value.retryLastAttemptAt = row["retryLastAttemptAt"]
            value.retryNextAt = row["retryNextAt"]
            value.linkState = (row["linkState"] as String?).flatMap(AcquisitionLinkState.init(rawValue:))
            value.linkFailure = row["linkFailure"]
            value.linkRetries = (row["linkRetries"] as Int?) ?? 0
            value.linkNextRetryAt = row["linkNextRetryAt"]
            value.linkUpdatedAt = row["linkUpdatedAt"]
            value.jobState = (row["jobState"] as String?).flatMap(StoredDownloadState.init(rawValue:))
            value.jobError = row["jobError"]
            value.jobExpectedBytes = row["jobExpected"]
            value.acceptedProvider = row["acceptedProvider"]
            value.pendingCandidates = row["pendingCandidates"]
            value.rejectedCandidates = row["rejectedCandidates"]
            facts[row["id"] as String] = value
        }
        // Bounded file checks: one per distinct associated recording, never per render.
        var available: [String: Bool] = [:]
        for trackID in Set(entries.compactMap(\.localTrackID)) {
            available[trackID] = try StoredTrack.fetchOne(db, key: trackID).map { MigrationLocalAudio.isAvailable($0, paths: paths) } ?? false
        }
        let open = Dictionary(grouping: try Row.fetchAll(db, sql: """
            SELECT * FROM migration_issues WHERE migrationID = ? AND resolution = 'open' AND code IN (\(MigrationIssueSchema.reportCodes))
            """, arguments: [id]).compactMap(issueRow), by: \.entryID)
        let history = Dictionary(uniqueKeysWithValues: try Row.fetchAll(db, sql: """
            SELECT entryID, COUNT(*) AS closed FROM migration_issues
            WHERE migrationID = ? AND resolution != 'open' AND code IN (\(MigrationIssueSchema.reportCodes)) AND entryID IS NOT NULL
            GROUP BY entryID
            """, arguments: [id]).compactMap { row -> (UUID, Int)? in
                guard let entry = UUID(uuidString: row["entryID"] as String) else { return nil }
                return (entry, row["closed"] as Int)
            })
        var occurrences: [MigrationOccurrenceReport] = []
        occurrences.reserveCapacity(entries.count)
        for entry in entries {
            var value = facts[entry.id.uuidString] ?? MigrationOccurrenceFacts(status: entry.status)
            value.status = entry.status
            value.localTrackID = entry.localTrackID
            value.trackAvailable = entry.localTrackID.flatMap { available[$0] } ?? false
            let assessment = MigrationIssueClassifier.assess(value, context: context)
            let candidates = open[entry.id] ?? []
            let current = candidates.first(where: { $0.stage == assessment.stage }) ?? candidates.first
            occurrences.append(MigrationOccurrenceReport(entry: entry, assessment: assessment, pendingCandidates: value.pendingCandidates,
                issueID: current?.id, issueCreatedAt: current?.createdAt, resolvedIssues: history[entry.id] ?? 0))
        }
        let summary = MigrationCompletionSummary.make(migrationID: migrationID, playlistID: session["destinationPlaylistID"],
            playlistName: session["sourcePlaylistName"], expected: session["expectedEntryCount"],
            dispositions: occurrences.map(\.assessment.disposition), context: context)
        let links = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM migration_acquisitions WHERE migrationID = ?", arguments: [id]) ?? 0
        return Built(report: MigrationIssueReport(summary: summary, occurrences: occurrences, context: context), open: open, control: control, links: links)
    }

    /// Keeps one open record per occurrence and stage in line with the assessment.
    private static func reconcileIssues(_ db: Database, migrationID: UUID, occurrence: MigrationOccurrenceReport,
                                        open: [MigrationIssueRow], now: Date) throws -> (opened: Int, closed: Int) {
        let assessment = occurrence.assessment
        var opened = 0, closed = 0
        func close(_ row: MigrationIssueRow, _ reason: MigrationIssueCloseReason) throws {
            try db.execute(sql: """
                UPDATE migration_issues SET resolution = 'resolved', closeReason = ?, resolvedAt = ?, updatedAt = ?
                WHERE id = ? AND resolution = 'open'
                """, arguments: [reason.rawValue, now, now, row.id.uuidString])
            closed += db.changesCount
        }
        switch assessment.disposition {
        case .playable:
            for row in open { try close(row, .conditionCleared) }
        case .skipped:
            for row in open { try close(row, .skipped) }
        case .waiting:
            // Temporary conditions never create records. An existing record stays open
            // while its stage is being retried; moving to a later stage clears it.
            for row in open where row.stage != assessment.stage {
                try close(row, row.stage == .matching ? .conditionCleared : .superseded)
            }
        case .needsReview, .failed:
            guard let stage = assessment.stage, let category = assessment.category else { return (0, 0) }
            for row in open where row.stage != stage {
                // Confirming a recording clears the matching problem; choosing another
                // recording supersedes the abandoned recording's download problem.
                try close(row, row.stage == .matching ? .conditionCleared : .superseded)
            }
            let current = open.first { $0.stage == stage }
            if let current, current.category == category.rawValue {
                let message = assessment.explanation ?? category.explanation
                if current.message != message || current.recoverable != assessment.retryable || current.provenance != assessment.provenance?.rawValue {
                    try db.execute(sql: """
                        UPDATE migration_issues SET message = ?, recoverable = ?, provenance = ?, severity = ?, lastObservedAt = ?, updatedAt = ?
                        WHERE id = ?
                        """, arguments: [message, assessment.retryable, assessment.provenance?.rawValue,
                                         assessment.disposition == .failed ? "blocking" : "warning", now, now, current.id.uuidString])
                }
                return (opened, closed)
            }
            if let current { try close(current, .superseded) }
            let message = assessment.explanation ?? category.explanation
            try MigrationPersistentText.validate([message])
            try db.execute(sql: """
                INSERT INTO migration_issues (id, migrationID, entryID, code, message, technicalDetails, severity, resolution,
                    createdAt, updatedAt, resolvedAt, category, stage, provenance, recoverable, lastObservedAt, closeReason)
                VALUES (?, ?, ?, ?, ?, ?, ?, 'open', ?, ?, NULL, ?, ?, ?, ?, ?, NULL)
                """, arguments: [UUID().uuidString, migrationID.uuidString, occurrence.id.uuidString, stage.code, message,
                                 "Category: " + category.rawValue, assessment.disposition == .failed ? "blocking" : "warning",
                                 now, now, category.rawValue, stage.rawValue, assessment.provenance?.rawValue, assessment.retryable, now])
            opened += 1
        }
        return (opened, closed)
    }

    // MARK: Processing cycles and the notification ledger

    /// A cycle ends when the playlist moves from unsettled (work remaining, paused) to a
    /// settled outcome, or from settled-with-issues to fully ready. The first observation
    /// of a migration that is already settled (e.g. right after upgrading) is a baseline
    /// and never produces a notification.
    private static func advanceCycle(_ db: Database, migrationID: UUID, summary: MigrationCompletionSummary,
                                     control: AcquisitionControlRecord?, now: Date) throws -> MigrationReportState {
        let id = migrationID.uuidString
        let settled = summary.outcome.settled
        let settledAt: Date? = settled ? now : nil
        guard let existing = try state(db, id) else {
            try db.execute(sql: """
                INSERT INTO migration_report_state (migrationID, cycle, settled, outcome, revision, observedBatch, settledAt, presentedCycle, createdAt, updatedAt)
                VALUES (?, 0, ?, ?, ?, ?, ?, 0, ?, ?)
                """, arguments: [id, settled, summary.outcome.rawValue, summary.revision, control?.resolvedBatch, settledAt, now, now])
            return MigrationReportState(cycle: 0, settled: settled, outcome: summary.outcome.rawValue, settledAt: settledAt, presentedCycle: 0)
        }
        let becameReady = existing.settled && settled && summary.outcome == .fullyReady && existing.outcome != MigrationCompletionOutcome.fullyReady.rawValue
        if settled && (!existing.settled || becameReady) {
            let cycle = existing.cycle + 1
            let batchAtSettle = try Int.fetchOne(db, sql: "SELECT observedBatch FROM migration_report_state WHERE migrationID = ?", arguments: [id])
            // Older undelivered events are superseded by the newer cycle (never replayed).
            try db.execute(sql: "UPDATE migration_report_events SET delivery = 'superseded', updatedAt = ? WHERE migrationID = ? AND delivery IS NULL",
                           arguments: [now, id])
            try db.execute(sql: """
                INSERT OR IGNORE INTO migration_report_events (migrationID, cycle, kind, revision, batchAtSettle, delivery, attempts, createdAt, updatedAt)
                VALUES (?, ?, ?, ?, ?, NULL, 0, ?, ?)
                """, arguments: [id, cycle, summary.fullyReady ? MigrationReportEvent.Kind.fullyReady.rawValue : MigrationReportEvent.Kind.needsAttention.rawValue,
                                 summary.revision, batchAtSettle, now, now])
            try db.execute(sql: """
                UPDATE migration_report_state SET cycle = ?, settled = 1, outcome = ?, revision = ?, settledAt = ?, updatedAt = ? WHERE migrationID = ?
                """, arguments: [cycle, summary.outcome.rawValue, summary.revision, now, now, id])
            return MigrationReportState(cycle: cycle, settled: true, outcome: summary.outcome.rawValue, settledAt: now, presentedCycle: existing.presentedCycle)
        }
        if !settled {
            if existing.settled || existing.outcome != summary.outcome.rawValue {
                try db.execute(sql: "UPDATE migration_report_state SET settled = 0, outcome = ?, revision = ?, updatedAt = ? WHERE migrationID = ?",
                               arguments: [summary.outcome.rawValue, summary.revision, now, id])
            }
            // Remember the last confirmed-download batch resolved before settling, to tell
            // whether the final batch notification already covered this cycle.
            if let resolved = control?.resolvedBatch,
               try Int.fetchOne(db, sql: "SELECT observedBatch FROM migration_report_state WHERE migrationID = ?", arguments: [id]) != resolved {
                try db.execute(sql: "UPDATE migration_report_state SET observedBatch = ? WHERE migrationID = ?", arguments: [resolved, id])
            }
            return MigrationReportState(cycle: existing.cycle, settled: false, outcome: summary.outcome.rawValue, settledAt: existing.settledAt,
                                        presentedCycle: existing.presentedCycle)
        }
        if existing.outcome != summary.outcome.rawValue {
            try db.execute(sql: "UPDATE migration_report_state SET outcome = ?, revision = ?, updatedAt = ? WHERE migrationID = ?",
                           arguments: [summary.outcome.rawValue, summary.revision, now, id])
        }
        var value = existing; value.outcome = summary.outcome.rawValue
        return value
    }

    /// Records a delivery outcome. A transient failure only counts an attempt; after the
    /// bound it is recorded as abandoned so it is never retried in a loop.
    @discardableResult
    func recordDelivery(migrationID: UUID, cycle: Int, outcome: MigrationReportEvent.Delivery?, now: Date) async throws -> MigrationReportEvent.Delivery? {
        try await db.write { db in
            guard let row = try Row.fetchOne(db, sql: "SELECT attempts, delivery FROM migration_report_events WHERE migrationID = ? AND cycle = ?",
                                             arguments: [migrationID.uuidString, cycle]),
                  (row["delivery"] as String?) == nil else { return nil }
            let attempts = (row["attempts"] as Int) + 1
            var final = outcome
            if final == nil && attempts >= Self.maximumDeliveryAttempts { final = .abandoned }
            // Coalescing is a decision, not a delivery attempt.
            let counted = outcome == .coalesced ? attempts - 1 : attempts
            let deliveredAt: Date? = final == .delivered ? now : nil
            try db.execute(sql: """
                UPDATE migration_report_events SET delivery = ?, attempts = ?, lastAttemptAt = ?, deliveredAt = ?, updatedAt = ?
                WHERE migrationID = ? AND cycle = ? AND delivery IS NULL
                """, arguments: [final?.rawValue, counted, now, deliveredAt, now, migrationID.uuidString, cycle])
            return final
        }
    }

    /// The user dismissed the in-app completion summary for this cycle. Only the
    /// presentation flag changes: issues, retry state and lifecycle are untouched.
    func markPresented(migrationID: UUID, cycle: Int) async throws {
        try await db.write { db in
            try db.execute(sql: "UPDATE migration_report_state SET presentedCycle = MAX(presentedCycle, ?), updatedAt = ? WHERE migrationID = ?",
                           arguments: [cycle, Date(), migrationID.uuidString])
        }
    }

    // MARK: User transitions

    /// Skip Song: an explicit, durable per-occurrence decision. Stops scheduling for this
    /// occurrence only. An accepted recording is kept as evidence (returned to `pending`,
    /// marked superseded) so restoring never inherits a stale download; shared downloads
    /// and library tracks are never touched here — acquisition consumer accounting
    /// decides which jobs other playlists still need.
    func skip(entryID: UUID, migrationID: UUID, now: Date) async throws {
        try await db.write { db in
            guard var entry = try MigrationEntryRecord.fetchOne(db, key: entryID.uuidString), entry.migrationID == migrationID.uuidString else {
                throw PlaylistMigrationStorageError.notFound
            }
            if entry.status == .skipped { return }
            guard entry.localTrackID == nil, entry.status != .matching, entry.status != .ready else { throw SongMatchingError.staleAttempt }
            try PlaylistMigrationValidation.requireEntryTransition(entry.status, to: .skipped)
            try db.execute(sql: """
                UPDATE migration_candidates SET decision = 'pending', updatedAt = ?,
                    evidence = json_set(evidence, '$.supersededBy', 'skip', '$.currentAttempt', 'false')
                WHERE entryID = ? AND decision = 'accepted'
                """, arguments: [now, entry.id])
            entry.status = .skipped; entry.updatedAt = max(now, entry.updatedAt.addingTimeInterval(0.01)); try entry.update(db)
            _ = try EntryRetryRecord.deleteOne(db, key: entry.id)
            try db.execute(sql: """
                UPDATE migration_issues SET resolution = 'resolved', closeReason = 'skipped', resolvedAt = ?, updatedAt = ?
                WHERE entryID = ? AND resolution = 'open' AND code IN (\(MigrationIssueSchema.reportCodes))
                """, arguments: [now, now, entry.id])
            try Self.audit(db, migrationID: migrationID, entryID: entryID, code: "user.skip", message: "Skipped by you.", now: now)
        }
    }

    /// Restore Song (undo Skip): returns the occurrence to review when suggestions exist,
    /// otherwise to unfinished matching. Rejected candidates stay rejected.
    func restore(entryID: UUID, migrationID: UUID, now: Date) async throws {
        try await db.write { db in
            guard var entry = try MigrationEntryRecord.fetchOne(db, key: entryID.uuidString), entry.migrationID == migrationID.uuidString else {
                throw PlaylistMigrationStorageError.notFound
            }
            guard entry.status == .skipped else { throw SongMatchingError.staleAttempt }
            let pending = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM migration_candidates WHERE entryID = ? AND decision = 'pending'", arguments: [entry.id]) ?? 0
            let next: PlaylistMigrationEntryStatus = pending > 0 ? .needsReview : .pending
            try PlaylistMigrationValidation.requireEntryTransition(entry.status, to: next)
            entry.status = next; entry.updatedAt = max(now, entry.updatedAt.addingTimeInterval(0.01)); try entry.update(db)
            try Self.audit(db, migrationID: migrationID, entryID: entryID, code: "user.restore", message: "Restored by you.", now: now)
        }
    }

    /// Before re-associating an occurrence whose verified audio disappeared: a `ready`
    /// occurrence whose file is gone, or an `unavailable` one still holding the accepted
    /// local decision, returns to review so the existing association paths (library
    /// recording, Files import, search) accept it. Refuses while the audio is still valid.
    /// The old decision is kept as evidence, never deleted.
    func releaseMissingLocalAudio(entryID: UUID, migrationID: UUID, now: Date) async throws {
        try await db.write { [paths] db in
            guard var entry = try MigrationEntryRecord.fetchOne(db, key: entryID.uuidString), entry.migrationID == migrationID.uuidString else {
                throw PlaylistMigrationStorageError.notFound
            }
            if let trackID = entry.localTrackID,
               try StoredTrack.fetchOne(db, key: trackID).map({ MigrationLocalAudio.isAvailable($0, paths: paths) }) == true {
                throw SongMatchingError.staleAttempt // Valid audio is never released.
            }
            let acceptedLocal = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM migration_candidates WHERE entryID = ? AND decision = 'accepted' AND provider = 'local'",
                                                 arguments: [entry.id]) ?? 0
            guard entry.status == .ready || (entry.status == .unavailable && acceptedLocal > 0) else { return }
            try db.execute(sql: """
                UPDATE migration_candidates SET decision = 'pending', updatedAt = ?,
                    evidence = json_set(evidence, '$.supersededBy', 'missing-audio', '$.currentAttempt', 'false')
                WHERE entryID = ? AND decision = 'accepted' AND provider = 'local'
                """, arguments: [now, entry.id])
            try PlaylistMigrationValidation.requireEntryTransition(entry.status, to: .needsReview)
            entry.status = .needsReview; entry.localTrackID = nil
            entry.updatedAt = max(now, entry.updatedAt.addingTimeInterval(0.01)); try entry.update(db)
            _ = try MatchingCheckpoint.deleteOne(db, key: entry.id)
        }
    }

    /// Durable, closed audit record of an explicit user action.
    private static func audit(_ db: Database, migrationID: UUID, entryID: UUID, code: String, message: String, now: Date) throws {
        try db.execute(sql: """
            INSERT INTO migration_issues (id, migrationID, entryID, code, message, technicalDetails, severity, resolution,
                createdAt, updatedAt, resolvedAt, closeReason)
            VALUES (?, ?, ?, ?, ?, NULL, 'information', 'resolved', ?, ?, ?, 'userAction')
            """, arguments: [UUID().uuidString, migrationID.uuidString, entryID.uuidString, code, message, now, now, now])
    }

    // MARK: Row mapping

    private static func state(_ db: Database, _ id: String) throws -> MigrationReportState? {
        try Row.fetchOne(db, sql: "SELECT * FROM migration_report_state WHERE migrationID = ?", arguments: [id]).map { row in
            MigrationReportState(cycle: row["cycle"], settled: row["settled"], outcome: row["outcome"], settledAt: row["settledAt"],
                                 presentedCycle: row["presentedCycle"])
        }
    }

    private static func event(_ row: Row) -> MigrationReportEvent? {
        guard let id = UUID(uuidString: row["migrationID"] as String), let kind = MigrationReportEvent.Kind(rawValue: row["kind"] as String) else { return nil }
        return MigrationReportEvent(migrationID: id, cycle: row["cycle"], kind: kind, revision: row["revision"], batchAtSettle: row["batchAtSettle"],
                                    delivery: (row["delivery"] as String?).flatMap(MigrationReportEvent.Delivery.init(rawValue:)),
                                    attempts: row["attempts"], lastAttemptAt: row["lastAttemptAt"], createdAt: row["createdAt"])
    }

    private static func issueRow(_ row: Row) -> MigrationIssueRow? {
        guard let id = UUID(uuidString: row["id"] as String), let migration = UUID(uuidString: row["migrationID"] as String),
              let entry = (row["entryID"] as String?).flatMap(UUID.init(uuidString:)),
              let stage = MigrationIssueStage(code: row["code"] as String),
              let resolution = PlaylistMigrationIssueResolution(rawValue: row["resolution"] as String) else { return nil }
        return MigrationIssueRow(id: id, migrationID: migration, entryID: entry, stage: stage, category: row["category"], provenance: row["provenance"],
                                 message: row["message"], resolution: resolution, closeReason: row["closeReason"], recoverable: row["recoverable"],
                                 createdAt: row["createdAt"], updatedAt: row["updatedAt"], resolvedAt: row["resolvedAt"], lastObservedAt: row["lastObservedAt"])
    }
}
