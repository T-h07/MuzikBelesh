import Foundation
import GRDB

final class GRDBPlaylistMigrationRepository: PlaylistMigrationStatePersisting, PlaylistImportPersisting {
    let db: DatabaseQueue
    let paths: AppStoragePaths
    init(db: DatabaseQueue, paths: AppStoragePaths) { self.db = db; self.paths = paths }

    func createPlaylist(from source: PlaylistMigrationSourcePlaylist, operationID: String) async throws -> PlaylistMigrationSession {
        try createCommittedPlaylist(from: source, operationID: operationID)
    }

    func createPlaylist(from source: PlaylistMigrationSourcePlaylist, operationID: String, destinationName: String) async throws -> PlaylistMigrationSession {
        try createCommittedPlaylist(from: source, operationID: operationID, destinationName: destinationName)
    }

    func importSessions() async throws -> [PlaylistMigrationSession] {
        try await db.read { try Self.sessions($0) }
    }

    /// One IMMEDIATE GRDB write transaction owns the idempotency check and every insert.
    /// No observer can see importingMetadata or a partially populated playlist.
    func createCommittedPlaylist(from source: PlaylistMigrationSourcePlaylist, operationID: String, destinationName: String? = nil) throws -> PlaylistMigrationSession {
        try Task.checkCancellation()
        try PlaylistMigrationValidation.validate(source)
        let operation = operationID.trimmingCharacters(in: .whitespacesAndNewlines).precomposedStringWithCanonicalMapping
        guard !operation.isEmpty, operation.count <= 200,
              operation.rangeOfCharacter(from: .controlCharacters) == nil else { throw PlaylistMigrationStorageError.invalidOperationID }
        let fingerprint = try PlaylistMigrationValidation.importFingerprint(for: source)
        let displayName = try LibraryIdentity.validatedName(destinationName ?? source.name)
        return try db.write { db in
            if let existing = try MigrationSessionRecord.fetchOne(db, sql: "SELECT * FROM playlist_migrations WHERE operationID = ?", arguments: [operation]) {
                guard existing.importFingerprint == fingerprint else { throw PlaylistMigrationStorageError.operationConflict }
                try Self.verify(existing, db: db)
                return try existing.model()
            }
            if PlaylistImportIdentity.parts(source.sourceReference) != nil,
               PlaylistImportIdentity.status(source: source, operation: operation, sessions: try Self.sessions(db)) == .ambiguous {
                throw PlaylistImportProblem(location: "Import identity", reason: PlaylistImportDuplicate.ambiguous.message)
            }
            let now = Date(), id = UUID().uuidString, playlistID = UUID().uuidString
            try StoredPlaylist(id: playlistID, name: displayName, description: nil, artworkRelativePath: nil, dateAdded: now, dateModified: now).insert(db)
            var session = MigrationSessionRecord(id: id, destinationPlaylistID: playlistID, operationID: operation, source: source.source.rawValue, sourcePlaylistID: source.sourcePlaylistID, sourceReference: source.sourceReference, sourcePlaylistName: source.name, importFingerprint: fingerprint, expectedEntryCount: source.entries.count, status: .importingMetadata, createdAt: now, updatedAt: now, failureInformation: nil)
            try session.insert(db)
            for sourceEntry in source.entries {
                try Task.checkCancellation()
                try MigrationEntryRecord(source: sourceEntry, migrationID: id, now: now).insert(db)
            }
            try Self.verify(session, db: db)
            try PlaylistMigrationValidation.requireSessionTransition(session.status, to: .metadataReady)
            session.status = .metadataReady
            try session.update(db)
            // Return SQLite's canonical timestamp precision, also used by retries.
            guard let committed = try MigrationSessionRecord.fetchOne(db, key: id) else { throw PlaylistMigrationStorageError.corruptMetadata }
            return try committed.model()
        }
    }

    static func verify(_ session: MigrationSessionRecord, db: Database) throws {
        let positions = try Int.fetchAll(db, sql: "SELECT sourcePosition FROM migration_entries WHERE migrationID = ? ORDER BY sourcePosition", arguments: [session.id])
        guard positions == Array(0..<session.expectedEntryCount),
              try StoredPlaylist.fetchOne(db, key: session.destinationPlaylistID) != nil else { throw PlaylistMigrationStorageError.corruptMetadata }
    }
    private static func requiredSession(_ id: UUID, db: Database) throws -> MigrationSessionRecord {
        guard let value = try MigrationSessionRecord.fetchOne(db, key: id.uuidString) else { throw PlaylistMigrationStorageError.notFound }; return value
    }
    private static func requiredEntry(_ id: UUID, db: Database) throws -> MigrationEntryRecord {
        guard let value = try MigrationEntryRecord.fetchOne(db, key: id.uuidString) else { throw PlaylistMigrationStorageError.notFound }; return value
    }
    func session(id: UUID) async throws -> PlaylistMigrationSession? { try await db.read { try MigrationSessionRecord.fetchOne($0, key: id.uuidString)?.model() } }
    func entries(migrationID: UUID) async throws -> [PlaylistMigrationEntry] {
        try await db.read { db in
            _ = try Self.requiredSession(migrationID, db: db)
            return try Self.entries(db, migrationID: migrationID.uuidString)
        }
    }
    static func entries(_ db: Database, migrationID: String? = nil) throws -> [PlaylistMigrationEntry] {
        try MigrationEntryRecord.fetchAll(db, sql: "SELECT * FROM migration_entries WHERE (? IS NULL OR migrationID = ?) ORDER BY migrationID, sourcePosition", arguments: [migrationID, migrationID]).map { try $0.model() }
    }
    static func sessions(_ db: Database) throws -> [PlaylistMigrationSession] {
        try MigrationSessionRecord.order(Column("createdAt"), Column("id")).fetchAll(db).map { try $0.model() }
    }
    /// Snapshot-only read access; the database row type remains private to this repository.
    static func issues(_ db: Database) throws -> [PlaylistMigrationIssue] {
        try MigrationIssueRecord.order(Column("createdAt"), Column("id")).fetchAll(db).map { try $0.model() }
    }
    func incompleteSessions() async throws -> [PlaylistMigrationSession] {
        try recover()
        return try await db.read { db in
            try Self.sessions(db).filter { session in
                let entries = try Self.entries(db, migrationID: session.id.uuidString)
                return !session.status.isTerminal || entries.contains { $0.status != .ready }
            }
        }
    }
    func updateStatus(migrationID: UUID, to status: PlaylistMigrationStatus, failureInformation: String? = nil) async throws {
        try MigrationPersistentText.validate([failureInformation])
        try await db.write { [self] db in
            var record = try Self.requiredSession(migrationID, db: db)
            try PlaylistMigrationValidation.requireSessionTransition(record.status, to: status)
            try Self.verify(record, db: db)
            if status == .completed {
                let rows = try Self.rows(db, playlistID: record.destinationPlaylistID, paths: paths)
                guard rows.allSatisfy({ $0.playableTrack != nil }) else { throw PlaylistMigrationStorageError.invalidLocalTrack }
            }
            record.status = status; record.updatedAt = Date(); record.failureInformation = failureInformation
            try record.update(db)
        }
    }
    func updateEntryStatus(entryID: UUID, to status: PlaylistMigrationEntryStatus) async throws {
        try await db.write { [self] db in
            var record = try Self.requiredEntry(entryID, db: db)
            try PlaylistMigrationValidation.requireEntryTransition(record.status, to: status)
            // Only associateVerifiedTrack may establish ready, after audio inspection.
            if status == .ready {
                guard record.status == .ready, let id = record.localTrackID,
                      let track = try StoredTrack.fetchOne(db, key: id), MigrationLocalAudio.isAvailable(track, paths: paths) else { throw PlaylistMigrationStorageError.invalidLocalTrack }
            }
            record.status = status; record.updatedAt = Date()
            if status != .ready { record.localTrackID = nil }
            try record.update(db)
        }
    }
    func associateVerifiedTrack(entryID: UUID, trackID: String) async throws {
        let track = try await verifiedMatchingAudio(trackID: trackID)
        try await db.write { [self] db in
            try validateMatchingAudio(track, db: db)
            var record = try Self.requiredEntry(entryID, db: db)
            try PlaylistMigrationValidation.requireEntryTransition(record.status, to: .ready)
            record.localTrackID = trackID; record.status = .ready; record.updatedAt = Date()
            try record.update(db)
        }
    }
    /// Shared by legacy association and atomic matching acceptance. Decoding and
    /// SHA-256 hashing stay outside the write transaction and off the main actor.
    private func verifiedMatchingAudio(trackID: String) async throws -> StoredTrack {
        guard let track = try await db.read({ try StoredTrack.fetchOne($0, key: trackID) }), MigrationLocalAudio.isAvailable(track, paths: paths) else { throw PlaylistMigrationStorageError.invalidLocalTrack }
        let url = try paths.musicURL(relativePath: track.fileRelativePath)
        let audio = AudioFileService()
        do {
            _ = try await audio.validate(url)
            guard try audio.sha256(url: url) == track.contentSHA256 else { throw PlaylistMigrationStorageError.invalidLocalTrack }
        } catch {
            if Task.isCancelled || error is CancellationError { throw CancellationError() }
            throw PlaylistMigrationStorageError.invalidLocalTrack
        }
        return track
    }
    private func validateMatchingAudio(_ track: StoredTrack, db: Database) throws {
            guard let current = try StoredTrack.fetchOne(db, key: track.id), current == track,
                  MigrationLocalAudio.isAvailable(current, paths: paths),
                  try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM library_file_operations WHERE kind = 'delete-track' AND ownerID = ?", arguments: [track.id]) == 0 else { throw PlaylistMigrationStorageError.invalidLocalTrack }
    }
    func removeLocalAssociation(entryID: UUID) async throws {
        try await db.write { db in
            var record = try Self.requiredEntry(entryID, db: db)
            if record.status == .ready {
                try PlaylistMigrationValidation.requireEntryTransition(record.status, to: .unavailable)
                record.status = .unavailable
            }
            record.localTrackID = nil; record.updatedAt = Date(); try record.update(db)
        }
    }

