import Foundation

/// Atomic metadata creation and read contracts shared with Phase 10.0 clients.
protocol PlaylistMigrationPersisting {
    /// Must atomically create the playlist, migration and all occurrences.
    /// Retrying the same operation identity must return the existing session.
    func createPlaylist(from source: PlaylistMigrationSourcePlaylist,
                        operationID: String) async throws -> PlaylistMigrationSession
    func session(id: UUID) async throws -> PlaylistMigrationSession?
    func entries(migrationID: UUID) async throws -> [PlaylistMigrationEntry]
    func candidates(entryID: UUID) async throws -> [PlaylistMigrationCandidate]
    func issues(migrationID: UUID) async throws -> [PlaylistMigrationIssue]
    func progress(migrationID: UUID) async throws -> PlaylistMigrationProgress
}

/// Mutable persistent lifecycle operations; file parsing and acquisition remain separate.
protocol PlaylistMigrationStatePersisting: PlaylistMigrationPersisting {
    func incompleteSessions() async throws -> [PlaylistMigrationSession]
    func updateStatus(migrationID: UUID, to status: PlaylistMigrationStatus, failureInformation: String?) async throws
    func updateEntryStatus(entryID: UUID, to status: PlaylistMigrationEntryStatus) async throws
    func associateVerifiedTrack(entryID: UUID, trackID: String) async throws
    func removeLocalAssociation(entryID: UUID) async throws
    func saveCandidate(_ value: PlaylistMigrationCandidate) async throws
    func updateCandidate(id: UUID, decision: PlaylistMigrationCandidateDecision) async throws
    func saveIssue(_ value: PlaylistMigrationIssue) async throws
    func resolveIssue(id: UUID, resolution: PlaylistMigrationIssueResolution) async throws
    func recover() throws
    func deleteSession(id: UUID) async throws
}

/// Implementations are introduced in Phase 10.2, not in the Foundation.
protocol PlaylistMigrationFileImporting {
    func playlists(from file: URL) async throws -> [PlaylistMigrationSourcePlaylist]
}

/// Discovery and scoring remain separate from downloading (Phase 10.4).
protocol PlaylistMigrationMatching {
    func candidates(for entry: PlaylistMigrationEntry) async throws -> [PlaylistMigrationCandidate]
}

/// Audio acquisition requires source authorization and an explicit verified match (Phase 10.5).
protocol PlaylistMigrationAcquiring {
    /// Returns the actual stored local track ID; never fabricate a track for a placeholder.
    func acquire(candidate: PlaylistMigrationCandidate, for entry: PlaylistMigrationEntry) async throws -> String
}

/// Scheduler implementation and durable retry policies belong to Phase 10.6.
protocol PlaylistMigrationCoordinating {
    func resume(migrationID: UUID) async throws
    func pause(migrationID: UUID) async throws
    func cancel(migrationID: UUID) async throws
}
