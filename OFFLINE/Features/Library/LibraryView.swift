import SwiftUI

struct LibraryView: View {
    @EnvironmentObject private var container: AppContainer
    @ObservedObject var coordinator: AppCoordinator
    let filters = ["All", "Songs", "Albums", "Artists", "Playlists"]
    var body: some View { ScrollView { VStack(alignment: .leading, spacing: AppSpacing.xl) { Text("Library").font(.system(size: 28, weight: .bold)).foregroundStyle(AppColors.textPrimary); ScrollView(.horizontal, showsIndicators: false) { HStack { ForEach(filters, id: \.self) { filter in FilterChip(title: filter, selected: coordinator.libraryFilter == filter) { coordinator.libraryFilter = filter } } } }; content }.padding(.horizontal, AppSpacing.xl).padding(.top, AppSpacing.lg).padding(.bottom, 100) }.navigationBarHidden(true).screenBackground() }
    @ViewBuilder private var content: some View { switch coordinator.libraryFilter { case "Albums": LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: AppSpacing.xl) { ForEach(container.music.albums) { album in NavigationLink { AlbumDetailView(album: album) } label: { AlbumCard(album: album) } } }; case "Artists": ForEach(container.music.artists) { artist in NavigationLink { ArtistDetailView(artist: artist) } label: { HStack { ArtworkView(name: artist.artwork, size: 56); Text(artist.name).foregroundStyle(AppColors.textPrimary); Spacer(); Text("\(artist.trackIDs.count) songs").font(.caption).foregroundStyle(AppColors.textSecondary) } } }; case "Playlists": ForEach(container.music.playlists) { playlist in NavigationLink { PlaylistDetailView(playlistID: playlist.id) } label: { HStack { ArtworkView(name: playlist.id, size: 64); VStack(alignment: .leading) { Text(playlist.name).foregroundStyle(AppColors.textPrimary); Text("\(playlist.trackIDs.count) tracks").font(.caption).foregroundStyle(AppColors.textSecondary) }; Spacer(); Image(systemName: "chevron.right").foregroundStyle(AppColors.textTertiary) } } }; default: if container.music.tracks.isEmpty { EmptyState(icon: "music.note", title: "Your library is empty", message: "Mock tracks will appear here.") } else { ForEach(container.music.tracks) { track in NavigationLink { TrackEditorView(trackID: track.id) } label: { TrackRow(track: track) } } } } }
}

struct PlaylistDetailView: View {
    @EnvironmentObject private var container: AppContainer
    let playlistID: String
    @State private var showingEditor = false
    var body: some View { let playlist = container.music.playlists.first { $0.id == playlistID }; ScrollView { VStack(alignment: .leading, spacing: AppSpacing.lg) { if let playlist { ArtworkView(name: playlist.id, size: 220).frame(maxWidth: .infinity); Text(playlist.name).font(.title.bold()).foregroundStyle(AppColors.textPrimary); Text(playlist.description).foregroundStyle(AppColors.textSecondary); ForEach(playlist.trackIDs.compactMap { container.music.track($0) }) { TrackRow(track: $0) } } }.padding(AppSpacing.xl).padding(.bottom, 100) }.navigationTitle("Playlist").navigationBarTitleDisplayMode(.inline).toolbar { ToolbarItem(placement: .primaryAction) { Button { showingEditor = true } label: { Image(systemName: "pencil") }.accessibilityLabel("Edit Playlist") } }.screenBackground().sheet(isPresented: $showingEditor) { PlaylistEditorView(playlistID: playlistID) } }
}