    /// Does not resume workers or reset completed/cancelled sessions. Their effective
    /// progress can regress when audio disappears, without rewriting lifecycle history.
    func recover() throws {
        try db.write { [self] db in
            for session in try MigrationSessionRecord.fetchAll(db) { try Self.verify(session, db: db) }
            var availability: [String: Bool] = [:]
            for var entry in try MigrationEntryRecord.fetchAll(db) where entry.localTrackID != nil || entry.status == .ready {
                let valid: Bool
                if let id = entry.localTrackID {
                    if let cached = availability[id] { valid = cached }
                    else {
                        valid = try StoredTrack.fetchOne(db, key: id).map { MigrationLocalAudio.isAvailable($0, paths: paths) } ?? false
                        availability[id] = valid
                    }
                } else { valid = false }
                if !valid {
                    if entry.status == .ready {
                        try PlaylistMigrationValidation.requireEntryTransition(entry.status, to: .unavailable)
                        entry.status = .unavailable
                    }
                    entry.localTrackID = nil; entry.updatedAt = Date(); try entry.update(db)
                }
            }
        }
    }
    static func rows(_ db: Database, playlistID: String, paths: AppStoragePaths) throws -> [MigrationPlaylistRow] {
        guard let session = try MigrationSessionRecord.fetchOne(db, sql: "SELECT * FROM playlist_migrations WHERE destinationPlaylistID = ?", arguments: [playlistID]) else { return [] }
        let entries = try Self.entries(db, migrationID: session.id)
        var local: [String: StoredTrack] = [:]
        for id in Set(entries.compactMap(\.localTrackID)) {
            if let track = try StoredTrack.fetchOne(db, key: id), MigrationLocalAudio.isAvailable(track, paths: paths) { local[id] = track }
        }
        return entries.map { MigrationPlaylistRow(entry: $0, playableTrack: $0.status == .ready ? $0.localTrackID.flatMap { local[$0] } : nil) }
    }
    func rows(playlistID: String) throws -> [MigrationPlaylistRow] { try db.read { try Self.rows($0, playlistID: playlistID, paths: paths) } }
    func progress(migrationID: UUID) async throws -> PlaylistMigrationProgress {
        try await db.read { [self] db in
            let session = try Self.requiredSession(migrationID, db: db)
            try Self.verify(session, db: db)
            let rows = try Self.rows(db, playlistID: session.destinationPlaylistID, paths: paths)
            return PlaylistMigrationProgress(expected: session.expectedEntryCount, states: rows.map(\.effectiveStatus), metadataCommitted: true)
        }
    }

    func candidates(entryID: UUID) async throws -> [PlaylistMigrationCandidate] {
        try await db.read { db in
            _ = try Self.requiredEntry(entryID, db: db)
            return try MigrationCandidateRecord.filter(Column("entryID") == entryID.uuidString).order(Column("createdAt"), Column("id")).fetchAll(db).map { try $0.model() }
        }
    }
    func saveCandidate(_ value: PlaylistMigrationCandidate) async throws {
        guard !value.provider.isEmpty, !value.title.isEmpty, value.confidence.map({ $0.isFinite && (0...1).contains($0) }) ?? true,
              value.durationMs.map({ $0 >= 0 }) ?? true else { throw PlaylistMigrationStorageError.invalidCandidate }
        try MigrationPersistentText.validate([value.provider, value.providerTrackID, value.title, value.artist] + value.evidence.flatMap { [$0.key, $0.value] })
        try await db.write { db in
            _ = try Self.requiredEntry(value.entryID, db: db)
            let old = try MigrationCandidateRecord.fetchOne(db, key: value.id.uuidString)
            guard old == nil || old?.entryID == value.entryID.uuidString else { throw PlaylistMigrationStorageError.invalidCandidate }
            try MigrationCandidateRecord(value, createdAt: old?.createdAt ?? Date()).save(db)
        }
    }
    func updateCandidate(id: UUID, decision: PlaylistMigrationCandidateDecision) async throws {
        try await db.write { db in
            guard var value = try MigrationCandidateRecord.fetchOne(db, key: id.uuidString) else { throw PlaylistMigrationStorageError.notFound }
            value.decision = decision; value.updatedAt = Date(); try value.update(db)
            try MatchingCheckpoint.deleteOne(db, key: value.entryID)
        }
    }
    func issues(migrationID: UUID) async throws -> [PlaylistMigrationIssue] {
        try await db.read { db in
            _ = try Self.requiredSession(migrationID, db: db)
            return try MigrationIssueRecord.filter(Column("migrationID") == migrationID.uuidString).order(Column("createdAt"), Column("id")).fetchAll(db).map { try $0.model() }
        }
    }
    func saveIssue(_ value: PlaylistMigrationIssue) async throws {
        try MigrationPersistentText.validate([value.code, value.message, value.technicalDetails])
        try await db.write { db in
            _ = try Self.requiredSession(value.migrationID, db: db)
            if let id = value.entryID {
                guard try Self.requiredEntry(id, db: db).migrationID == value.migrationID.uuidString else { throw PlaylistMigrationStorageError.invalidCandidate }
            }
            if let old = try MigrationIssueRecord.fetchOne(db, key: value.id.uuidString) {
                guard old.migrationID == value.migrationID.uuidString, old.entryID == value.entryID?.uuidString else { throw PlaylistMigrationStorageError.invalidCandidate }
            }
            try MigrationIssueRecord(value).save(db)
        }
    }
    func resolveIssue(id: UUID, resolution: PlaylistMigrationIssueResolution) async throws {
        try await db.write { db in
            guard var value = try MigrationIssueRecord.fetchOne(db, key: id.uuidString) else { throw PlaylistMigrationStorageError.notFound }
            value.resolution = resolution; value.updatedAt = Date(); value.resolvedAt = resolution == .open ? nil : value.updatedAt
            try value.update(db)
        }
    }
    /// Session ownership includes its destination. Delete the destination to cascade
    /// metadata; tracks and ordinary playlists are never owned by this operation.
    func deleteSession(id: UUID) async throws {
        try await db.write { db in
            let session = try Self.requiredSession(id, db: db)
            _ = try StoredPlaylist.deleteOne(db, key: session.destinationPlaylistID)
        }
    }
}

/// Optimistic ownership uses existing canonical timestamps plus full candidate
/// snapshots. No schema change or reinterpretation of older candidate records.
struct MatchingSessionLease: Sendable {
    let id: UUID
    let revision: Date
}
struct MatchingEntryLease: Sendable {
    let session: MatchingSessionLease
    let entry: PlaylistMigrationEntry
    let previousCandidates: [PlaylistMigrationCandidate]
}

