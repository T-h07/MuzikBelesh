import Foundation

protocol PlaylistImportPersisting: PlaylistMigrationPersisting {
    func importSessions() async throws -> [PlaylistMigrationSession]
    func createPlaylist(from source: PlaylistMigrationSourcePlaylist, operationID: String, destinationName: String) async throws -> PlaylistMigrationSession
}

struct PlaylistImportCommit: Sendable {
    let session: PlaylistMigrationSession
    let existing: Bool
}

struct PlaylistImportCoordinator {
    let persistence: any PlaylistImportPersisting

    func review(_ report: PlaylistImportReport) async throws -> [UUID: PlaylistImportDuplicate] {
        let sessions = try await persistence.importSessions()
        var result: [UUID: PlaylistImportDuplicate] = [:]
        for candidate in report.candidates {
            if let source = candidate.source, let operation = candidate.operationID {
                result[candidate.id] = PlaylistImportIdentity.status(source: source, operation: operation, sessions: sessions)
            }
        }
        return result
    }

    func commit(_ candidate: PlaylistImportCandidate, destinationName: String) async throws -> PlaylistImportCommit {
        try Task.checkCancellation()
        guard let source = candidate.source, let operation = candidate.operationID else { throw PlaylistImportProblem(location: candidate.location, reason: "This source has validation errors.") }
        try PlaylistMigrationValidation.validate(source)
        _ = try LibraryIdentity.validatedName(destinationName)
        let status = PlaylistImportIdentity.status(source: source, operation: operation, sessions: try await persistence.importSessions())
        guard status != .ambiguous else { throw PlaylistImportProblem(location: candidate.location, reason: status.message) }
        // Repository repeats identity checks in its transaction, and verifies all
        // persisted positions before returning the canonical session. Cancellation
        // after commit must not hide that successful transaction from the user.
        let session = try await persistence.createPlaylist(from: source, operationID: operation, destinationName: destinationName)
        if case .existing = status { return .init(session: session, existing: true) }
        return .init(session: session, existing: false)
    }
}
