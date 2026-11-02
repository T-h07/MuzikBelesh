import SwiftUI

struct RootView: View {
    @EnvironmentObject private var container: AppContainer
    @EnvironmentObject private var audioPlayer: AudioPlayerService
    @ObservedObject var coordinator: AppCoordinator
    var body: some View {
        ZStack(alignment: .bottom) {
            TabView(selection: $coordinator.selectedTab) {
                NavigationStack { HomeView(coordinator: coordinator) }.tabItem { Label("Home", systemImage: "house.fill") }.tag(RootTab.home)
                NavigationStack { SearchView(coordinator: coordinator) }.tabItem { Label("Search", systemImage: "magnifyingglass") }.tag(RootTab.search)
                NavigationStack { LibraryView(coordinator: coordinator) }.tabItem { Label("Library", systemImage: "square.stack") }.tag(RootTab.library)
                NavigationStack { DownloadsView() }.tabItem { Label("Downloads", systemImage: "arrow.down.circle") }.tag(RootTab.downloads)
            }
            .tint(AppColors.accentPrimary)
            if audioPlayer.state.currentTrackID != nil { MiniPlayer(coordinator: coordinator) }
        }
        .preferredColorScheme(.dark)
        .sheet(item: $coordinator.sheet) { sheet in
            switch sheet { case .settings: SettingsView(); case .importLink: ImportLinkView(); case .sleepTimer: SleepTimerSheet() }
        }
        .fullScreenCover(isPresented: $coordinator.showingNowPlaying) { NowPlayingView(coordinator: coordinator) }
    }
}

struct TrackRow: View {
    @EnvironmentObject private var container: AppContainer
    let track: MockTrack
    var showDuration = true
    var body: some View {
        HStack(spacing: AppSpacing.md) {
            ArtworkView(name: track.artwork, size: 52)
            VStack(alignment: .leading, spacing: 3) { Text(track.title).font(.subheadline.weight(.semibold)).foregroundStyle(AppColors.textPrimary).lineLimit(1); Text(track.artist).font(.caption).foregroundStyle(AppColors.textSecondary).lineLimit(1) }
            Spacer()
            if container.music.likedTrackIDs.contains(track.id) { Image(systemName: "heart.fill").foregroundStyle(AppColors.accentPrimary).font(.caption) }
            if showDuration { Text(format(track.duration)).font(.caption).foregroundStyle(AppColors.textTertiary) }
            Menu { TrackContextMenu(track: track) } label: { Image(systemName: "ellipsis").foregroundStyle(AppColors.textSecondary).frame(width: 32, height: 40) }.accessibilityLabel("More actions for \(track.title)")
        }
        .contentShape(Rectangle())
        .onTapGesture { }
        .contextMenu { TrackContextMenu(track: track) }
        .accessibilityIdentifier("track-row-\(track.id)")
    }
    private func format(_ seconds: TimeInterval) -> String { String(format: "%d:%02d", Int(seconds) / 60, Int(seconds) % 60) }
}

struct TrackContextMenu: View {
    @EnvironmentObject private var container: AppContainer
    let track: MockTrack
    var body: some View {
        Button {} label: { Label("Import local audio to play", systemImage: "waveform") }
        Button { container.playback.addToQueue(track.id) } label: { Label("Add to Queue", systemImage: "text.badge.plus") }
        Button { container.music.toggleLiked(track.id) } label: { Label(container.music.likedTrackIDs.contains(track.id) ? "Unlike" : "Like", systemImage: "heart") }
        Button { container.music.add(track.id, to: "playlist-drive") } label: { Label("Add to Playlist", systemImage: "text.badge.plus") }
    }
}

struct AlbumCard: View {
    let album: MockAlbum
    var body: some View { VStack(alignment: .leading, spacing: AppSpacing.sm) { ArtworkView(name: album.artwork, size: 148); Text(album.title).font(.subheadline.weight(.semibold)).foregroundStyle(AppColors.textPrimary).lineLimit(1); Text(album.artist).font(.caption).foregroundStyle(AppColors.textSecondary).lineLimit(1) }.frame(width: 148, alignment: .leading) }
}

