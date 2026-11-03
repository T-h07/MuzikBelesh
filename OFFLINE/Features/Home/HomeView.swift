import SwiftUI

struct HomeView: View {
    @EnvironmentObject private var container: AppContainer
    @EnvironmentObject private var audioPlayer: AudioPlayerService
    @ObservedObject var coordinator: AppCoordinator
    var body: some View { ScrollView { VStack(alignment: .leading, spacing: AppSpacing.section) {
        HStack { Text("Muzik Belesh").font(.system(size: 28, weight: .bold)).foregroundStyle(AppColors.textPrimary); Spacer(); Button { coordinator.sheet = .settings } label: { Image(systemName: "gearshape").font(.title3).foregroundStyle(AppColors.textPrimary) }.accessibilityLabel("Settings") }
        if let track = currentTrack { VStack(alignment: .leading, spacing: AppSpacing.md) { Text("CONTINUE LISTENING").font(.caption.weight(.semibold)).tracking(1).foregroundStyle(AppColors.accentPrimary); HStack(spacing: AppSpacing.lg) { StoredArtworkView(track: track, size: 112); VStack(alignment: .leading, spacing: AppSpacing.sm) { Text(track.title).font(.title3.weight(.bold)).foregroundStyle(AppColors.textPrimary).lineLimit(2); Text(track.originalFilename ?? "Local Music").foregroundStyle(AppColors.textSecondary).lineLimit(1); Button { coordinator.showingNowPlaying = true } label: { Label("Open player", systemImage: "play.fill").font(.caption).foregroundStyle(.black).padding(.horizontal, 12).padding(.vertical, 9).background(AppColors.accentPrimary).clipShape(Capsule()) } } }.padding(AppSpacing.lg).background(AppColors.backgroundSecondary).clipShape(RoundedRectangle(cornerRadius: AppRadius.card)) } } else { EmptyState(icon: "music.note", title: "Your library is ready", message: "Import local audio to start listening.", actionTitle: "Import Audio") { coordinator.selectedTab = .library } }
        SectionHeader(title: "Quick shortcuts")
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: AppSpacing.md)], spacing: AppSpacing.md) { shortcut("Liked Songs", "heart.fill", .library); shortcut("Playlists", "rectangle.stack.fill", .library); shortcut("Downloaded", "arrow.down.circle.fill", .downloads); shortcut("All Music", "music.note.list", .library) }
        SectionHeader(title: "Demo Recently Played")
        if container.music.recentlyPlayedIDs.isEmpty { EmptyState(icon: "clock", title: "Nothing played yet", message: "Choose a track to start your session.") } else { ForEach(container.music.recentlyPlayedIDs.compactMap { container.music.track($0) }) { TrackRow(track: $0) } }
        SectionHeader(title: "Demo Collection")
        ScrollView(.horizontal, showsIndicators: false) { HStack(spacing: AppSpacing.lg) { ForEach(container.music.albums) { AlbumCard(album: $0) }; ForEach(container.music.playlists) { PlaylistCard(playlist: $0) } } }
    }.padding(.horizontal, AppSpacing.lg).padding(.top, AppSpacing.md).padding(.bottom, 100) }.navigationBarHidden(true).screenBackground() }
    private var currentTrack: StoredTrack? {
        guard let storage = container.storage else { return nil }
        if let id = audioPlayer.state.currentTrackID { return try? storage.tracks.find(id: id) }
        return storage.library.first
    }
    private func shortcut(_ title: String, _ icon: String, _ tab: RootTab) -> some View { Button { coordinator.selectedTab = tab } label: { HStack(spacing: AppSpacing.sm) { Image(systemName: icon).foregroundStyle(AppColors.accentPrimary); Text(title).font(.subheadline.weight(.medium)).foregroundStyle(AppColors.textPrimary).lineLimit(1).minimumScaleFactor(0.85); Spacer(minLength: AppSpacing.xs); Image(systemName: "chevron.right").font(.caption).foregroundStyle(AppColors.textTertiary) }.padding(.horizontal, AppSpacing.md).frame(minHeight: 52).background(AppColors.backgroundSecondary).clipShape(RoundedRectangle(cornerRadius: AppRadius.medium)) } }
}

