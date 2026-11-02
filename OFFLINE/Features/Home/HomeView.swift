import SwiftUI

struct HomeView: View {
    @EnvironmentObject private var container: AppContainer
    @ObservedObject var coordinator: AppCoordinator
    var body: some View { ScrollView { VStack(alignment: .leading, spacing: AppSpacing.section) {
        HStack { Text("Muzik Belesh").font(.system(size: 28, weight: .bold)).foregroundStyle(AppColors.textPrimary); Spacer(); Button { coordinator.sheet = .settings } label: { Image(systemName: "gearshape").font(.title3).foregroundStyle(AppColors.textPrimary) }.accessibilityLabel("Settings") }
        if let track = container.music.track(container.playback.currentTrackID ?? "track-neon") { VStack(alignment: .leading, spacing: AppSpacing.md) { Text("CONTINUE LISTENING").font(.caption.weight(.semibold)).tracking(1).foregroundStyle(AppColors.accentPrimary); HStack(spacing: AppSpacing.lg) { ArtworkView(name: track.artwork, size: 132); VStack(alignment: .leading, spacing: AppSpacing.sm) { Text(track.title).font(.title3.weight(.bold)).foregroundStyle(AppColors.textPrimary); Text(track.artist).foregroundStyle(AppColors.textSecondary); Button { container.playback.select(track.id) } label: { Label("Play", systemImage: "play.fill").foregroundStyle(.black).padding(.horizontal, 16).padding(.vertical, 9).background(AppColors.accentPrimary).clipShape(Capsule()) } } }.padding(AppSpacing.lg).background(AppColors.backgroundSecondary).clipShape(RoundedRectangle(cornerRadius: AppRadius.card)) } }
        SectionHeader(title: "Quick shortcuts")
        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: AppSpacing.md) { shortcut("Liked Songs", "heart.fill", .library); shortcut("Playlists", "rectangle.stack.fill", .library); shortcut("Downloaded", "arrow.down.circle.fill", .downloads); shortcut("All Music", "music.note.list", .library) }
        SectionHeader(title: "Recently Played")
        if container.music.recentlyPlayedIDs.isEmpty { EmptyState(icon: "clock", title: "Nothing played yet", message: "Choose a track to start your session.") } else { ForEach(container.music.recentlyPlayedIDs.compactMap { container.music.track($0) }) { TrackRow(track: $0) } }
        SectionHeader(title: "Your Collection")
        ScrollView(.horizontal, showsIndicators: false) { HStack(spacing: AppSpacing.lg) { ForEach(container.music.albums) { AlbumCard(album: $0) }; ForEach(container.music.playlists) { PlaylistCard(playlist: $0) } } }
    }.padding(.horizontal, AppSpacing.xl).padding(.top, AppSpacing.lg).padding(.bottom, 100) }.navigationBarHidden(true).screenBackground() }
    private func shortcut(_ title: String, _ icon: String, _ tab: RootTab) -> some View { Button { coordinator.selectedTab = tab } label: { HStack { Image(systemName: icon).foregroundStyle(AppColors.accentPrimary); Text(title).font(.subheadline.weight(.medium)).foregroundStyle(AppColors.textPrimary); Spacer(); Image(systemName: "chevron.right").font(.caption).foregroundStyle(AppColors.textTertiary) }.padding(AppSpacing.lg).background(AppColors.backgroundSecondary).clipShape(RoundedRectangle(cornerRadius: AppRadius.medium)) } }
}