struct PlaylistCard: View {
    let playlist: MockPlaylist
    var body: some View { VStack(alignment: .leading, spacing: AppSpacing.sm) { ArtworkView(name: playlist.id, size: 148); Text(playlist.name).font(.subheadline.weight(.semibold)).foregroundStyle(AppColors.textPrimary).lineLimit(1); Text("\(playlist.trackIDs.count) tracks").font(.caption).foregroundStyle(AppColors.textSecondary) }.frame(width: 148, alignment: .leading) }
}

struct SearchBar: View {
    @Binding var text: String
    let placeholder: String
    var body: some View { HStack(spacing: AppSpacing.sm) { Image(systemName: "magnifyingglass").foregroundStyle(AppColors.textSecondary); TextField(placeholder, text: $text).textInputAutocapitalization(.never).autocorrectionDisabled().foregroundStyle(AppColors.textPrimary).accessibilityIdentifier("search-field"); if !text.isEmpty { Button { text = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(AppColors.textSecondary) }.accessibilityLabel("Clear search") } }.padding(.horizontal, AppSpacing.md).padding(.vertical, 11).background(AppColors.backgroundSecondary).clipShape(RoundedRectangle(cornerRadius: AppRadius.medium)) }
}

struct MiniPlayer: View {
    @EnvironmentObject private var container: AppContainer
    @EnvironmentObject private var audioPlayer: AudioPlayerService
    @ObservedObject var coordinator: AppCoordinator
    private var track: StoredTrack? { guard let storage = container.storage, let id = audioPlayer.state.currentTrackID else { return nil }; return try? storage.tracks.find(id: id) }
    var body: some View { if let track { HStack(spacing: AppSpacing.md) { StoredArtworkView(track: track, size: 42); VStack(alignment: .leading, spacing: 2) { Text(track.title).font(.caption.weight(.semibold)).foregroundStyle(AppColors.textPrimary).lineLimit(1); Text(track.originalFilename ?? "Local Music").font(.caption2).foregroundStyle(AppColors.textSecondary).lineLimit(1) }; Spacer(); Button { Task { await audioPlayer.togglePlayback() } } label: { Image(systemName: audioPlayer.state.isPlaying ? "pause.fill" : "play.fill").foregroundStyle(AppColors.textPrimary).frame(width: 44, height: 44) }.buttonStyle(.plain).accessibilityLabel(audioPlayer.state.isPlaying ? "Pause" : "Play"); Button { Task { await audioPlayer.next() } } label: { Image(systemName: "forward.fill").foregroundStyle(AppColors.textPrimary).frame(width: 44, height: 44) }.buttonStyle(.plain).accessibilityLabel("Next track") }.padding(.horizontal, AppSpacing.md).padding(.vertical, 6).background(.ultraThinMaterial).contentShape(Rectangle()).onTapGesture { coordinator.showingNowPlaying = true }.accessibilityIdentifier("mini-player") } }
}

struct ProgressRow: View {
    let job: MockDownloadJob
    var body: some View { HStack(spacing: AppSpacing.md) { ArtworkView(name: job.video.artwork, size: 58); VStack(alignment: .leading, spacing: 5) { Text(job.video.title).font(.subheadline.weight(.semibold)).foregroundStyle(AppColors.textPrimary).lineLimit(1); Text(job.state.rawValue.capitalized).font(.caption).foregroundStyle(job.state == .failed ? AppColors.error : AppColors.textSecondary); ProgressView(value: job.progress).tint(AppColors.accentPrimary) }; Spacer(); Text("\(Int(job.progress * 100))%").font(.caption).foregroundStyle(AppColors.textSecondary) }.padding(.vertical, 6) }
}

struct YouTubeResultRow: View {
    let video: MockVideo
    var body: some View { HStack(spacing: AppSpacing.md) { ArtworkView(name: video.artwork, size: 112); VStack(alignment: .leading, spacing: 5) { Text(video.title).font(.subheadline.weight(.semibold)).foregroundStyle(AppColors.textPrimary).lineLimit(2); Text(video.channel).font(.caption).foregroundStyle(AppColors.textSecondary); Text(video.duration).font(.caption2).foregroundStyle(AppColors.textTertiary) }; Spacer() }.padding(.vertical, 5) }
}