extension GRDBPlaylistMigrationRepository {
    /// Explicit resolution is different from adding an independent playlist item.
    /// The user has inspected both sets of metadata and acknowledged uncertainty.
    func confirmLocalRecording(for expected: PlaylistMigrationEntry, trackID: String) async throws {
        let track = try await verifiedMatchingAudio(trackID: trackID)
        try await db.write { [self] db in
            var entry = try Self.requiredEntry(expected.id, db: db)
            guard try entry.model() == expected, entry.localTrackID == nil,
                  [.pending, .matching, .needsReview, .failed, .unavailable].contains(entry.status) else { throw SongMatchingError.staleAttempt }
            try validateMatchingAudio(track, db: db)
            let previous = try Self.matchingCandidates(expected.id, db: db)
            guard !previous.contains(where: { $0.decision == .accepted }),
                  !previous.contains(where: { $0.provider == "local" && $0.providerTrackID == trackID && $0.decision == .rejected }) else { throw PlaylistMigrationStorageError.invalidCandidate }
            if entry.status != .matching {
                try PlaylistMigrationValidation.requireEntryTransition(entry.status, to: .matching); entry.status = .matching
            }
            try PlaylistMigrationValidation.requireEntryTransition(entry.status, to: .ready)
            let artist = try track.artistID.flatMap { try StoredArtist.fetchOne(db, key: $0)?.name }
            guard [track.title, artist ?? ""].allSatisfy({ MatchingSafeText.metadata($0) == $0 }) else { throw PlaylistMigrationStorageError.unsafeDiagnostics }
            let old = previous.first { $0.provider == "local" && $0.providerTrackID == trackID }
            let candidate = PlaylistMigrationCandidate(id: old?.id ?? UUID(), entryID: expected.id, provider: "local", providerTrackID: trackID,
                title: track.title, artist: artist, durationMs: track.durationMs, confidence: nil,
                evidence: ["matchingAlgorithmVersion": "manual-10.4", "sourceOccurrenceID": entry.id, "acceptance": "Explicit user confirmation after metadata inspection",
                    "selectionExplanation": "The user confirmed this recording. Managed audio decoding and SHA-256 verification passed.",
                    "confidenceClassification": "User confirmed; no automatic identity claim", "currentAttempt": "true", "rank": "1"], decision: .accepted)
            try MigrationCandidateRecord(candidate, createdAt: Date()).save(db)
            entry.status = .ready; entry.localTrackID = trackID; entry.updatedAt = Self.nextMatchingRevision(entry.updatedAt); try entry.update(db)
            try MatchingCheckpoint(entryID: entry.id, algorithm: CandidateScoringEngine.algorithmVersion, retryable: false, outcome: "local", updatedAt: Date()).save(db)
        }
    }
    private static func nextMatchingRevision(_ old: Date) -> Date { max(Date(), old.addingTimeInterval(0.01)) }
    private static func matchingCandidates(_ id: UUID, db: Database) throws -> [PlaylistMigrationCandidate] {
        try MigrationCandidateRecord.filter(Column("entryID") == id.uuidString).order(Column("id")).fetchAll(db).map { try $0.model() }
    }
    private static func requireMatchingSession(_ lease: MatchingSessionLease, db: Database) throws -> MigrationSessionRecord {
        let record = try requiredSession(lease.id, db: db)
        guard record.status == .matching, record.updatedAt == lease.revision else { throw SongMatchingError.staleAttempt }
        return record
    }
    private static func requireMatchingEntry(_ lease: MatchingEntryLease, db: Database) throws -> MigrationEntryRecord {
        _ = try requireMatchingSession(lease.session, db: db)
        let record = try requiredEntry(lease.entry.id, db: db)
        guard try record.model() == lease.entry,
              try matchingCandidates(lease.entry.id, db: db) == lease.previousCandidates,
              record.status == .matching, record.localTrackID == nil else { throw SongMatchingError.staleAttempt }
        return record
    }
    func beginMatching(migrationID: UUID) async throws -> MatchingSessionLease {
        try Task.checkCancellation()
        return try await db.write { db in
            var session = try Self.requiredSession(migrationID, db: db)
            guard [.metadataReady, .matching, .awaitingReview, .partiallyCompleted, .paused, .failed].contains(session.status) else { throw SongMatchingError.staleAttempt }
            try Self.verify(session, db: db)
            try PlaylistMigrationValidation.requireSessionTransition(session.status, to: .matching)
            session.status = .matching; session.updatedAt = Self.nextMatchingRevision(session.updatedAt)
            session.failureInformation = nil; try session.update(db)
            let canonical = try Self.requiredSession(migrationID, db: db)
            return MatchingSessionLease(id: migrationID, revision: canonical.updatedAt)
        }
    }
    /// Eligibility. Ordinary resume (`retryFailed == false`) claims only unfinished
    /// work: never-searched/in-flight occurrences, provider-deferred searches, and
    /// occurrences whose checkpoint was cleared (e.g. after a rejection) or predates the
    /// current algorithm. Failed searches are retried only on explicit request.
    func claimMatchingEntry(_ entry: PlaylistMigrationEntry, session: MatchingSessionLease, retryFailed: Bool = true) async throws -> MatchingEntryLease? {
        try Task.checkCancellation()
        return try await db.write { db in
            _ = try Self.requireMatchingSession(session, db: db)
            var current = try Self.requiredEntry(entry.id, db: db)
            guard current.migrationID == session.id.uuidString, try current.model() == entry,
                  current.localTrackID == nil, [.pending, .matching, .needsReview, .unavailable, .failed].contains(current.status) else { return nil }
            let candidates = try Self.matchingCandidates(entry.id, db: db)
            guard !candidates.contains(where: { $0.decision == .accepted }) else { return nil }
            let checkpoint = try MatchingCheckpoint.fetchOne(db, key: entry.id.uuidString)
            if let checkpoint, checkpoint.algorithm == CandidateScoringEngine.algorithmVersion, !checkpoint.retryable,
               [.needsReview, .unavailable].contains(current.status) { return nil }
            if !retryFailed, ![.pending, .matching].contains(current.status), let checkpoint,
               checkpoint.algorithm == CandidateScoringEngine.algorithmVersion, checkpoint.outcome != "discoveryDeferred" {
                return nil // Completed or failed: not part of an ordinary resume.
            }
            try PlaylistMigrationValidation.requireEntryTransition(current.status, to: .matching)
            current.status = .matching; current.updatedAt = Self.nextMatchingRevision(current.updatedAt); try current.update(db)
            return try MatchingEntryLease(session: session, entry: Self.requiredEntry(entry.id, db: db).model(), previousCandidates: candidates)
        }
    }
    /// All candidates, their evidence, the decision and the entry state commit together.
    func commitMatching(_ lease: MatchingEntryLease, decision: SongMatchDecision,
                        local: MatchingLocalRecording? = nil, librarySnapshot: MatchingLibrarySnapshot? = nil, issue: String? = nil,
                        discoveryFailed: Bool = false, deferred: Bool = false) async throws {
        try Task.checkCancellation()
        var verified: StoredTrack?
        if decision.outcome == .local {
            guard let local, let top = decision.ranked.first, top.recording == local.recording,
                  top.gates.isEmpty else { throw PlaylistMigrationStorageError.invalidCandidate }
            verified = try await verifiedMatchingAudio(trackID: local.track.id)
            guard verified == local.track else { throw SongMatchingError.staleAttempt }
        } else if local != nil { throw PlaylistMigrationStorageError.invalidCandidate }
        try Task.checkCancellation()
        let verifiedTrack = verified
        try await db.write { [self] db in
            try Task.checkCancellation()
            var entry = try Self.requireMatchingEntry(lease, db: db)
            if let selected = decision.ranked.first, decision.outcome == .local {
                guard !lease.previousCandidates.contains(where: {
                    $0.provider == selected.recording.provider && $0.providerTrackID == selected.recording.identity && $0.decision == .rejected
                }) else { throw SongMatchingError.staleAttempt }
            }
            if let verifiedTrack, let local {
                // A new/edited competitor invalidates uniqueness established by the
                // shared index. This check and acceptance share the write transaction.
                guard let librarySnapshot, try librarySnapshot.unchanged(in: db) else { throw SongMatchingError.staleAttempt }
                try validateMatchingAudio(verifiedTrack, db: db)
                let artist = try verifiedTrack.artistID.flatMap { try StoredArtist.fetchOne(db, key: $0)?.name }
                let album = try verifiedTrack.albumID.flatMap { try StoredAlbum.fetchOne(db, key: $0)?.title }
                guard artist == local.recording.artist, album == local.recording.album else { throw SongMatchingError.staleAttempt }
            }
            // Retain old evidence, but distinguish historical proposals from this attempt.
            for old in lease.previousCandidates where old.decision == .pending {
                var stored = try MigrationCandidateRecord(old, createdAt: Date())
                if let existing = try MigrationCandidateRecord.fetchOne(db, key: old.id.uuidString) { stored.createdAt = existing.createdAt }
                var evidence = old.evidence; evidence["currentAttempt"] = "false"
                stored.evidence = try migrationJSON(evidence); try stored.update(db)
            }
            var identities = Set<String>()
            for (index, score) in decision.ranked.prefix(40).enumerated() {
                let item = score.recording
                guard identities.insert(item.provider + ":" + item.identity).inserted else { continue }
                let old = lease.previousCandidates.first { $0.provider == item.provider && $0.providerTrackID == item.identity }
                // Explicit decisions are immutable to discovery, including rejected rows.
                if let old, old.decision != .pending { continue }
                var evidence = score.evidence
                evidence.removeValue(forKey: "thumbnailURL")
                evidence["selectionExplanation"] = decision.explanation
                evidence["topCandidateMargin"] = String(decision.margin)
                evidence["evaluatedAt"] = ISO8601DateFormatter().string(from: Date())
                evidence["sourceOccurrenceID"] = entry.id
                evidence["outcome"] = decision.outcome.rawValue
                evidence["rank"] = String(index + 1)
                evidence["currentAttempt"] = "true"
                evidence["acceptance"] = index == 0 && verifiedTrack != nil ? "Automatic verified local association" : "Pending review"
                if let channel = item.channel { evidence["channel"] = channel }
                if let source = item.discoverySource, item.provider == "youtube" { evidence["discoveryProvider"] = String(source.prefix(60)) }
                if let thumbnail = MatchingCandidateArtwork.safe(item.thumbnailURL) { evidence["thumbnailURL"] = thumbnail.absoluteString }
                let candidate = PlaylistMigrationCandidate(id: old?.id ?? UUID(), entryID: lease.entry.id, provider: item.provider,
                    providerTrackID: item.identity, title: item.fullTitle ?? item.title, artist: item.artist, durationMs: item.durationMs,
                    confidence: score.score / 100, evidence: evidence, decision: index == 0 && verifiedTrack != nil ? .accepted : .pending)
                guard candidate.confidence.map({ $0.isFinite && (0...1).contains($0) }) == true,
                      !candidate.title.isEmpty, candidate.durationMs.map({ $0 >= 0 }) ?? true else { throw PlaylistMigrationStorageError.invalidCandidate }
                // Display metadata is not diagnostic text. A song named "Secret"
                // must not be rejected as a credential; credential syntax still is.
                let metadata = [candidate.provider, candidate.providerTrackID, candidate.title, candidate.artist].compactMap { $0 }
                    + evidence.filter { $0.key != "thumbnailURL" }.flatMap { [$0.key, $0.value] }
                guard metadata.allSatisfy({ MatchingSafeText.metadata($0) == $0 }) else {
                    throw PlaylistMigrationStorageError.unsafeDiagnostics
                }
                let created = try MigrationCandidateRecord.fetchOne(db, key: candidate.id.uuidString)?.createdAt ?? Date()
                try MigrationCandidateRecord(candidate, createdAt: created).save(db)
            }
            let next: PlaylistMigrationEntryStatus = verifiedTrack != nil ? .ready : decision.outcome == .noMatch ? (discoveryFailed ? .failed : .unavailable) : .needsReview
            try PlaylistMigrationValidation.requireEntryTransition(entry.status, to: next)
            entry.status = next; entry.localTrackID = verifiedTrack?.id; entry.updatedAt = Self.nextMatchingRevision(entry.updatedAt)
            try entry.update(db)
            try MatchingCheckpoint(entryID: entry.id, algorithm: CandidateScoringEngine.algorithmVersion,
                retryable: discoveryFailed || issue != nil,
                outcome: deferred ? "discoveryDeferred" : discoveryFailed ? "discoveryFailed" : decision.outcome.rawValue, updatedAt: Date()).save(db)
            // One reusable attempt issue per occurrence; historical candidates remain intact.
            let oldIssue = try MigrationIssueRecord.filter(Column("entryID") == entry.id && Column("code") == "matching-attempt").fetchOne(db)
            let message = issue ?? (decision.outcome == .noMatch ? decision.explanation : nil)
            if let message {
                try MigrationPersistentText.validate([message])
                try MigrationIssueRecord(PlaylistMigrationIssue(id: oldIssue.flatMap { UUID(uuidString: $0.id) } ?? UUID(), migrationID: lease.session.id,
                    entryID: lease.entry.id, code: "matching-attempt", message: message, technicalDetails: nil,
                    severity: .warning, resolution: .open, createdAt: oldIssue?.createdAt ?? Date(), resolvedAt: nil)).save(db)
            } else if var oldIssue {
                oldIssue.resolution = .resolved; oldIssue.resolvedAt = Date(); oldIssue.updatedAt = Date(); try oldIssue.update(db)
            }
        }
    }
    /// An occurrence failure is recoverable only while this session still owns
    /// the job. Never overwrite a concurrent user decision or a newer worker.
    func recordMatchingFailure(_ lease: MatchingEntryLease, category: MatchingFailureCategory) async throws {
        try await db.write { db in
            _ = try Self.requireMatchingSession(lease.session, db: db)
            guard var entry = try MigrationEntryRecord.fetchOne(db, key: lease.entry.id.uuidString) else { return }
            let unchanged = try entry.model() == lease.entry && Self.matchingCandidates(lease.entry.id, db: db) == lease.previousCandidates
            if !unchanged && (entry.localTrackID != nil || entry.status == .skipped) { return }
            if unchanged && entry.status == .matching && entry.localTrackID == nil {
                try PlaylistMigrationValidation.requireEntryTransition(entry.status, to: .failed)
                entry.status = .failed; entry.updatedAt = Self.nextMatchingRevision(entry.updatedAt); try entry.update(db)
                try MatchingCheckpoint(entryID: entry.id, algorithm: CandidateScoringEngine.algorithmVersion, retryable: true,
                    outcome: category.rawValue, updatedAt: Date()).save(db)
            }
            let old = try MigrationIssueRecord.filter(Column("entryID") == entry.id && Column("code") == "matching-attempt").fetchOne(db)
            try MigrationIssueRecord(PlaylistMigrationIssue(id: old.flatMap { UUID(uuidString: $0.id) } ?? UUID(), migrationID: lease.session.id,
                entryID: lease.entry.id, code: "matching-attempt", message: category.message, technicalDetails: "Category: " + category.rawValue,
                severity: .warning, resolution: .open, createdAt: old?.createdAt ?? Date(), resolvedAt: nil)).save(db)
        }
    }
    func finishMatching(_ lease: MatchingSessionLease, paused: Bool) async throws {
        try await db.write { db in
            var session = try Self.requireMatchingSession(lease, db: db)
            let entries = try Self.entries(db, migrationID: lease.id.uuidString)
            // A cancelled/interrupted attempt never leaves an active-looking entry. With
            // nothing saved it returns to `pending` (unfinished), never "needs review".
            for entry in entries where entry.status == .matching {
                var record = try Self.requiredEntry(entry.id, db: db)
                let next: PlaylistMigrationEntryStatus = try Self.matchingCandidates(entry.id, db: db).isEmpty ? .pending : .needsReview
                try PlaylistMigrationValidation.requireEntryTransition(record.status, to: next)
                record.status = next; record.updatedAt = Self.nextMatchingRevision(record.updatedAt); try record.update(db)
            }
            let next: PlaylistMigrationStatus = paused ? .paused : entries.contains { $0.status == .ready } ? .partiallyCompleted : .awaitingReview
            try PlaylistMigrationValidation.requireSessionTransition(session.status, to: next)
            session.status = next; session.updatedAt = Self.nextMatchingRevision(session.updatedAt); try session.update(db)
        }
    }
    func matchingSummary(migrationID: UUID) async throws -> SongMatchingProgress {
        try await db.read { db in
            let entries = try Self.entries(db, migrationID: migrationID.uuidString)
            let candidates = try MigrationCandidateRecord.fetchAll(db, sql: """
                SELECT c.* FROM migration_candidates c JOIN migration_entries e ON e.id = c.entryID
                WHERE e.migrationID = ? AND (c.decision = 'accepted' OR
                    (json_extract(c.evidence, '$.currentAttempt') = 'true' AND json_extract(c.evidence, '$.rank') = '1'))
                """, arguments: [migrationID.uuidString]).map { try $0.model() }
            let localIDs = Set(candidates.filter { $0.provider == "local" && $0.decision == .accepted }.map(\.entryID))
            let recommendedIDs = Set(candidates.filter { $0.decision == .pending && $0.evidence["outcome"] == "recommended" }.map(\.entryID))
            var result = SongMatchingProgress(total: entries.count)
            let discoveryFailures = Set(try String.fetchAll(db, sql: """
                SELECT e.id FROM migration_entries e
                LEFT JOIN migration_matching_checkpoints c ON c.entryID = e.id
                WHERE e.migrationID = ? AND (c.outcome = 'discoveryFailed' OR (COALESCE(c.outcome, '') != 'discoveryDeferred' AND EXISTS (
                    SELECT 1 FROM migration_issues i WHERE i.entryID = e.id AND i.code = 'matching-attempt'
                    AND i.resolution = 'open' AND i.message LIKE 'External discovery%')))
                """, arguments: [migrationID.uuidString]))
            let checkpoints = Dictionary(try MatchingCheckpoint.fetchAll(db, sql: """
                SELECT c.* FROM migration_matching_checkpoints c JOIN migration_entries e ON e.id = c.entryID WHERE e.migrationID = ?
                """, arguments: [migrationID.uuidString]).map { ($0.entryID, $0.outcome) }, uniquingKeysWith: { first, _ in first })
            result.candidates = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM migration_candidates c JOIN migration_entries e ON e.id = c.entryID WHERE e.migrationID = ?", arguments: [migrationID.uuidString]) ?? 0
            for entry in entries {
                let unresolvedEntry = entry.localTrackID == nil && ![.skipped, .matched, .ready].contains(entry.status)
                let outcome = checkpoints[entry.id.uuidString]
                let deferred = outcome == "discoveryDeferred" && unresolvedEntry
                let discoveryFailed = !deferred && discoveryFailures.contains(entry.id.uuidString) && unresolvedEntry
                if discoveryFailed { result.discoveryFailed += 1 }
                if deferred { result.externalDeferred += 1 }
                if let outcome, ["recommended", "review", "noMatch", "discoveryFailed"].contains(outcome) { result.externalAttempted += 1 }
                if let outcome, ["recommended", "review", "noMatch"].contains(outcome) { result.externalSucceeded += 1 }
                if outcome == "discoveryFailed" { result.discoveryFailedRequests += 1 }
                if entry.status == .ready {
                    if localIDs.contains(entry.id) { result.localMatches += 1 } else { result.alreadyLocal += 1 }
                } else if entry.status == .needsReview {
                    if recommendedIDs.contains(entry.id) { result.recommended += 1 } else { result.review += 1 }
                } else if entry.status == .matched { result.selected += 1
                } else if entry.status == .unavailable && !discoveryFailed && !deferred { result.noMatch += 1 }
                else if entry.status == .failed && !discoveryFailed && !deferred { result.failed += 1 }
                if [.pending, .matching].contains(entry.status) { result.deferred += 1 }
                if ![.pending, .matching].contains(entry.status) { result.processed += 1 }
            }
            result.discoveryPaused = try Self.requiredSession(migrationID, db: db).status == .paused && result.discoveryFailed + result.externalDeferred > 0
            result.message = try MigrationIssueRecord.filter(Column("migrationID") == migrationID.uuidString && Column("code") == "matching-attempt" && Column("resolution") == "open")
                .order(Column("updatedAt").desc).fetchOne(db)?.message
            return result
        }
    }
}

