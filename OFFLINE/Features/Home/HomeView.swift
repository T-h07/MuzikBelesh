import SwiftUI

struct HomeView: View {
    @EnvironmentObject private var library: MusicLibraryService
    @EnvironmentObject private var audioPlayer: AudioPlayerService
    @ObservedObject var coordinator: AppCoordinator
    private var currentTrack: StoredTrack? { library.track(audioPlayer.state.currentTrackID) ?? library.snapshot.tracks.first }
    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: AppSpacing.section) {
                HStack {
                    Text("Muzik Belesh").font(.system(size: 28, weight: .bold)).foregroundStyle(AppColors.textPrimary)
                    Spacer(); Button { coordinator.sheet = .settings } label: { Image(systemName: "gearshape").font(.title3).frame(width: 44, height: 44) }.accessibilityLabel("Settings")
                }
                if let track = currentTrack {
                    VStack(alignment: .leading, spacing: AppSpacing.md) {
                        Text("CONTINUE LISTENING").font(.caption.weight(.semibold)).foregroundStyle(AppColors.accentPrimary)
                        HStack(spacing: AppSpacing.md) {
                            StoredArtworkView(track: track, size: 100)
                            VStack(alignment: .leading, spacing: 8) {
                                Text(track.title).font(.headline).foregroundStyle(AppColors.textPrimary).lineLimit(2)
                                Text(library.artistName(track.artistID)).font(.subheadline).foregroundStyle(AppColors.textSecondary).lineLimit(1)
                                Button("Open Player") {
                                    Task {
                                        if audioPlayer.state.currentTrackID == nil { await library.play(track.id, ids: library.snapshot.tracks.map(\.id), kind: "library") }
                                        coordinator.showingNowPlaying = true
                                    }
                                }.buttonStyle(.borderedProminent).tint(AppColors.accentPrimary).foregroundStyle(.black)
                            }
                        }
                    }.cardSurface()
                } else { EmptyState(icon: "music.note", title: "Your library is ready", message: "Import local audio to start listening.", actionTitle: "Import Audio") { coordinator.selectedTab = .library } }
                SectionHeader(title: "Quick shortcuts")
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: AppSpacing.md)], spacing: AppSpacing.md) {
                    shortcut("Liked Songs", "heart.fill", "Liked Songs")
                    shortcut("Playlists", "rectangle.stack.fill", "Playlists")
                    shortcut("Albums", "square.stack", "Albums")
                    shortcut("All Music", "music.note.list", "Songs")
                }
                SectionHeader(title: "Recently Played")
                if library.snapshot.recentIDs.isEmpty { Text("Play a local song to see it here.").foregroundStyle(AppColors.textSecondary) }
                ForEach(library.tracks(library.snapshot.recentIDs)) { StoredTrackRow(track: $0, contextTrackIDs: library.snapshot.recentIDs, contextKind: "recent") }
                SectionHeader(title: "Your Playlists")
                ForEach(library.snapshot.playlists.prefix(5)) { playlist in
                    NavigationLink { PlaylistDetailView(playlistID: playlist.id) } label: { PlaylistLibraryRow(playlist: playlist) }
                }
            }.padding(.horizontal, AppSpacing.lg).padding(.top, AppSpacing.md).padding(.bottom, 30)
        }.navigationBarHidden(true).screenBackground()
    }
    private func shortcut(_ title: String, _ icon: String, _ filter: String) -> some View {
        Button { coordinator.libraryFilter = filter; coordinator.selectedTab = .library } label: {
            HStack { Image(systemName: icon).foregroundStyle(AppColors.accentPrimary); Text(title).font(.subheadline).lineLimit(1); Spacer(); Image(systemName: "chevron.right").font(.caption) }.padding(AppSpacing.md).frame(minHeight: 52).background(AppColors.backgroundSecondary).clipShape(RoundedRectangle(cornerRadius: AppRadius.medium))
        }.foregroundStyle(AppColors.textPrimary)
    }
}
