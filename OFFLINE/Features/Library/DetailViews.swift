import SwiftUI

struct AlbumDetailView: View {
    @EnvironmentObject private var container: AppContainer
    let album: MockAlbum
    var body: some View { ScrollView { VStack(alignment: .leading, spacing: AppSpacing.lg) { ArtworkView(name: album.artwork, size: 220).frame(maxWidth: .infinity); Text(album.title).font(.title.bold()).foregroundStyle(AppColors.textPrimary); Text(album.artist).foregroundStyle(AppColors.textSecondary); ForEach(album.trackIDs.compactMap { container.music.track($0) }) { TrackRow(track: $0) } }.padding(AppSpacing.xl).padding(.bottom, 100) }.navigationTitle("Album").navigationBarTitleDisplayMode(.inline).screenBackground() }
}

struct ArtistDetailView: View {
    @EnvironmentObject private var container: AppContainer
    let artist: MockArtist
    var body: some View { ScrollView { VStack(alignment: .leading, spacing: AppSpacing.lg) { ArtworkView(name: artist.artwork, size: 180).frame(maxWidth: .infinity); Text(artist.name).font(.title.bold()).foregroundStyle(AppColors.textPrimary); Text("Top tracks").font(.headline).foregroundStyle(AppColors.textPrimary); ForEach(artist.trackIDs.compactMap { container.music.track($0) }) { TrackRow(track: $0) } }.padding(AppSpacing.xl).padding(.bottom, 100) }.navigationTitle("Artist").navigationBarTitleDisplayMode(.inline).screenBackground() }
}

struct PlaylistEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var container: AppContainer
    let playlistID: String
    @State private var name = ""
    var body: some View { NavigationStack { Form { TextField("Playlist name", text: $name) }.navigationTitle("Edit Playlist").toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }; ToolbarItem(placement: .confirmationAction) { Button("Save") { container.music.renamePlaylist(playlistID, name: name); dismiss() } } } } .onAppear { name = container.music.playlists.first { $0.id == playlistID }?.name ?? "" } }
}

struct TrackEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var container: AppContainer
    let trackID: String
    @State private var title = ""
    @State private var artist = ""
    var body: some View { NavigationStack { Form { TextField("Title", text: $title); TextField("Artist", text: $artist) }.navigationTitle("Edit Track").toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }; ToolbarItem(placement: .confirmationAction) { Button("Save") { container.music.editTrack(trackID, title: title, artist: artist); dismiss() } } } }.onAppear { if let track = container.music.track(trackID) { title = track.title; artist = track.artist } } }
}