private func migrationUUID(_ value: String) throws -> UUID {
    guard let id = UUID(uuidString: value) else { throw PlaylistMigrationStorageError.corruptMetadata }; return id
}
private func migrationJSON<T: Encodable>(_ value: T) throws -> String { String(decoding: try JSONEncoder().encode(value), as: UTF8.self) }
private func migrationDecode<T: Decodable>(_ value: String) throws -> T { try JSONDecoder().decode(T.self, from: Data(value.utf8)) }

struct MigrationSessionRecord: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "playlist_migrations"
    var id: String, destinationPlaylistID: String, operationID: String, source: String
    var sourcePlaylistID: String?, sourceReference: String?
    var sourcePlaylistName: String, importFingerprint: String
    var expectedEntryCount: Int
    var status: PlaylistMigrationStatus
    var createdAt: Date, updatedAt: Date
    var failureInformation: String?
    func model() throws -> PlaylistMigrationSession {
        guard let provider = PlaylistMigrationSource(rawValue: source) else { throw PlaylistMigrationStorageError.corruptMetadata }
        return try PlaylistMigrationSession(id: migrationUUID(id), destinationPlaylistID: destinationPlaylistID, source: provider, sourcePlaylistID: sourcePlaylistID, sourcePlaylistName: sourcePlaylistName, importFingerprint: importFingerprint, expectedEntryCount: expectedEntryCount, status: status, createdAt: createdAt, updatedAt: updatedAt, operationID: operationID, failureInformation: failureInformation, sourceReference: sourceReference)
    }
}

