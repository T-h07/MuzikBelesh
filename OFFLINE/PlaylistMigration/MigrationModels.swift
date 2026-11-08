import Foundation

/// Metadata origin only. No provider requests are performed by Phase 10.0.
enum PlaylistMigrationSource: String, Codable, CaseIterable, Sendable {
    case spotifyAccountExport
    case exportify
    case spotifyAPI
}

enum PlaylistMigrationStatus: String, Codable, CaseIterable, Sendable {
    case preparing, importingMetadata, metadataReady, matching, awaitingReview
    case downloading, verifying, completed, partiallyCompleted, paused, cancelled, failed

    var isTerminal: Bool { self == .completed || self == .cancelled }

    /// Legal *session* transitions; Phase 10.1 will enforce these at the storage boundary.
    func canTransition(to next: Self) -> Bool {
        if self == next { return true }
        switch self {
        case .preparing: return [.importingMetadata, .cancelled, .failed].contains(next)
        case .importingMetadata: return [.metadataReady, .cancelled, .failed].contains(next)
        case .metadataReady: return [.matching, .paused, .cancelled, .failed].contains(next)
        case .matching: return [.awaitingReview, .downloading, .verifying, .completed, .partiallyCompleted, .paused, .cancelled, .failed].contains(next)
        case .awaitingReview: return [.matching, .downloading, .partiallyCompleted, .paused, .cancelled, .failed].contains(next)
        case .downloading: return [.matching, .awaitingReview, .verifying, .partiallyCompleted, .paused, .cancelled, .failed].contains(next)
        case .verifying: return [.matching, .awaitingReview, .downloading, .completed, .partiallyCompleted, .paused, .cancelled, .failed].contains(next)
        case .partiallyCompleted: return [.matching, .awaitingReview, .downloading, .verifying, .completed, .paused, .cancelled].contains(next)
        case .paused: return [.metadataReady, .matching, .awaitingReview, .downloading, .verifying, .partiallyCompleted, .cancelled, .failed].contains(next)
        case .failed: return [.importingMetadata, .metadataReady, .matching, .cancelled].contains(next)
        case .completed, .cancelled: return false
        }
    }
}

enum PlaylistMigrationEntryStatus: String, Codable, CaseIterable, Sendable {
    case pending, matching, needsReview, matched, queued, downloading, verifying
    case ready, unavailable, failed, skipped

    /// 'Ready' is not sufficient on its own: a repository must also validate the local file.
    var suggestsPlayableAudio: Bool { self == .ready }

    func canTransition(to next: Self) -> Bool {
        if self == next { return true }
        switch self {
        case .pending: return [.matching, .needsReview, .matched, .ready, .failed, .skipped].contains(next)
        case .matching: return [.needsReview, .matched, .ready, .unavailable, .failed, .skipped].contains(next)
        case .needsReview: return [.matching, .matched, .unavailable, .skipped].contains(next)
        case .matched: return [.queued, .ready, .needsReview, .failed, .skipped].contains(next)
        case .queued: return [.downloading, .failed, .skipped, .needsReview].contains(next)
        case .downloading: return [.queued, .verifying, .failed, .skipped].contains(next)
        case .verifying: return [.ready, .failed, .needsReview].contains(next)
        case .ready: return [.unavailable, .failed, .needsReview].contains(next)
        case .unavailable: return [.matching, .needsReview, .skipped].contains(next)
        case .failed: return [.matching, .matched, .queued, .needsReview, .skipped].contains(next)
        case .skipped: return [.pending, .matching, .needsReview].contains(next)
        }
    }
}

/// One *occurrence* in a source playlist, not a unique music recording.
struct PlaylistMigrationSourceTrack: Identifiable, Codable, Equatable, Sendable {
    let id: UUID
    let position: Int
    let title: String
    let primaryArtist: String?
    let additionalArtists: [String]
    let album: String?
    let durationMs: Int64?
    let sourceTrackID: String?
    let sourceURI: String?
    let artworkURL: URL?

