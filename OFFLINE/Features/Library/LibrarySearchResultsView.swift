import SwiftUI

/// The Library filters and Your Library search use identical entities/destinations.
struct LibrarySearchResultsView: View {
    let results: LibrarySearchResults
    var scope: LibrarySearchScope = .all
    var contextKind: String = "search"
    var onInteraction: () -> Void = { }
    private var matches: LibrarySearchResults { results.restricted(to: scope) }
    var body: some View {
        let values = matches
        let songIDs = values.songs.map(\.id)
        LazyVStack(alignment: .leading, spacing: AppSpacing.lg) {
            if values.isEmpty {
                EmptyState(icon: "magnifyingglass", title: emptyTitle, message: results.query.isEmpty ? "Import music or create a playlist to get started." : "Try another title, artist, album or playlist.")
                    .accessibilityIdentifier("library-search-empty")
            }
            if !values.songs.isEmpty {
                heading(scope == .likedSongs ? "Liked Songs" : "Songs", count: values.songs.count, id: "songs")
                ForEach(values.songs) { track in
                    StoredTrackRow(track: track, contextTrackIDs: songIDs, contextKind: scope == .likedSongs ? "liked" : contextKind, onInteraction: onInteraction)
                }
            }
            if !values.albums.isEmpty {
                heading("Albums", count: values.albums.count, id: "albums")
                ForEach(values.albums) { group in
                    NavigationLink { AlbumDetailView(groupID: group.id) } label: { LibraryGroupRow(group: group) }
                        .accessibilityIdentifier("search-album-" + group.id)
                }
            }
            if !values.artists.isEmpty {
                heading("Artists", count: values.artists.count, id: "artists")
                ForEach(values.artists) { group in
                    NavigationLink { ArtistDetailView(groupID: group.id) } label: { LibraryGroupRow(group: group) }
                        .accessibilityIdentifier("search-artist-" + group.id)
                }
            }
            if !values.playlists.isEmpty {
                heading("Playlists", count: values.playlists.count, id: "playlists")
                ForEach(values.playlists) { playlist in
                    NavigationLink { PlaylistDetailView(playlistID: playlist.id) } label: { PlaylistLibraryRow(playlist: playlist) }
                        .accessibilityIdentifier("search-playlist-" + playlist.id)
                }
            }
        }
    }
    private var emptyTitle: String {
        guard results.query.isEmpty else { return "No library matches" }
        switch scope {
        case .playlists: return "No playlists"
        case .albums: return "No albums"
        case .artists: return "No artists"
        case .likedSongs: return "No liked songs"
        default: return "Your library is empty"
        }
    }
    private func heading(_ title: String, count: Int, id: String) -> some View {
        HStack {
            Text(title).font(.title3.weight(.semibold)).foregroundStyle(AppColors.textPrimary)
            Spacer(); Text("\(count)").font(.callout).foregroundStyle(AppColors.textSecondary)
        }.accessibilityElement(children: .combine).accessibilityIdentifier("search-section-" + id)
    }
}
