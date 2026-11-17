import Foundation

enum PlaylistMigrationFoundationError: LocalizedError, Equatable {
    case invalidName
    case tooManyEntries
    case invalidPosition(index: Int)
    case duplicateOccurrenceID
    case invalidTitle(index: Int)
    case invalidArtist(index: Int)
    case invalidDuration(index: Int)
    case invalidSourceIdentity
    case illegalSessionTransition
    case illegalEntryTransition

    var errorDescription: String? {
        switch self {
        case .invalidName: return "Playlist name must contain 1–120 characters."
        case .tooManyEntries: return "Playlist exceeds the 10,000-entry import limit."
        case .invalidPosition: return "Playlist source positions must be contiguous and zero-based."
        case .duplicateOccurrenceID: return "Every playlist occurrence must have a unique identity."
        case .invalidTitle: return "A source track has an invalid title."
        case .invalidArtist: return "A source track has invalid artist metadata."
        case .invalidDuration: return "A source track has an invalid duration."
        case .invalidSourceIdentity: return "A source identifier exceeds the supported length."
        case .illegalSessionTransition: return "The migration session cannot move to that state."
        case .illegalEntryTransition: return "The migration entry cannot move to that state."
        }
    }
}

enum PlaylistMigrationValidation {
    static let maximumEntries = 10_000

    /// Validate before Phase 10.1 inserts a destination playlist and all source entries atomically.
    static func validate(_ playlist: PlaylistMigrationSourcePlaylist) throws {
        let name = playlist.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty && name.count <= 120 else { throw PlaylistMigrationFoundationError.invalidName }
        guard playlist.entries.count <= maximumEntries else { throw PlaylistMigrationFoundationError.tooManyEntries }
        guard (playlist.sourcePlaylistID?.count ?? 0) <= 500,
              (playlist.sourceReference?.count ?? 0) <= 4096 else { throw PlaylistMigrationFoundationError.invalidSourceIdentity }
        var occurrences = Set<UUID>()
        for (index, entry) in playlist.entries.enumerated() {
            guard entry.position == index else { throw PlaylistMigrationFoundationError.invalidPosition(index: index) }
            guard occurrences.insert(entry.id).inserted else { throw PlaylistMigrationFoundationError.duplicateOccurrenceID }
            let title = entry.title.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty && title.count <= 300 else { throw PlaylistMigrationFoundationError.invalidTitle(index: index) }
            let artists = [entry.primaryArtist].compactMap { $0 } + entry.additionalArtists
            guard artists.count <= 50 && artists.allSatisfy({ $0.count <= 300 }) &&
                    (entry.album?.count ?? 0) <= 300 else { throw PlaylistMigrationFoundationError.invalidArtist(index: index) }
            guard entry.durationMs.map({ $0 >= 0 }) ?? true else { throw PlaylistMigrationFoundationError.invalidDuration(index: index) }
            guard (entry.sourceTrackID?.count ?? 0) <= 500,
                  (entry.sourceURI?.count ?? 0) <= 4096 else { throw PlaylistMigrationFoundationError.invalidSourceIdentity }
        }
    }

    /// Stable across retry attempts and snapshot dates; occurrence UUIDs are intentionally omitted.
    /// This is a content identity, not proof of licensing or availability.
    static func importFingerprint(for playlist: PlaylistMigrationSourcePlaylist) throws -> String {
        try validate(playlist)
        var values = [playlist.source.rawValue, playlist.sourcePlaylistID ?? "",
                      playlist.sourceReference ?? "", playlist.name]
        values.reserveCapacity(4 + playlist.entries.count * 7)
        for entry in playlist.entries {
            values.append(contentsOf: [
                String(entry.position), entry.sourceTrackID ?? "", entry.sourceURI ?? "",
                entry.title, entry.primaryArtist ?? "", entry.additionalArtists.joined(separator: "\u{001f}"),
                entry.album ?? "", entry.durationMs.map(String.init) ?? ""
            ])
        }
        return LibraryIdentity.id("playlist-migration", values)
    }

    static func requireSessionTransition(_ current: PlaylistMigrationStatus, to next: PlaylistMigrationStatus) throws {
        guard current.canTransition(to: next) else { throw PlaylistMigrationFoundationError.illegalSessionTransition }
    }

    static func requireEntryTransition(_ current: PlaylistMigrationEntryStatus, to next: PlaylistMigrationEntryStatus) throws {
        guard current.canTransition(to: next) else { throw PlaylistMigrationFoundationError.illegalEntryTransition }
    }
}
