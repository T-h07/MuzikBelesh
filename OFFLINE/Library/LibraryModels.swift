import Foundation
import CryptoKit
import GRDB

enum LibraryError: LocalizedError, Equatable, Sendable {
    case invalidName, invalidTitle, invalidMetadata, invalidDescription, invalidOrder, notFound, confirmationRequired, invalidImage, operationFailed, deletionInProgress
    var errorDescription: String? {
        switch self {
        case .invalidName: return "Enter a collection name between 1 and 120 characters."
        case .invalidTitle: return "Enter a song title between 1 and 300 characters."
        case .invalidMetadata: return "Artist and album names must be at most 300 characters."
        case .invalidDescription: return "Descriptions must be at most 2000 characters."
        case .invalidOrder: return "The collection changed. Reload it and try reordering again."
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
    static func validatedDescription(_ value: String) throws -> String {
        guard value.count <= 2000 else { throw LibraryError.invalidDescription }
        return value
    }
}

struct PlaylistMembership: Codable, FetchableRecord, TableRecord, Equatable, Sendable {
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
        let records = Dictionary(uniqueKeysWithValues: artists.map { ($0.id, $0) })
        let albumArtists = Dictionary(uniqueKeysWithValues: albums.compactMap { album in album.artistID.map { (album.id, $0) } })
        var grouped: [String: [StoredTrack]] = [:]
        for song in tracks {
            let performer = song.artistID ?? "unknown-artist"
            grouped[performer, default: []].append(song)
            if let albumID = song.albumID, let artistID = albumArtists[albumID], artistID != performer { grouped[artistID, default: []].append(song) }
        }
        for album in albums where album.managementSource == "managed" {
            if let id = album.artistID, grouped[id] == nil { grouped[id] = [] }
        }
        return grouped.map { id, songs in
            LibraryGroup(id: id, title: records[id]?.name ?? "Unknown Artist", subtitle: "\(songs.count) songs", trackIDs: songs.map(\.id), artworkRelativePath: records[id]?.artworkRelativePath ?? songs.compactMap(\.artworkRelativePath).first)
        }.sorted { LibraryIdentity.normalized($0.title) == LibraryIdentity.normalized($1.title) ? $0.id < $1.id : LibraryIdentity.normalized($0.title) < LibraryIdentity.normalized($1.title) }
    }
    var albumGroups: [LibraryGroup] {
        let artistNames = Dictionary(uniqueKeysWithValues: artists.map { ($0.id, $0.name) })
        let membership = Dictionary(grouping: tracks.filter { $0.albumID != nil }, by: { $0.albumID! })
        var groups = albums.compactMap { record -> LibraryGroup? in
            let songs = membership[record.id] ?? []
            guard !songs.isEmpty || record.managementSource == "managed" else { return nil }
            let ordered = songs.sorted {
                if $0.albumPosition != $1.albumPosition { return ($0.albumPosition ?? Int.max) < ($1.albumPosition ?? Int.max) }
                return $0.dateAdded == $1.dateAdded ? $0.id < $1.id : $0.dateAdded < $1.dateAdded
            }
            return LibraryGroup(id: record.id, title: record.title, subtitle: record.artistID.flatMap { artistNames[$0] } ?? "Unknown Artist", trackIDs: ordered.map(\.id), artworkRelativePath: record.artworkRelativePath ?? ordered.compactMap(\.artworkRelativePath).first)
        }.sorted { LibraryIdentity.normalized($0.title) == LibraryIdentity.normalized($1.title) ? $0.id < $1.id : LibraryIdentity.normalized($0.title) < LibraryIdentity.normalized($1.title) }
        let unassigned = tracks.filter { $0.albumID == nil }.sorted { $0.dateAdded == $1.dateAdded ? $0.id < $1.id : $0.dateAdded < $1.dateAdded }
        if !unassigned.isEmpty {
            groups.append(LibraryGroup(id: Self.unassignedAlbumID, title: "Unassigned Songs", subtitle: "No album assigned", trackIDs: unassigned.map(\.id), artworkRelativePath: nil))
        }
        return groups
    }
    static let unassignedAlbumID = "unassigned-songs"
}

struct AlbumDraft: Equatable, Sendable {
    var title: String
    var artist: String = ""
    var releaseYear: Int? = nil
    var description: String = ""
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
