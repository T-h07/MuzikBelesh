import Foundation
import GRDB

final class GRDBPlaylistMigrationRepository: PlaylistMigrationStatePersisting {
    let db: DatabaseQueue
    let paths: AppStoragePaths
    init(db: DatabaseQueue, paths: AppStoragePaths) { self.db = db; self.paths = paths }

    func createPlaylist(from source: PlaylistMigrationSourcePlaylist, operationID: String) async throws -> PlaylistMigrationSession {
        try createCommittedPlaylist(from: source, operationID: operationID)
    }

    /// One IMMEDIATE GRDB write transaction owns the idempotency check and every insert.
    /// No observer can see importingMetadata or a partially populated playlist.
    func createCommittedPlaylist(from source: PlaylistMigrationSourcePlaylist, operationID: String) throws -> PlaylistMigrationSession {
        try Task.checkCancellation()
        try PlaylistMigrationValidation.validate(source)
        let operation = operationID.trimmingCharacters(in: .whitespacesAndNewlines).precomposedStringWithCanonicalMapping
        guard !operation.isEmpty, operation.count <= 200,
              operation.rangeOfCharacter(from: .controlCharacters) == nil else { throw PlaylistMigrationStorageError.invalidOperationID }
        let fingerprint = try PlaylistMigrationValidation.importFingerprint(for: source)
        return try db.write { [self] db in
            if let existing = try MigrationSessionRecord.fetchOne(db, sql: "SELECT * FROM playlist_migrations WHERE operationID = ?", arguments: [operation]) {
                guard existing.importFingerprint == fingerprint else { throw PlaylistMigrationStorageError.operationConflict }
                try Self.verify(existing, db: db)
                return try existing.model()
            }
            let now = Date(), id = UUID().uuidString, playlistID = UUID().uuidString
            try StoredPlaylist(id: playlistID, name: LibraryIdentity.validatedName(source.name), description: nil, artworkRelativePath: nil, dateAdded: now, dateModified: now).insert(db)
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
        try await db.read { [self] db in
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
    func incompleteSessions() async throws -> [PlaylistMigrationSession] {
        try recover()
        return try await db.read { [self] db in
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
        guard let track = try await db.read({ try StoredTrack.fetchOne($0, key: trackID) }), MigrationLocalAudio.isAvailable(track, paths: paths) else { throw PlaylistMigrationStorageError.invalidLocalTrack }
        let url = try paths.musicURL(relativePath: track.fileRelativePath)
        let audio = AudioFileService()
        _ = try await audio.validate(url)
        guard try audio.sha256(url: url) == track.contentSHA256 else { throw PlaylistMigrationStorageError.invalidLocalTrack }
        try await db.write { [self] db in
            guard let current = try StoredTrack.fetchOne(db, key: trackID), current == track,
                  MigrationLocalAudio.isAvailable(current, paths: paths),
                  try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM library_file_operations WHERE kind = 'delete-track' AND ownerID = ?", arguments: [trackID]) == 0 else { throw PlaylistMigrationStorageError.invalidLocalTrack }
            var record = try Self.requiredEntry(entryID, db: db)
            try PlaylistMigrationValidation.requireEntryTransition(record.status, to: .ready)
            record.localTrackID = trackID; record.status = .ready; record.updatedAt = Date()
            try record.update(db)
        }
    }
    func removeLocalAssociation(entryID: UUID) async throws {
        try await db.write { [self] db in
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
        try await db.read { [self] db in
            _ = try Self.requiredEntry(entryID, db: db)
            return try MigrationCandidateRecord.filter(Column("entryID") == entryID.uuidString).order(Column("createdAt"), Column("id")).fetchAll(db).map { try $0.model() }
        }
    }
    func saveCandidate(_ value: PlaylistMigrationCandidate) async throws {
        guard !value.provider.isEmpty, !value.title.isEmpty, value.confidence.map({ $0.isFinite && (0...1).contains($0) }) ?? true,
              value.durationMs.map({ $0 >= 0 }) ?? true else { throw PlaylistMigrationStorageError.invalidCandidate }
        try MigrationPersistentText.validate([value.provider, value.providerTrackID, value.title, value.artist] + value.evidence.flatMap { [$0.key, $0.value] })
        try await db.write { [self] db in
            _ = try Self.requiredEntry(value.entryID, db: db)
            let old = try MigrationCandidateRecord.fetchOne(db, key: value.id.uuidString)
            guard old == nil || old?.entryID == value.entryID.uuidString else { throw PlaylistMigrationStorageError.invalidCandidate }
            try MigrationCandidateRecord(value, createdAt: old?.createdAt ?? Date()).save(db)
        }
    }
    func updateCandidate(id: UUID, decision: PlaylistMigrationCandidateDecision) async throws {
        try await db.write { [self] db in
            guard var value = try MigrationCandidateRecord.fetchOne(db, key: id.uuidString) else { throw PlaylistMigrationStorageError.notFound }
            value.decision = decision; value.updatedAt = Date(); try value.update(db)
        }
    }
    func issues(migrationID: UUID) async throws -> [PlaylistMigrationIssue] {
        try await db.read { [self] db in
            _ = try Self.requiredSession(migrationID, db: db)
            return try MigrationIssueRecord.filter(Column("migrationID") == migrationID.uuidString).order(Column("createdAt"), Column("id")).fetchAll(db).map { try $0.model() }
        }
    }
    func saveIssue(_ value: PlaylistMigrationIssue) async throws {
        try MigrationPersistentText.validate([value.code, value.message, value.technicalDetails])
        try await db.write { [self] db in
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
        try await db.write { [self] db in
            guard var value = try MigrationIssueRecord.fetchOne(db, key: id.uuidString) else { throw PlaylistMigrationStorageError.notFound }
            value.resolution = resolution; value.updatedAt = Date(); value.resolvedAt = resolution == .open ? nil : value.updatedAt
            try value.update(db)
        }
    }
    /// Session ownership includes its destination. Delete the destination to cascade
    /// metadata; tracks and ordinary playlists are never owned by this operation.
    func deleteSession(id: UUID) async throws {
        try await db.write { [self] db in
            let session = try Self.requiredSession(id, db: db)
            _ = try StoredPlaylist.deleteOne(db, key: session.destinationPlaylistID)
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