struct MigrationEntryRecord: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "migration_entries"
    var id: String, migrationID: String
    var sourcePosition: Int
    var title: String, primaryArtist: String?, additionalArtists: String, album: String?
    var durationMs: Int64?
    var sourceTrackID: String?, sourceURI: String?, artworkURL: String?, localTrackID: String?
    var status: PlaylistMigrationEntryStatus
    var createdAt: Date, updatedAt: Date
    init(source: PlaylistMigrationSourceTrack, migrationID: String, now: Date) throws {
        id = source.id.uuidString; self.migrationID = migrationID; sourcePosition = source.position
        title = source.title; primaryArtist = source.primaryArtist; additionalArtists = try migrationJSON(source.additionalArtists)
        album = source.album; durationMs = source.durationMs; sourceTrackID = source.sourceTrackID; sourceURI = source.sourceURI
        artworkURL = MigrationPersistentText.artwork(source.artworkURL); localTrackID = nil
        status = .pending; createdAt = now; updatedAt = now
    }
    func model() throws -> PlaylistMigrationEntry {
        let uuid = try migrationUUID(id)
        let source = try PlaylistMigrationSourceTrack(id: uuid, position: sourcePosition, title: title, primaryArtist: primaryArtist, additionalArtists: migrationDecode(additionalArtists), album: album, durationMs: durationMs, sourceTrackID: sourceTrackID, sourceURI: sourceURI, artworkURL: artworkURL.flatMap(URL.init(string:)))
        return try PlaylistMigrationEntry(id: uuid, migrationID: migrationUUID(migrationID), source: source, localTrackID: localTrackID, status: status, updatedAt: updatedAt)
    }
}

private struct MigrationCandidateRecord: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "migration_candidates"
    var id: String, entryID: String, provider: String, providerTrackID: String?, title: String, artist: String?
    var durationMs: Int64?, confidence: Double?, evidence: String
    var decision: PlaylistMigrationCandidateDecision
    var createdAt: Date, updatedAt: Date
    init(_ value: PlaylistMigrationCandidate, createdAt: Date) throws {
        id = value.id.uuidString; entryID = value.entryID.uuidString; provider = value.provider; providerTrackID = value.providerTrackID
        title = value.title; artist = value.artist; durationMs = value.durationMs; confidence = value.confidence
        evidence = try migrationJSON(value.evidence); decision = value.decision; self.createdAt = createdAt; updatedAt = Date()
    }
    func model() throws -> PlaylistMigrationCandidate {
        try PlaylistMigrationCandidate(id: migrationUUID(id), entryID: migrationUUID(entryID), provider: provider, providerTrackID: providerTrackID, title: title, artist: artist, durationMs: durationMs, confidence: confidence, evidence: migrationDecode(evidence), decision: decision)
    }
}

private struct MigrationIssueRecord: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "migration_issues"
    var id: String, migrationID: String, entryID: String?, code: String, message: String, technicalDetails: String?
    var severity: PlaylistMigrationIssueSeverity, resolution: PlaylistMigrationIssueResolution
    var createdAt: Date, updatedAt: Date, resolvedAt: Date?
    init(_ value: PlaylistMigrationIssue) {
        id = value.id.uuidString; migrationID = value.migrationID.uuidString; entryID = value.entryID?.uuidString
        code = value.code; message = value.message; technicalDetails = value.technicalDetails; severity = value.severity; resolution = value.resolution
        createdAt = value.createdAt; updatedAt = Date(); resolvedAt = value.resolution == .open ? nil : (value.resolvedAt ?? updatedAt)
    }
    func model() throws -> PlaylistMigrationIssue {
        try PlaylistMigrationIssue(id: migrationUUID(id), migrationID: migrationUUID(migrationID), entryID: entryID.map(migrationUUID), code: code, message: message, technicalDetails: technicalDetails, severity: severity, resolution: resolution, createdAt: createdAt, resolvedAt: resolvedAt)
    }
}

/// Manual browser-assisted selection. A confirmed YouTube candidate marks the
/// occurrence `matched` only: no track, file or download is created, so it is
/// never presented as playable or offline-ready.
extension GRDBPlaylistMigrationRepository {
    static func manualYouTubeCandidate(for entry: PlaylistMigrationEntry, video: YouTubeVideo, metadataVerified: Bool,
                                       id: UUID = UUID()) throws -> PlaylistMigrationCandidate {
        guard YouTubeURLValidator.isValidID(video.id) else { throw YouTubeError.invalidVideoID }
        let fullTitle = MatchingSafeText.metadata(video.title.trimmingCharacters(in: .whitespacesAndNewlines))
        let title = fullTitle.isEmpty ? "YouTube video " + video.id : String(fullTitle.prefix(500))
        let channel = video.channel.map { MatchingSafeText.metadata($0) }.flatMap { $0.isEmpty ? nil : $0 }
        let durationMs = video.duration.flatMap { $0.isFinite && $0 > 0 && $0 < 86_400 ? Int64($0 * 1000) : nil }
        let credits = YouTubeSearchProviderAdapter.credits(title)
        let recording = SongRecording(provider: "youtube", identity: video.id, title: credits.title, artist: credits.artist,
                                      durationMs: durationMs, performerEstablished: credits.artist != nil,
                                      available: video.availability == .available, fullTitle: title, channel: channel)
        // Scored for information only; strict gates are shown, never relaxed.
        let score = CandidateScoringEngine().score(source: entry.source, candidate: recording)
        var evidence = score.evidence
        evidence.removeValue(forKey: "thumbnailURL")
        evidence["matchingAlgorithmVersion"] = "manual-youtube-10.4.5"
        evidence["sourceOccurrenceID"] = entry.id.uuidString
        evidence["selectionMethod"] = "manual"
        evidence["acceptance"] = "Explicit user confirmation of a pasted YouTube link. Audio is not downloaded or verified."
        evidence["selectionExplanation"] = "User-selected YouTube video. Not available offline until acquired and verified."
        evidence["confidenceClassification"] = score.gates.isEmpty ? "User confirmed" : "User confirmed despite automatic checks"
        evidence["hardGateFailures"] = score.gates.joined(separator: ", ")
        evidence["metadataSource"] = metadataVerified ? "verified" : "unavailable"
        evidence["currentAttempt"] = "true"; evidence["rank"] = "1"; evidence["outcome"] = "manual"
        if let channel { evidence["channel"] = channel }
        if let thumbnail = MatchingCandidateArtwork.safe(video.thumbnailURL) ?? MatchingCandidateArtwork.safe(URL(string: "https://i.ytimg.com/vi/" + video.id + "/hqdefault.jpg")) {
            evidence["thumbnailURL"] = thumbnail.absoluteString
        }
        let confidence = min(1, max(0, score.score / 100))
        return PlaylistMigrationCandidate(id: id, entryID: entry.id, provider: "youtube", providerTrackID: video.id, title: title,
            artist: credits.artist, durationMs: durationMs, confidence: confidence.isFinite ? confidence : 0, evidence: evidence, decision: .accepted)
    }

    /// Requires the caller's last-read entry; a running worker or concurrent edit wins.
    @discardableResult
    func confirmYouTubeCandidate(for expected: PlaylistMigrationEntry, video: YouTubeVideo, metadataVerified: Bool) async throws -> PlaylistMigrationCandidate {
        _ = try Self.manualYouTubeCandidate(for: expected, video: video, metadataVerified: metadataVerified)
        return try await db.write { db in
            var entry = try Self.requiredEntry(expected.id, db: db)
            guard try entry.model() == expected, entry.localTrackID == nil,
                  [.pending, .needsReview, .failed, .unavailable].contains(entry.status) else { throw SongMatchingError.staleAttempt }
            let previous = try Self.matchingCandidates(expected.id, db: db)
            guard !previous.contains(where: { $0.decision == .accepted }) else { throw PlaylistMigrationStorageError.invalidCandidate }
            let old = previous.first { $0.provider == "youtube" && $0.providerTrackID == video.id }
            let candidate = try Self.manualYouTubeCandidate(for: expected, video: video, metadataVerified: metadataVerified, id: old?.id ?? UUID())
            let metadata = [candidate.provider, candidate.providerTrackID, candidate.title, candidate.artist].compactMap { $0 }
                + candidate.evidence.filter { $0.key != "thumbnailURL" }.flatMap { [$0.key, $0.value] }
            guard metadata.allSatisfy({ MatchingSafeText.metadata($0) == $0 }) else { throw PlaylistMigrationStorageError.unsafeDiagnostics }
            let created = try MigrationCandidateRecord.fetchOne(db, key: candidate.id.uuidString)?.createdAt ?? Date()
            try MigrationCandidateRecord(candidate, createdAt: created).save(db)
            if entry.status == .unavailable {
                try PlaylistMigrationValidation.requireEntryTransition(entry.status, to: .matching); entry.status = .matching
            }
            try PlaylistMigrationValidation.requireEntryTransition(entry.status, to: .matched)
            entry.status = .matched; entry.updatedAt = Self.nextMatchingRevision(entry.updatedAt); try entry.update(db)
            try MatchingCheckpoint(entryID: entry.id, algorithm: CandidateScoringEngine.algorithmVersion, retryable: false,
                                   outcome: "manual", updatedAt: Date()).save(db)
            if var issue = try MigrationIssueRecord.filter(Column("entryID") == entry.id && Column("code") == "matching-attempt"
                && Column("resolution") == "open").fetchOne(db) {
                issue.resolution = .resolved; issue.resolvedAt = Date(); issue.updatedAt = Date(); try issue.update(db)
            }
            return candidate
        }
    }

