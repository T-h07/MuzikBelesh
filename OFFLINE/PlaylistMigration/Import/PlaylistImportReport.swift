import Foundation

enum PlaylistImportLimits {
    static let inputBytes = 20 * 1024 * 1024
    static let entryBytes = 8 * 1024 * 1024
    static let expandedBytes = 32 * 1024 * 1024
    static let members = 128
    static let compressionRatio = 200
    static let playlists = 100
    static let occurrences = 20_000
    static let csvColumns = 128
    static let fieldBytes = 16 * 1024
}

struct PlaylistImportProblem: LocalizedError, Sendable {
    let location: String
    let reason: String
    var errorDescription: String? { "\(location) — \(reason) This playlist was not imported." }
}

struct PlaylistImportCandidate: Identifiable, Sendable {
    let id = UUID()
    let location: String
    let format: String
    let name: String
    let entryCount: Int?
    let source: PlaylistMigrationSourcePlaylist?
    let diagnostics: [String]
    var operationID: String? {
        guard let source, let fingerprint = try? PlaylistMigrationValidation.importFingerprint(for: source) else { return nil }
        return LibraryIdentity.id("file-import-v1", [fingerprint])
    }
}

struct PlaylistImportReport: Sendable {
    let filename: String
    let format: String
    let candidates: [PlaylistImportCandidate]
    let notes: [String]
    var validCount: Int { candidates.filter { $0.source != nil }.count }
}

enum PlaylistImportDuplicate: Equatable, Sendable {
    case new, changed, existing(UUID), ambiguous
    var message: String {
        switch self {
        case .new: return "Ready to import"
        case .changed: return "Changed export: creates a separate playlist; the earlier import is preserved."
        case .existing: return "Already imported: reuses the existing playlist. Source context and metadata match."
        case .ambiguous: return "Identical metadata exists under a different file context. Identity is ambiguous; this playlist cannot be imported automatically."
        }
    }
}

/// Only hashes of source context are stored, never provider URLs or private paths.
enum PlaylistImportIdentity {
    static func reference(source: PlaylistMigrationSourcePlaylist, container: String, member: String, index: Int) throws -> String {
        let content = PlaylistMigrationSourcePlaylist(source: source.source, name: "Content identity", entries: source.entries)
        let fingerprint = try PlaylistMigrationValidation.importFingerprint(for: content)
        let digest = LibraryIdentity.id("metadata", [fingerprint] + source.entries.map { $0.artworkURL?.absoluteString ?? "" })
        let scope = LibraryIdentity.id("scope", [source.source.rawValue, source.sourcePlaylistID ?? container.precomposedStringWithCanonicalMapping])
        let context = LibraryIdentity.id("context", [scope, member.precomposedStringWithCanonicalMapping, String(source.sourcePlaylistID == nil ? index : 0)])
        return ["mb-import-v1", scope, context, digest].joined(separator: ":")
    }
    static func parts(_ reference: String?) -> [String]? {
        guard let reference else { return nil }
        let parts = reference.components(separatedBy: ":")
        return parts.count == 4 && parts[0] == "mb-import-v1" ? parts : nil
    }
    static func status(source: PlaylistMigrationSourcePlaylist, operation: String, sessions: [PlaylistMigrationSession]) -> PlaylistImportDuplicate {
        if let same = sessions.first(where: { $0.operationID == operation }) { return .existing(same.id) }
        guard let parts = parts(source.sourceReference) else { return .new }
        for session in sessions where session.source == source.source {
            guard let other = self.parts(session.sourceReference) else { continue }
            if source.sourcePlaylistID == nil && other[3] == parts[3] && other[1] != parts[1] { return .ambiguous }
        }
        return sessions.contains { self.parts($0.sourceReference)?[2] == parts[2] } ? .changed : .new
    }
}
