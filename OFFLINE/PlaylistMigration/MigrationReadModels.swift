import Foundation

enum PlaylistMigrationStorageError: LocalizedError, Equatable {
    case invalidOperationID, operationConflict, notFound, corruptMetadata, invalidLocalTrack, unsafeDiagnostics, invalidCandidate, managedPlaylist
    var errorDescription: String? {
        switch self {
        case .invalidOperationID: return "Enter an operation identity between 1 and 200 characters without control characters."
        case .operationConflict: return "This operation identity already belongs to different source content."
        case .notFound: return "The migration record no longer exists."
        case .corruptMetadata: return "The stored source occurrences are incomplete or inconsistent."
        case .invalidLocalTrack: return "The associated recording must be verified and available in managed local storage."
        case .unsafeDiagnostics: return "Persistent metadata must not contain credentials or temporary URLs."
        case .invalidCandidate: return "Candidate metadata or ownership is invalid."
        case .managedPlaylist: return "Imported source occurrences are preserved in their original order."
        }
    }
}

/// Identity always belongs to the source occurrence, including repeated recordings.
struct MigrationPlaylistRow: Identifiable, Equatable, Sendable {
    let entry: PlaylistMigrationEntry
    let playableTrack: StoredTrack?
    var id: UUID { entry.id }
    var effectiveStatus: PlaylistMigrationEntryStatus {
        entry.status == .ready && playableTrack == nil ? .unavailable : entry.status
    }
}

struct MigrationPlaybackOccurrence: Identifiable, Codable, Equatable, Sendable {
    let id: String
    let trackID: String
}

/// One derived value per playlist per observed transaction. No persistent cache.
struct MigrationPlaylistPresentation: Equatable, Sendable {
    let session: PlaylistMigrationSession
    let rows: [MigrationPlaylistRow]
    let issues: [PlaylistMigrationIssue]
    let progress: PlaylistMigrationProgress
    let statusCounts: [PlaylistMigrationEntryStatus: Int]
    let rowsByID: [UUID: MigrationPlaylistRow]
    let issuesByEntry: [UUID: [PlaylistMigrationIssue]]

    init(session: PlaylistMigrationSession, rows: [MigrationPlaylistRow], issues: [PlaylistMigrationIssue]) {
        self.session = session; self.rows = rows; self.issues = issues
        let states = rows.map(\.effectiveStatus)
        // Atomic imports expose only complete source snapshots. Lifecycle status
        // may subsequently be paused/failed/cancelled without losing metadata.
        let committed = rows.count == session.expectedEntryCount && rows.enumerated().allSatisfy { $0.offset == $0.element.entry.position }
        progress = PlaylistMigrationProgress(expected: session.expectedEntryCount, states: states, metadataCommitted: committed)
        statusCounts = Dictionary(grouping: states, by: { $0 }).mapValues(\.count)
        rowsByID = Dictionary(uniqueKeysWithValues: rows.map { ($0.id, $0) })
        issuesByEntry = Dictionary(grouping: issues.filter { $0.entryID != nil }, by: { $0.entryID! })
    }
}

extension Array where Element == MigrationPlaylistRow {
    var playbackOccurrences: [MigrationPlaybackOccurrence] {
        compactMap { row in row.playableTrack.map { MigrationPlaybackOccurrence(id: row.id.uuidString, trackID: $0.id) } }
    }
}

/// Cheap check for previously verified managed recordings. Audio decoding still happens
/// at AVPlayer selection; hashing is deliberately confined to association/verification.
enum MigrationLocalAudio {
    static func isAvailable(_ track: StoredTrack, paths: AppStoragePaths) -> Bool {
        guard track.availability == .available,
              SupportedAudioFormat.isSupported(URL(fileURLWithPath: track.fileRelativePath)),
              let url = try? paths.musicURL(relativePath: track.fileRelativePath),
              paths.fileManager.isReadableFile(atPath: url.path),
              let attributes = try? paths.fileManager.attributesOfItem(atPath: url.path),
              attributes[.type] as? FileAttributeType == .typeRegular,
              let size = attributes[.size] as? NSNumber,
              size.int64Value > 0, size.int64Value == track.fileSizeBytes else { return false }
        return true
    }
}

enum MigrationPersistentText {
    static func validate(_ values: [String?]) throws {
        for value in values.compactMap({ $0 }) {
            guard value.count <= 16_384,
                  value.range(of: "(?i)(bearer\\s|access[_-]?token|refresh[_-]?token|oauth|password|secret|api[_-]?key|[?&](token|sig|signature|expires|x-amz-|x-goog-)|https?://[^\\s/]*@)", options: .regularExpression) == nil else {
                throw PlaylistMigrationStorageError.unsafeDiagnostics
            }
            // Arbitrary query-bearing URLs may carry opaque signed credentials.
            if value.range(of: "(?i)https?://[^\\s]*[?#]", options: .regularExpression) != nil {
                throw PlaylistMigrationStorageError.unsafeDiagnostics
            }
        }
    }
    static func artwork(_ url: URL?) -> String? {
        guard let url, url.scheme?.lowercased() == "https", url.host != nil,
              url.user == nil, url.password == nil, url.query == nil, url.fragment == nil else { return nil }
        return url.absoluteString
    }
}