    /// Rejects the accepted YouTube selection. The occurrence returns to review and
    /// becomes eligible for discovery again; the rejected video is never re-proposed.
    func rejectYouTubeSelection(entryID: UUID, candidateID: UUID) async throws {
        try await db.write { db in
            var entry = try Self.requiredEntry(entryID, db: db)
            guard var record = try MigrationCandidateRecord.fetchOne(db, key: candidateID.uuidString),
                  record.entryID == entryID.uuidString, record.provider == "youtube", record.decision == .accepted else {
                throw PlaylistMigrationStorageError.invalidCandidate
            }
            guard entry.localTrackID == nil, entry.status == .matched else { throw SongMatchingError.staleAttempt }
            record.decision = .rejected; record.updatedAt = Date(); try record.update(db)
            try PlaylistMigrationValidation.requireEntryTransition(entry.status, to: .needsReview)
            entry.status = .needsReview; entry.updatedAt = Self.nextMatchingRevision(entry.updatedAt); try entry.update(db)
            try MatchingCheckpoint.deleteOne(db, key: entry.id)
        }
    }
}

// MARK: - Phase 10.4.6 candidate review, resolution and Phase 10.5 handoff

enum MigrationResolutionCategory: String, CaseIterable, Sendable {
    case confirmed, needsReview, discoveryFailed, discoveryDeferred, noCandidate, awaiting, skipped
    var title: String {
        switch self {
        case .confirmed: "Confirmed"
        case .needsReview: "Needs Review"
        case .discoveryFailed: "Discovery Failed"
        case .discoveryDeferred: "External Discovery Deferred"
        case .noCandidate: "No Candidate Found"
        case .awaiting: "Awaiting Discovery"
        case .skipped: "Skipped"
        }
    }
    var isUnresolved: Bool { ![.confirmed, .skipped].contains(self) }
}

struct MigrationResolutionItem: Identifiable, Equatable, Sendable {
    let entry: PlaylistMigrationEntry
    let category: MigrationResolutionCategory
    let reason: String?
    let pendingCandidates: Int
    var id: UUID { entry.id }
}

struct MigrationResolutionOverview: Equatable, Sendable {
    let items: [MigrationResolutionItem]
    func count(_ category: MigrationResolutionCategory) -> Int { items.filter { $0.category == category }.count }
    var resolved: Int { count(.confirmed) }
    var unresolved: Int { items.filter { $0.category.isUnresolved && $0.category != .needsReview }.count }
    /// Example: "Resolved 157/200 — 25 Need Review — 18 Unresolved"
    var summary: String { "Resolved \(resolved)/\(items.count) — \(count(.needsReview)) Need Review — \(unresolved) Unresolved" }
}

enum MigrationAcquisitionStatus: String, Sendable {
    /// Verified managed local audio is already associated (offline-ready).
    case localAudioVerified
    /// A recording was selected but no audio exists yet. Phase 10.5 owns acquisition.
    case awaitingAcquisition
}

/// Durable, read-only contract for Phase 10.5. One item per resolved occurrence.
struct MigrationAcquisitionHandoff: Equatable, Sendable {
    let occurrenceID: UUID
    let position: Int
    let source: PlaylistMigrationSourceTrack
    let candidate: PlaylistMigrationCandidate?
    let provider: String?
    let providerIdentity: String?
    let canonicalURL: URL?
    let userConfirmed: Bool
    let acquisitionStatus: MigrationAcquisitionStatus
    let localTrackID: String?
}

extension GRDBPlaylistMigrationRepository {
    private static let selectableStatuses: [PlaylistMigrationEntryStatus] = [.pending, .needsReview, .failed, .unavailable]

    func entry(id: UUID) async throws -> PlaylistMigrationEntry {
        try await db.read { db in try Self.requiredEntry(id, db: db).model() }
    }

    /// Accepts one already-discovered candidate for its exact occurrence. Exactly one
    /// accepted candidate per occurrence is enforced inside the write transaction.
    /// Local candidates go through managed-audio verification; YouTube candidates
    /// mark the occurrence `matched` only, never downloaded.
    @discardableResult
    func selectCandidate(for expected: PlaylistMigrationEntry, candidateID: UUID) async throws -> PlaylistMigrationCandidate {
        let stored = try await candidates(entryID: expected.id)
        guard let target = stored.first(where: { $0.id == candidateID }), target.decision == .pending else {
            throw PlaylistMigrationStorageError.invalidCandidate
        }
        if target.provider == "local", let trackID = target.providerTrackID {
            try await confirmLocalRecording(for: expected, trackID: trackID)
            return try await candidates(entryID: expected.id).first { $0.decision == .accepted } ?? target
        }
        guard target.provider == "youtube", let videoID = target.providerTrackID, YouTubeURLValidator.isValidID(videoID) else {
            throw PlaylistMigrationStorageError.invalidCandidate
        }
        return try await db.write { db in
            var entry = try Self.requiredEntry(expected.id, db: db)
            guard try entry.model() == expected, entry.localTrackID == nil,
                  Self.selectableStatuses.contains(entry.status) else { throw SongMatchingError.staleAttempt }
            let previous = try Self.matchingCandidates(expected.id, db: db)
            guard !previous.contains(where: { $0.decision == .accepted }),
                  var record = try MigrationCandidateRecord.fetchOne(db, key: candidateID.uuidString),
                  record.entryID == expected.id.uuidString, record.decision == .pending else { throw PlaylistMigrationStorageError.invalidCandidate }
            var evidence = try record.model().evidence
            evidence["selectionMethod"] = "reviewed-candidate"
            evidence["acceptance"] = "Explicit user confirmation of a discovered YouTube candidate. Audio is not downloaded or verified."
            evidence["userConfirmedAt"] = ISO8601DateFormatter().string(from: Date())
            record.evidence = try migrationJSON(evidence)
            record.decision = .accepted; record.updatedAt = Date(); try record.update(db)
            if entry.status == .unavailable {
                try PlaylistMigrationValidation.requireEntryTransition(entry.status, to: .matching); entry.status = .matching
            }
            try PlaylistMigrationValidation.requireEntryTransition(entry.status, to: .matched)
            entry.status = .matched; entry.updatedAt = Self.nextMatchingRevision(entry.updatedAt); try entry.update(db)
            try MatchingCheckpoint(entryID: entry.id, algorithm: CandidateScoringEngine.algorithmVersion, retryable: false,
                                   outcome: "selected", updatedAt: Date()).save(db)
            try Self.resolveAttemptIssue(entry.id, db: db)
            guard try Self.matchingCandidates(expected.id, db: db).filter({ $0.decision == .accepted }).count == 1 else {
                throw PlaylistMigrationStorageError.invalidCandidate // Rolls back the transaction.
            }
            return try record.model()
        }
    }

    /// Rejects a pending candidate, or the accepted YouTube selection (returning the
    /// occurrence to review). Rejected identities are never re-proposed by discovery.
    func rejectCandidate(entryID: UUID, candidateID: UUID) async throws {
        let accepted = try await candidates(entryID: entryID).first { $0.id == candidateID }?.decision == .accepted
        if accepted { return try await rejectYouTubeSelection(entryID: entryID, candidateID: candidateID) }
        try await db.write { db in
            let entry = try Self.requiredEntry(entryID, db: db)
            guard entry.status != .matching else { throw SongMatchingError.staleAttempt }
            guard var record = try MigrationCandidateRecord.fetchOne(db, key: candidateID.uuidString),
                  record.entryID == entryID.uuidString, record.decision == .pending else { throw PlaylistMigrationStorageError.invalidCandidate }
            record.decision = .rejected; record.updatedAt = Date(); try record.update(db)
        }
    }

    /// Makes one unresolved occurrence eligible for the next matching run. Confirmed
    /// occurrences and accepted decisions are never reopened here.
    func markRetryable(entryID: UUID) async throws {
        try await db.write { db in
            let entry = try Self.requiredEntry(entryID, db: db)
            guard entry.localTrackID == nil, Self.selectableStatuses.contains(entry.status),
                  try !Self.matchingCandidates(entryID, db: db).contains(where: { $0.decision == .accepted }) else { throw SongMatchingError.staleAttempt }
            if var checkpoint = try MatchingCheckpoint.fetchOne(db, key: entry.id) {
                checkpoint.retryable = true; checkpoint.updatedAt = Date(); try checkpoint.update(db)
            }
        }
    }

    private static func resolveAttemptIssue(_ entryID: String, db: Database) throws {
        if var issue = try MigrationIssueRecord.filter(Column("entryID") == entryID && Column("code") == "matching-attempt"
            && Column("resolution") == "open").fetchOne(db) {
            issue.resolution = .resolved; issue.resolvedAt = Date(); issue.updatedAt = Date(); try issue.update(db)
        }
    }