    init(id: UUID = UUID(), position: Int, title: String, primaryArtist: String? = nil,
         additionalArtists: [String] = [], album: String? = nil, durationMs: Int64? = nil,
         sourceTrackID: String? = nil, sourceURI: String? = nil, artworkURL: URL? = nil) {
        self.id = id; self.position = position; self.title = title
        self.primaryArtist = primaryArtist; self.additionalArtists = additionalArtists
        self.album = album; self.durationMs = durationMs
        self.sourceTrackID = sourceTrackID; self.sourceURI = sourceURI; self.artworkURL = artworkURL
    }
}

/// Immutable input contract. File parsing belongs to Phase 10.2.
struct PlaylistMigrationSourcePlaylist: Codable, Equatable, Sendable {
    let source: PlaylistMigrationSource
    let name: String
    let sourcePlaylistID: String?
    let sourceReference: String?
    let entries: [PlaylistMigrationSourceTrack]
    let capturedAt: Date

    init(source: PlaylistMigrationSource, name: String, sourcePlaylistID: String? = nil,
         sourceReference: String? = nil, entries: [PlaylistMigrationSourceTrack],
         capturedAt: Date = Date()) {
        self.source = source; self.name = name; self.sourcePlaylistID = sourcePlaylistID
        self.sourceReference = sourceReference; self.entries = entries; self.capturedAt = capturedAt
    }
}

/// Future database records are distinct from their source metadata.
struct PlaylistMigrationSession: Identifiable, Codable, Equatable, Sendable {
    let id: UUID
    let destinationPlaylistID: String?
    let source: PlaylistMigrationSource
    let sourcePlaylistID: String?
    let sourcePlaylistName: String
    let importFingerprint: String
    let expectedEntryCount: Int
    let status: PlaylistMigrationStatus
    let createdAt: Date
    let updatedAt: Date
    var operationID: String? = nil
    var failureInformation: String? = nil
    var sourceReference: String? = nil
}

struct PlaylistMigrationEntry: Identifiable, Codable, Equatable, Sendable {
    let id: UUID
    let migrationID: UUID
    let source: PlaylistMigrationSourceTrack
    let localTrackID: String?
    let status: PlaylistMigrationEntryStatus
    let updatedAt: Date

    var position: Int { source.position }
}

enum PlaylistMigrationCandidateDecision: String, Codable, Sendable {
    case pending, accepted, rejected
}

struct PlaylistMigrationCandidate: Identifiable, Codable, Equatable, Sendable {
    let id: UUID
    let entryID: UUID
    let provider: String
    let providerTrackID: String?
    let title: String
    let artist: String?
    let durationMs: Int64?
    let confidence: Double?
    let evidence: [String: String]
    let decision: PlaylistMigrationCandidateDecision
}

enum PlaylistMigrationIssueSeverity: String, Codable, Sendable {
    case information, warning, blocking
}

enum PlaylistMigrationIssueResolution: String, Codable, Sendable {
    case open, resolved, dismissed
}

struct PlaylistMigrationIssue: Identifiable, Codable, Equatable, Sendable {
    let id: UUID
    let migrationID: UUID
    let entryID: UUID?
    let code: String
    let message: String
    let technicalDetails: String?
    let severity: PlaylistMigrationIssueSeverity
    let resolution: PlaylistMigrationIssueResolution
    let createdAt: Date
    let resolvedAt: Date?
}

/// Derived display counters are never a replacement for authoritative SQLite records.
struct PlaylistMigrationProgress: Equatable, Sendable {
    let expected: Int
    let actual: Int
    let ready: Int
    let needsReview: Int
    let unavailable: Int
    let failed: Int
    let skipped: Int
    let pendingOrActive: Int
    let metadataCommitted: Bool

    var metadataComplete: Bool { metadataCommitted && actual == expected }
    var unresolved: Int { actual - ready }
    var audioComplete: Bool { metadataComplete && unresolved == 0 }

    init(expected: Int, states: [PlaylistMigrationEntryStatus], metadataCommitted: Bool) {
        self.expected = expected
        self.actual = states.count
        self.ready = states.filter { $0 == .ready }.count
        self.needsReview = states.filter { $0 == .needsReview }.count
        self.unavailable = states.filter { $0 == .unavailable }.count
        self.failed = states.filter { $0 == .failed }.count
        self.skipped = states.filter { $0 == .skipped }.count
        self.pendingOrActive = states.count - ready - needsReview - unavailable - failed - skipped
        self.metadataCommitted = metadataCommitted
    }
}
