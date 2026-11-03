import Foundation
import CryptoKit
import GRDB

enum LibraryError: LocalizedError, Equatable, Sendable {
    case invalidName, invalidTitle, invalidOrder, notFound, confirmationRequired, invalidImage, operationFailed, deletionInProgress
    var errorDescription: String? {
        switch self {
        case .invalidName: return "Enter a playlist name between 1 and 120 characters."
        case .invalidTitle: return "Enter a song title between 1 and 300 characters."
        case .invalidOrder: return "The playlist changed. Reload it and try reordering again."
        case .notFound: return "This library item is no longer available."
        case .confirmationRequired: return "Confirm deletion before removing this item."
        case .invalidImage: return "Choose a valid image smaller than 20 MB."
        case .operationFailed: return "The library change could not be saved. Your existing music is preserved. Try again."
        case .deletionInProgress: return "This song has a pending file operation. Try again after recovery."
        }
    }
}

enum LibrarySort: String, CaseIterable, Identifiable, Sendable {
    case nameAscending, nameDescending, artist, newest, oldest, shortest, longest
    var id: String { rawValue }
    var title: String {
        switch self {
        case .nameAscending: return "Name A–Z"
        case .nameDescending: return "Name Z–A"
        case .artist: return "Artist A–Z"
        case .newest: return "Date Added — Newest"
        case .oldest: return "Date Added — Oldest"
        case .shortest: return "Duration — Shortest"
        case .longest: return "Duration — Longest"
        }
    }
    var sqlOrder: String {
        switch self {
        case .nameAscending: return "tracks.normalizedTitle ASC, tracks.id ASC"
        case .nameDescending: return "tracks.normalizedTitle DESC, tracks.id ASC"
        case .artist: return "COALESCE(artists.normalizedName, '') ASC, tracks.normalizedTitle ASC, tracks.id ASC"
        case .newest: return "tracks.dateAdded DESC, tracks.id ASC"
        case .oldest: return "tracks.dateAdded ASC, tracks.id ASC"
        case .shortest: return "(tracks.durationMs IS NULL), tracks.durationMs ASC, tracks.id ASC"
        case .longest: return "(tracks.durationMs IS NULL), tracks.durationMs DESC, tracks.id ASC"
        }
    }
}

enum LibraryIdentity {
    static func display(_ value: String) -> String {
        value.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ").precomposedStringWithCanonicalMapping
    }
    static func normalized(_ value: String) -> String {
        display(value).folding(options: .caseInsensitive, locale: Locale(identifier: "en_US_POSIX"))
    }
    static func search(_ value: String) -> String {
        display(value).folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
    }
    static func id(_ prefix: String, _ values: [String]) -> String {
        let bytes = (try? JSONEncoder().encode(values)) ?? Data()
        return prefix + "-" + SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    }
    static func validatedName(_ name: String) throws -> String {
        let result = display(name)
        guard !result.isEmpty, result.count <= 120 else { throw LibraryError.invalidName }
        return result
    }
    static func validatedTitle(_ title: String) throws -> String {
        let result = title.trimmingCharacters(in: .whitespacesAndNewlines).precomposedStringWithCanonicalMapping
        guard !result.isEmpty, result.count <= 300 else { throw LibraryError.invalidTitle }
        return result
    }
}

struct PlaylistMembership: Codable, FetchableRecord, Equatable, Sendable {
    static let databaseTableName = "playlist_tracks"
    var playlistID: String
    var trackID: String
    var position: Int
    var dateAdded: Date
}

struct LibraryGroup: Identifiable, Equatable, Sendable {
    let id: String
    let title: String
    let subtitle: String
    let trackIDs: [String]
    let artworkRelativePath: String?
    var count: Int { trackIDs.count }
}

struct LibrarySnapshot: Equatable, Sendable {
    var tracks: [StoredTrack] = []
    var artists: [StoredArtist] = []
    var albums: [StoredAlbum] = []
    var playlists: [StoredPlaylist] = []
    var memberships: [PlaylistMembership] = []
    var likedIDs: Set<String> = []
    var recentIDs: [String] = []
    var sort: LibrarySort = .newest
    var trackByID: [String: StoredTrack] { Dictionary(uniqueKeysWithValues: tracks.map { ($0.id, $0) }) }
    func artistName(_ id: String?) -> String { artists.first { $0.id == id }?.name ?? "Unknown Artist" }
    func albumTitle(_ id: String?) -> String { albums.first { $0.id == id }?.title ?? "Unknown Album" }
    func playlistTracks(_ id: String) -> [StoredTrack] {
        let lookup = trackByID
        return memberships.filter { $0.playlistID == id }.sorted { $0.position < $1.position }.compactMap { lookup[$0.trackID] }
    }
    var artistGroups: [LibraryGroup] {
        Dictionary(grouping: tracks, by: { $0.artistID ?? "unknown-artist" }).map { id, songs in
            LibraryGroup(id: id, title: artistName(songs.first?.artistID), subtitle: "\(songs.count) songs", trackIDs: songs.map(\.id), artworkRelativePath: artists.first { $0.id == id }?.artworkRelativePath ?? songs.compactMap(\.artworkRelativePath).first)
        }.sorted { LibraryIdentity.normalized($0.title) == LibraryIdentity.normalized($1.title) ? $0.id < $1.id : LibraryIdentity.normalized($0.title) < LibraryIdentity.normalized($1.title) }
    }
    var albumGroups: [LibraryGroup] {
        Dictionary(grouping: tracks, by: { $0.albumID ?? "unknown-album:\($0.artistID ?? "unknown")" }).map { id, songs in
            let record = albums.first { $0.id == id }
            let ordered = songs.sorted { $0.dateAdded == $1.dateAdded ? $0.id < $1.id : $0.dateAdded < $1.dateAdded }
            return LibraryGroup(id: id, title: record?.title ?? "Unknown Album", subtitle: artistName(record?.artistID ?? songs.first?.artistID), trackIDs: ordered.map(\.id), artworkRelativePath: record?.artworkRelativePath ?? songs.compactMap(\.artworkRelativePath).first)
        }.sorted { LibraryIdentity.normalized($0.title) == LibraryIdentity.normalized($1.title) ? $0.id < $1.id : LibraryIdentity.normalized($0.title) < LibraryIdentity.normalized($1.title) }
    }
}

struct TrackMetadataDraft: Equatable, Sendable {
    var title: String
    var artist: String
    var album: String
    var albumArtist: String = ""
}

struct ManagedFileOperation: Codable, FetchableRecord, PersistableRecord, Identifiable, Sendable {
    static let databaseTableName = "library_file_operations"
    var id: String
    var kind: String
    var ownerID: String
    var originalPath: String?
    var stagedPath: String
    var state: String
    var dateUpdated: Date
    var artworkPath: String? = nil
}

/// One coordinator serializes filesystem/database transitions without blocking UI.
actor LibraryMutationGate {
    private var occupied = false
    private var waiting: [CheckedContinuation<Void, Never>] = []
    func withLock<T>(_ operation: () async throws -> T) async rethrows -> T {
        if occupied { await withCheckedContinuation { waiting.append($0) } }
        else { occupied = true }
        defer {
            if waiting.isEmpty { occupied = false }
            else { waiting.removeFirst().resume() }
        }
        return try await operation()
    }
}