    func resolutionOverview(migrationID: UUID) async throws -> MigrationResolutionOverview {
        try await db.read { db in
            let entries = try Self.entries(db, migrationID: migrationID.uuidString)
            let candidates = Dictionary(grouping: try MigrationCandidateRecord.fetchAll(db, sql: """
                SELECT c.* FROM migration_candidates c JOIN migration_entries e ON e.id = c.entryID WHERE e.migrationID = ?
                """, arguments: [migrationID.uuidString]), by: \.entryID)
            let checkpoints = try MatchingCheckpoint.fetchAll(db, sql: """
                SELECT c.* FROM migration_matching_checkpoints c JOIN migration_entries e ON e.id = c.entryID WHERE e.migrationID = ?
                """, arguments: [migrationID.uuidString]).reduce(into: [String: String]()) { $0[$1.entryID] = $1.outcome }
            let issues = try MigrationIssueRecord.filter(Column("migrationID") == migrationID.uuidString && Column("resolution") == "open")
                .order(Column("updatedAt").desc).fetchAll(db).reduce(into: [String: String]()) { if let id = $1.entryID, $0[id] == nil { $0[id] = $1.message } }
            return MigrationResolutionOverview(items: entries.map { entry in
                let key = entry.id.uuidString, rows = candidates[key] ?? []
                let accepted = rows.contains { $0.decision == .accepted }
                let category: MigrationResolutionCategory
                switch entry.status {
                case .ready where entry.localTrackID != nil: category = .confirmed
                case .matched where accepted: category = .confirmed
                case .skipped: category = .skipped
                case .pending, .matching: category = checkpoints[key] == "discoveryDeferred" ? .discoveryDeferred : .awaiting
                default:
                    if checkpoints[key] == "discoveryDeferred" { category = .discoveryDeferred }
                    else if entry.status == .needsReview { category = .needsReview }
                    else if entry.status == .unavailable { category = .noCandidate }
                    else { category = .discoveryFailed }
                }
                return MigrationResolutionItem(entry: entry, category: category, reason: issues[key],
                                               pendingCandidates: rows.filter { $0.decision == .pending }.count)
            })
        }
    }

    /// Handoff for Phase 10.5. Throws if an occurrence has more than one accepted
    /// candidate, which the write paths make impossible.
    func acquisitionHandoff(migrationID: UUID) async throws -> [MigrationAcquisitionHandoff] {
        let overview = try await resolutionOverview(migrationID: migrationID)
        var result: [MigrationAcquisitionHandoff] = []
        for item in overview.items where item.category == .confirmed {
            let accepted = try await candidates(entryID: item.entry.id).filter { $0.decision == .accepted }
            guard accepted.count <= 1 else { throw PlaylistMigrationStorageError.invalidCandidate }
            let candidate = accepted.first
            let method = candidate?.evidence["selectionMethod"] ?? ""
            let confirmed = ["manual", "reviewed-candidate"].contains(method) || candidate?.evidence["matchingAlgorithmVersion"] == "manual-10.4"
            let local = item.entry.status == .ready && item.entry.localTrackID != nil
            result.append(.init(occurrenceID: item.entry.id, position: item.entry.position, source: item.entry.source, candidate: candidate,
                provider: candidate?.provider ?? (local ? "local" : nil), providerIdentity: candidate?.providerTrackID ?? item.entry.localTrackID,
                canonicalURL: candidate.flatMap(MatchingCandidateArtwork.watchURL), userConfirmed: confirmed,
                acquisitionStatus: local ? .localAudioVerified : .awaitingAcquisition, localTrackID: item.entry.localTrackID))
        }
        return result
    }
}

#if DEBUG
extension GRDBPlaylistMigrationRepository {
    /// UI-test fixture seeding only (AppBootstrap `--review-queue-fixture`). Keeps the
    /// candidate record type private to this file.
    static func insertFixtureCandidate(_ candidate: PlaylistMigrationCandidate, db: Database) throws {
        try MigrationCandidateRecord(candidate, createdAt: Date()).insert(db)
    }
}
#endif

// MARK: - Phase 10.5 acquisition association

extension GRDBPlaylistMigrationRepository {
    /// Attaches one verified downloaded recording to every listed occurrence that still
    /// holds the exact accepted YouTube decision it was linked for. Decoding and SHA-256
    /// verification run once, before (and outside) the write transaction. A changed or
    /// rejected decision is `.stale` and is never overwritten by a late completion.
    func associateAcquiredTrack(trackID: String, occurrences: [(entryID: UUID, candidateID: UUID)]) async throws -> [UUID: AcquisitionAssociation] {
        guard !occurrences.isEmpty else { return [:] }
        let track: StoredTrack
        do { track = try await verifiedMatchingAudio(trackID: trackID) }
        catch is CancellationError { throw CancellationError() }
        catch { return Dictionary(uniqueKeysWithValues: occurrences.map { ($0.entryID, AcquisitionAssociation.invalidAudio) }) }
        return try await db.write { [self] db in
            var result: [UUID: AcquisitionAssociation] = [:]
            do { try validateMatchingAudio(track, db: db) }
            catch { return Dictionary(uniqueKeysWithValues: occurrences.map { ($0.entryID, AcquisitionAssociation.invalidAudio) }) }
            for item in occurrences {
                guard var entry = try MigrationEntryRecord.fetchOne(db, key: item.entryID.uuidString) else { result[item.entryID] = .stale; continue }
                let accepted = try Self.matchingCandidates(item.entryID, db: db).filter { $0.decision == .accepted }
                guard accepted.count == 1, accepted[0].id == item.candidateID, accepted[0].provider == "youtube" else { result[item.entryID] = .stale; continue }
                if entry.status == .ready && entry.localTrackID == trackID { result[item.entryID] = .associated; continue }
                guard entry.status == .matched, entry.localTrackID == nil else { result[item.entryID] = .stale; continue }
                try PlaylistMigrationValidation.requireEntryTransition(entry.status, to: .ready)
                entry.status = .ready; entry.localTrackID = trackID; entry.updatedAt = Self.nextMatchingRevision(entry.updatedAt)
                try entry.update(db)
                result[item.entryID] = .associated
            }
            return result
        }
    }

    /// Resolves an occurrence with audio the user imported from Files and explicitly
    /// confirmed after inspecting both sets of metadata. The occurrence keeps its source
    /// identity and position. A previously accepted YouTube selection (for example one
    /// whose source is not downloadable) is retained as evidence: it returns to `pending`
    /// and is marked superseded, never deleted or silently rejected.
    func confirmImportedRecording(for expected: PlaylistMigrationEntry, trackID: String) async throws {
        let track = try await verifiedMatchingAudio(trackID: trackID)
        try await db.write { [self] db in
            var entry = try Self.requiredEntry(expected.id, db: db)
            guard try entry.model() == expected, entry.localTrackID == nil,
                  [.pending, .matching, .needsReview, .matched, .failed, .unavailable].contains(entry.status) else { throw SongMatchingError.staleAttempt }
            try validateMatchingAudio(track, db: db)
            let previous = try Self.matchingCandidates(expected.id, db: db)
            guard !previous.contains(where: { $0.provider == "local" && $0.providerTrackID == trackID && $0.decision == .rejected }) else {
                throw PlaylistMigrationStorageError.invalidCandidate
            }
            for old in previous where old.decision == .accepted {
                guard old.provider != "local", var record = try MigrationCandidateRecord.fetchOne(db, key: old.id.uuidString) else {
                    throw PlaylistMigrationStorageError.invalidCandidate
                }
                var evidence = old.evidence
                evidence["supersededBy"] = "local-file"; evidence["currentAttempt"] = "false"
                record.evidence = try migrationJSON(evidence); record.decision = .pending; record.updatedAt = Date()
                try record.update(db)
            }
            if entry.status != .matched && entry.status != .matching {
                try PlaylistMigrationValidation.requireEntryTransition(entry.status, to: .matching); entry.status = .matching
            }
            try PlaylistMigrationValidation.requireEntryTransition(entry.status, to: .ready)
            let artist = try track.artistID.flatMap { try StoredArtist.fetchOne(db, key: $0)?.name }
            let title = MatchingSafeText.metadata(track.title).isEmpty ? "Imported audio" : MatchingSafeText.metadata(track.title)
            let safeArtist = artist.map { MatchingSafeText.metadata($0) }.flatMap { $0.isEmpty ? nil : $0 }
            let old = previous.first { $0.provider == "local" && $0.providerTrackID == trackID }
            let candidate = PlaylistMigrationCandidate(id: old?.id ?? UUID(), entryID: expected.id, provider: "local", providerTrackID: trackID,
                title: String(title.prefix(500)), artist: safeArtist, durationMs: track.durationMs, confidence: nil,
                evidence: ["matchingAlgorithmVersion": "manual-10.5-file", "selectionMethod": "local-file", "sourceOccurrenceID": entry.id,
                    "acceptance": "Explicit user confirmation of audio imported from Files after metadata inspection",
                    "selectionExplanation": "The user imported and confirmed this file. Managed audio decoding and SHA-256 verification passed.",
                    "confidenceClassification": "User confirmed; no automatic identity claim", "currentAttempt": "true", "rank": "1"], decision: .accepted)
            try MigrationCandidateRecord(candidate, createdAt: Date()).save(db)
            entry.status = .ready; entry.localTrackID = trackID; entry.updatedAt = Self.nextMatchingRevision(entry.updatedAt); try entry.update(db)
            try MatchingCheckpoint(entryID: entry.id, algorithm: CandidateScoringEngine.algorithmVersion, retryable: false, outcome: "local", updatedAt: Date()).save(db)
            try Self.resolveAttemptIssue(entry.id, db: db)
        }
    }
}

// MARK: - Staged recording replacement ("Change Video" for a verified occurrence)

extension GRDBPlaylistMigrationRepository {
    func replacements() async throws -> [RecordingReplacementRecord] {
        try await db.read { db in try RecordingReplacementRecord.order(Column("createdAt"), Column("entryID")).fetchAll(db) }
    }
    func replacement(entryID: UUID) async throws -> RecordingReplacementRecord? {
        try await db.read { db in try RecordingReplacementRecord.fetchOne(db, key: entryID.uuidString) }
    }

