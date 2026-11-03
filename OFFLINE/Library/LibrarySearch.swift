import Foundation
import Combine

enum LibrarySearchScope: String, CaseIterable, Sendable {
    case all = "All", songs = "Songs", albums = "Albums", artists = "Artists", playlists = "Playlists", likedSongs = "Liked Songs"
}

struct LibrarySearchResults: Equatable, Sendable {
    var query: String
    var songs: [StoredTrack]
    var albums: [LibraryGroup]
    var artists: [LibraryGroup]
    var playlists: [StoredPlaylist]
    var likedIDs: Set<String>
    var isEmpty: Bool { songs.isEmpty && albums.isEmpty && artists.isEmpty && playlists.isEmpty }

    func restricted(to scope: LibrarySearchScope) -> Self {
        var result = self
        if scope != .all {
            if scope != .songs && scope != .likedSongs { result.songs = [] }
            if scope != .albums { result.albums = [] }
            if scope != .artists { result.artists = [] }
            if scope != .playlists { result.playlists = [] }
            if scope == .likedSongs { result.songs = result.songs.filter { likedIDs.contains($0.id) } }
        }
        return result
    }
}

/// Searches a consistent immutable snapshot of persisted records away from UI work.
/// String containment deliberately treats SQL wildcard characters as literal text.
enum LibrarySearchEngine {
    static func normalizedQuery(_ query: String) -> String { String(LibraryIdentity.search(query).prefix(500)) }
    static func search(_ query: String, in snapshot: LibrarySnapshot) -> LibrarySearchResults {
        let term = normalizedQuery(query)
        func matches(_ text: String) -> Bool { term.isEmpty || LibraryIdentity.search(text).contains(term) }
        let artists = Dictionary(uniqueKeysWithValues: snapshot.artists.map { ($0.id, $0.name) })
        let albums = Dictionary(uniqueKeysWithValues: snapshot.albums.map { ($0.id, $0.title) })
        let songs = snapshot.tracks.filter {
            matches([$0.title, $0.artistID.flatMap { artists[$0] } ?? "Unknown Artist", $0.albumID.flatMap { albums[$0] } ?? "Unknown Album", $0.albumArtist ?? ""].joined(separator: " "))
        }
        return LibrarySearchResults(query: term, songs: songs,
            albums: snapshot.albumGroups.filter { matches($0.title + " " + $0.subtitle) },
            artists: snapshot.artistGroups.filter { matches($0.title) },
            playlists: snapshot.playlists.filter { matches($0.name + " " + ($0.description ?? "")) }, likedIDs: snapshot.likedIDs)
    }
}

struct LibrarySearchRequest: Hashable {
    let query: String
    let revision: Int
}

/// Each surface has independent query state but shares semantics and stale-result
/// protection. A cancelled/older computation can never replace a newer response.
@MainActor final class LibrarySearchSession: ObservableObject {
    typealias Operation = @Sendable (String, LibrarySnapshot) async -> LibrarySearchResults
    @Published private(set) var results: LibrarySearchResults?
    private var generation = 0
    private let operation: Operation

    init(operation: @escaping Operation = { query, snapshot in
        await Task.detached(priority: .userInitiated) { LibrarySearchEngine.search(query, in: snapshot) }.value
    }) { self.operation = operation }

    func update(query: String, snapshot: LibrarySnapshot, debounce: Bool = true) async {
        generation += 1
        let request = generation
        let changedQuery = results?.query != LibrarySearchEngine.normalizedQuery(query)
        if changedQuery { results = nil }
        if debounce && changedQuery && !LibraryIdentity.search(query).isEmpty {
            do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
        }
        guard !Task.isCancelled else { return }
        let value = await operation(query, snapshot)
        guard !Task.isCancelled, generation == request else { return }
        results = value
    }
}