    /// Stages a different YouTube recording for an occurrence that is ready with verified,
    /// present audio. Nothing about the current association changes: the occurrence stays
    /// `ready` with its track, its accepted decision stays accepted, and the replacement is
    /// saved as a *pending* candidate. Staging again supersedes the earlier request.
    @discardableResult
    func stageReplacement(for expected: PlaylistMigrationEntry, video: YouTubeVideo, metadataVerified: Bool) async throws -> RecordingReplacementRecord {
        _ = try Self.manualYouTubeCandidate(for: expected, video: video, metadataVerified: metadataVerified) // Validates the video ID.
        return try await db.write { [paths] db in
            let entry = try Self.requiredEntry(expected.id, db: db)
            guard try entry.model() == expected, entry.status == .ready, let trackID = entry.localTrackID,
                  let track = try StoredTrack.fetchOne(db, key: trackID), MigrationLocalAudio.isAvailable(track, paths: paths) else {
                throw SongMatchingError.staleAttempt
            }
            let previous = try Self.matchingCandidates(expected.id, db: db)
            let accepted = previous.filter { $0.decision == .accepted }
            guard accepted.count <= 1 else { throw PlaylistMigrationStorageError.invalidCandidate }
            // Replacing a recording with itself is not a change.
            if let current = accepted.first, current.provider == "youtube", current.providerTrackID == video.id {
                throw PlaylistMigrationStorageError.invalidCandidate
            }
            try Self.supersedeStagedReplacements(previous, outcome: "superseded", db: db)
            let reuse = previous.first { $0.provider == "youtube" && $0.providerTrackID == video.id && $0.decision != .accepted }
            let scored = try Self.manualYouTubeCandidate(for: expected, video: video, metadataVerified: metadataVerified, id: reuse?.id ?? UUID())
            var evidence = scored.evidence
            evidence["stagedReplacement"] = "true"
            evidence["selectionMethod"] = "replacement"
            evidence["outcome"] = "replacement"
            evidence["acceptance"] = "Explicit user request to replace the verified recording. The current audio stays in use until this one is downloaded and verified."
            evidence["selectionExplanation"] = "Replacement requested. The current recording keeps playing until this one is verified."
            let candidate = PlaylistMigrationCandidate(id: scored.id, entryID: scored.entryID, provider: scored.provider, providerTrackID: scored.providerTrackID,
                title: scored.title, artist: scored.artist, durationMs: scored.durationMs, confidence: scored.confidence, evidence: evidence, decision: .pending)
            let metadata = [candidate.provider, candidate.providerTrackID, candidate.title, candidate.artist].compactMap { $0 }
                + candidate.evidence.filter { $0.key != "thumbnailURL" }.flatMap { [$0.key, $0.value] }
            guard metadata.allSatisfy({ MatchingSafeText.metadata($0) == $0 }) else { throw PlaylistMigrationStorageError.unsafeDiagnostics }
            let created = try MigrationCandidateRecord.fetchOne(db, key: candidate.id.uuidString)?.createdAt ?? Date()
            try MigrationCandidateRecord(candidate, createdAt: created).save(db)
            let now = Date()
            let record = RecordingReplacementRecord(entryID: entry.id, migrationID: entry.migrationID, originalCandidateID: accepted.first?.id.uuidString,
                originalTrackID: trackID, candidateID: candidate.id.uuidString, videoID: video.id, title: candidate.title,
                channel: candidate.evidence["channel"], durationMs: candidate.durationMs, downloadJobID: nil, createdJob: false,
                state: .waiting, failure: nil, retries: 0, createdAt: now, updatedAt: now)
            try record.save(db)
            return record
        }
    }

    /// Cancels a pending replacement. The current recording is untouched; the staged
    /// candidate is kept as evidence. Returns the removed request, if any.
    @discardableResult
    func cancelReplacement(entryID: UUID) async throws -> RecordingReplacementRecord? {
        try await db.write { db in
            guard let record = try RecordingReplacementRecord.fetchOne(db, key: entryID.uuidString) else { return nil }
            try Self.supersedeStagedReplacements(try Self.matchingCandidates(entryID, db: db), outcome: "cancelled", db: db)
            _ = try record.delete(db)
            return record
        }
    }

    /// Saves acquisition bookkeeping for the replacement the caller still owns (same
    /// staged candidate). A re-staged or cancelled request is never overwritten.
    @discardableResult
    func updateReplacement(_ value: RecordingReplacementRecord) async throws -> Bool {
        try await db.write { db in
            guard let current = try RecordingReplacementRecord.fetchOne(db, key: value.entryID), current.candidateID == value.candidateID else { return false }
            var stored = value
            if let job = stored.downloadJobID, try StoredDownloadJob.fetchOne(db, key: job) == nil { stored.downloadJobID = nil }
            stored.createdAt = current.createdAt
            try stored.update(db)
            return true
        }
    }

    /// The atomic switch. Decoding and SHA-256 verification of the new audio happen first,
    /// outside the transaction; inside it every precondition is re-checked: the request is
    /// still this candidate, the occurrence is still `ready` with the original track and
    /// the original decision. Only then does the occurrence move to the new track, the
    /// new candidate become the single accepted decision and the previous one become
    /// rejected-as-replaced. Source position and metadata never change; no track or file
    /// is deleted, so other occurrences sharing the old recording are unaffected.
    func commitReplacement(entryID: UUID, candidateID: UUID, trackID: String) async throws -> RecordingReplacementOutcome {
        let track: StoredTrack
        do { track = try await verifiedMatchingAudio(trackID: trackID) }
        catch is CancellationError { throw CancellationError() }
        catch { return .invalidAudio }
        return try await db.write { [self] db in
            guard let request = try RecordingReplacementRecord.fetchOne(db, key: entryID.uuidString),
                  request.candidateID == candidateID.uuidString, request.state == .waiting else { return .stale }
            do { try validateMatchingAudio(track, db: db) } catch { return .invalidAudio }
            let candidates = try Self.matchingCandidates(entryID, db: db)
            let accepted = candidates.filter { $0.decision == .accepted }
            let expectedAccepted: [String] = request.originalCandidateID.map { [$0] } ?? []
            guard var entry = try MigrationEntryRecord.fetchOne(db, key: entryID.uuidString), entry.status == .ready,
                  entry.localTrackID == request.originalTrackID,
                  accepted.map(\.id.uuidString) == expectedAccepted,
                  var next = try MigrationCandidateRecord.fetchOne(db, key: candidateID.uuidString),
                  next.entryID == entryID.uuidString, next.decision == .pending else {
                // The occurrence changed underneath the request: it can never apply.
                _ = try request.delete(db)
                return .stale
            }
            let stamp = Date()
            for old in accepted {
                guard var record = try MigrationCandidateRecord.fetchOne(db, key: old.id.uuidString) else { continue }
                var evidence = old.evidence
                evidence["replacedBy"] = candidateID.uuidString; evidence["currentAttempt"] = "false"
                record.evidence = try migrationJSON(evidence); record.decision = .rejected; record.updatedAt = stamp
                try record.update(db)
            }
            var evidence = try next.model().evidence
            evidence.removeValue(forKey: "stagedReplacement")
            evidence["replacementOf"] = request.originalCandidateID ?? "local-association"
            evidence["userConfirmedAt"] = ISO8601DateFormatter().string(from: stamp)
            evidence["acceptance"] = "Explicit user replacement. Managed audio decoding and SHA-256 verification passed before the switch."
            next.evidence = try migrationJSON(evidence); next.decision = .accepted; next.updatedAt = stamp
            try next.update(db)
            entry.localTrackID = trackID; entry.updatedAt = Self.nextMatchingRevision(entry.updatedAt)
            try entry.update(db)
            try MatchingCheckpoint(entryID: entry.id, algorithm: CandidateScoringEngine.algorithmVersion, retryable: false,
                                   outcome: "selected", updatedAt: stamp).save(db)
            // The acquisition link follows the new decision, already complete.
            var link = try AcquisitionLinkRecord.fetchOne(db, key: entry.id)
                ?? AcquisitionLinkRecord(entryID: entry.id, migrationID: entry.migrationID, candidateID: candidateID.uuidString, provider: "youtube",
                                         providerIdentity: request.videoID, downloadJobID: nil, createdJob: false, state: .ready, trackID: nil,
                                         failure: nil, retries: 0, nextRetryAt: nil, createdAt: stamp, updatedAt: stamp, completedAt: nil)
            var job: String? = nil
            if let id = request.downloadJobID, try StoredDownloadJob.fetchOne(db, key: id) != nil { job = id }
            link.candidateID = candidateID.uuidString; link.providerIdentity = request.videoID
            link.downloadJobID = job; link.createdJob = request.createdJob; link.state = .ready; link.trackID = trackID; link.failure = nil
            link.retries = 0; link.nextRetryAt = nil; link.completedAt = stamp; link.updatedAt = stamp
            try link.save(db)
            _ = try request.delete(db)
            return .replaced
        }
    }

    private static func supersedeStagedReplacements(_ candidates: [PlaylistMigrationCandidate], outcome: String, db: Database) throws {
        for old in candidates where old.decision == .pending && old.evidence["stagedReplacement"] == "true" {
            guard var record = try MigrationCandidateRecord.fetchOne(db, key: old.id.uuidString) else { continue }
            var evidence = old.evidence
            evidence["stagedReplacement"] = "false"; evidence["replacementOutcome"] = outcome; evidence["currentAttempt"] = "false"
            record.evidence = try migrationJSON(evidence); record.updatedAt = Date()
            try record.update(db)
        }
    }
}
