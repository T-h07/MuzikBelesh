import SwiftUI

enum LibrarySearchField: Hashable { case search, library }

struct RootView: View {
    @Environment(\.scenePhase) private var scenePhase
    @EnvironmentObject private var container: AppContainer
    @EnvironmentObject private var audioPlayer: AudioPlayerService
    @EnvironmentObject private var library: MusicLibraryService
    @ObservedObject var coordinator: AppCoordinator
    @FocusState private var searchFocus: LibrarySearchField?
    @State private var keyboardTop: CGFloat?
    var body: some View {
        GeometryReader { available in
            let origin = available.frame(in: .global).minY
            let height = keyboardTop.map { min(available.size.height, max(0, $0 - origin)) } ?? available.size.height
            TabView(selection: $coordinator.selectedTab) {
                TabContent(coordinator: coordinator) { NavigationStack { HomeView(coordinator: coordinator) } }.tabItem { Label("Home", systemImage: "house.fill") }.tag(RootTab.home)
                TabContent(coordinator: coordinator, onPresent: { searchFocus = nil }) { NavigationStack { SearchView(coordinator: coordinator, searchFocus: $searchFocus) } }.tabItem { Label("Search", systemImage: "magnifyingglass") }.tag(RootTab.search)
                TabContent(coordinator: coordinator, onPresent: { searchFocus = nil }) { NavigationStack { LibraryView(coordinator: coordinator, searchFocus: $searchFocus) } }.tabItem { Label("Library", systemImage: "square.stack") }.tag(RootTab.library)
                TabContent(coordinator: coordinator) { NavigationStack { DownloadsView() } }.tabItem { Label("Downloads", systemImage: "arrow.down.circle") }.tag(RootTab.downloads)
            }
            .frame(width: available.size.width, height: height)
        }
        .ignoresSafeArea(.keyboard, edges: .bottom)
        .background { KeyboardLayoutRegion { keyboardTop = $0 }.ignoresSafeArea().allowsHitTesting(false) }
        .tint(AppColors.accentPrimary)
        .onChange(of: coordinator.selectedTab) { _, _ in searchFocus = nil }
        .onChange(of: coordinator.showingNowPlaying) { _, presented in if presented { searchFocus = nil } }
        .onChange(of: coordinator.sheet?.id) { _, presented in if presented != nil { searchFocus = nil } }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { audioPlayer.reconcileLifecycle(); Task { await library.reconcileFiles() } }
            else { searchFocus = nil }
        }
        .preferredColorScheme(.dark)
        .alert("Library", isPresented: Binding(get: { library.error != nil }, set: { if !$0 { library.error = nil } })) {
            Button("OK") { library.error = nil }
            Button("Retry Recovery") { Task { await library.reconcileFiles() } }
        } message: { Text(library.error ?? "") }
        .sheet(item: $coordinator.sheet) { sheet in
            switch sheet { case .settings: SettingsView(); case .importLink: ImportLinkView(); case .sleepTimer: SleepTimerSheet(timer: audioPlayer.sleepTimer).presentationDetents([.height(390)]) }
        }
        .fullScreenCover(isPresented: $coordinator.showingNowPlaying) { NowPlayingView(coordinator: coordinator) }
    }
}

private struct TabContent<Content: View>: View {
    @EnvironmentObject private var audioPlayer: AudioPlayerService
    let coordinator: AppCoordinator
    let content: Content
    let onPresent: () -> Void
    @State private var showingTimer = false

    init(coordinator: AppCoordinator, onPresent: @escaping () -> Void = { }, @ViewBuilder content: () -> Content) {
        self.coordinator = coordinator
        self.onPresent = onPresent
        self.content = content()
    }

    var body: some View {
        content.safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(spacing: AppSpacing.xs) {
                SleepTimerStatusIndicator(timer: audioPlayer.sleepTimer, showsLabel: true) { onPresent(); showingTimer = true }
                if audioPlayer.state.currentTrackID != nil { MiniPlayer(coordinator: coordinator).padding(.horizontal, AppSpacing.sm) }
            }.padding(.top, AppSpacing.sm)
        }
        .sheet(isPresented: $showingTimer) { SleepTimerSheet(timer: audioPlayer.sleepTimer).presentationDetents([.height(390)]) }
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
        Button {} label: { Label("Demo track · import local audio to play", systemImage: "waveform") }.disabled(true)
        Button { container.playback.addToQueue(track.id) } label: { Label("Add to Demo Queue", systemImage: "text.badge.plus") }
        Button { container.music.toggleLiked(track.id) } label: { Label(container.music.likedTrackIDs.contains(track.id) ? "Unlike" : "Like", systemImage: "heart") }
        Button { container.music.add(track.id, to: "playlist-drive") } label: { Label("Add to Demo Playlist", systemImage: "text.badge.plus") }
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
    @FocusState.Binding var focus: LibrarySearchField?
    let field: LibrarySearchField
    var body: some View {
        HStack(spacing: AppSpacing.sm) {
            Image(systemName: "magnifyingglass").foregroundStyle(AppColors.textSecondary)
            TextField(placeholder, text: $text)
                .focused($focus, equals: field).submitLabel(.search).onSubmit { focus = nil }
                .textInputAutocapitalization(.never).autocorrectionDisabled().foregroundStyle(AppColors.textPrimary).accessibilityIdentifier("search-field")
            if !text.isEmpty {
                Button { text = ""; focus = nil } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(AppColors.textSecondary).frame(minWidth: 44, minHeight: 22) }.accessibilityLabel("Clear search")
            }
        }.padding(.horizontal, AppSpacing.md).padding(.vertical, 11).background(AppColors.backgroundSecondary).clipShape(RoundedRectangle(cornerRadius: AppRadius.medium))
            .toolbar {
                if focus == field {
                    ToolbarItemGroup(placement: .keyboard) {
                        Spacer()
                        Button("Done") { focus = nil }.accessibilityIdentifier("keyboard-done")
                    }
                }
            }
    }
}

struct MiniPlayer: View {
    @EnvironmentObject private var container: AppContainer
    @EnvironmentObject private var audioPlayer: AudioPlayerService
    @EnvironmentObject private var library: MusicLibraryService
    @ObservedObject var coordinator: AppCoordinator
    private var track: StoredTrack? { library.track(audioPlayer.state.currentTrackID) }
    var body: some View { if let track { HStack(spacing: AppSpacing.xs) {
        Button { coordinator.showingNowPlaying = true } label: { HStack(spacing: AppSpacing.sm) { StoredArtworkView(track: track, size: 44); VStack(alignment: .leading, spacing: 2) { Text(track.title).font(.caption.weight(.semibold)).foregroundStyle(AppColors.textPrimary).lineLimit(1); Text(library.artistName(track.artistID)).font(.caption2).foregroundStyle(AppColors.textSecondary).lineLimit(1) } }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle()) }.buttonStyle(.plain).accessibilityLabel("Open Now Playing")
        Button { Task { await audioPlayer.previous() } } label: { Image(systemName: "backward.fill").foregroundStyle(AppColors.textPrimary).frame(width: 44, height: 44) }.buttonStyle(.plain).disabled(!audioPlayer.state.canSkipPrevious && audioPlayer.state.elapsedTime <= 3).accessibilityLabel("Previous track")
        Button { Task { await audioPlayer.togglePlayback() } } label: { Image(systemName: audioPlayer.state.isPlaying ? "pause.fill" : "play.fill").foregroundStyle(AppColors.textPrimary).frame(width: 44, height: 44) }.buttonStyle(.plain).accessibilityLabel(audioPlayer.state.isPlaying ? "Pause" : "Play")
        Button { Task { await audioPlayer.next() } } label: { Image(systemName: "forward.fill").foregroundStyle(AppColors.textPrimary).frame(width: 44, height: 44) }.buttonStyle(.plain).disabled(!audioPlayer.state.canSkipNext).accessibilityLabel("Next track")
    }.padding(.horizontal, AppSpacing.sm).padding(.vertical, AppSpacing.xs).background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: AppRadius.medium)).accessibilityIdentifier("mini-player") } }
}

struct ProgressRow: View {
    let job: MockDownloadJob
    var body: some View { HStack(spacing: AppSpacing.md) { ArtworkView(name: job.video.artwork, size: 58); VStack(alignment: .leading, spacing: 5) { Text(job.video.title).font(.subheadline.weight(.semibold)).foregroundStyle(AppColors.textPrimary).lineLimit(1); Text(job.state.rawValue.capitalized).font(.caption).foregroundStyle(job.state == .failed ? AppColors.error : AppColors.textSecondary); ProgressView(value: job.progress).tint(AppColors.accentPrimary) }; Spacer(); Text("\(Int(job.progress * 100))%").font(.caption).foregroundStyle(AppColors.textSecondary) }.padding(.vertical, 6) }
}

struct YouTubeResultRow: View {
    let video: MockVideo
    var body: some View { HStack(spacing: AppSpacing.md) { ArtworkView(name: video.artwork, size: 112); VStack(alignment: .leading, spacing: 5) { Text(video.title).font(.subheadline.weight(.semibold)).foregroundStyle(AppColors.textPrimary).lineLimit(2); Text(video.channel).font(.caption).foregroundStyle(AppColors.textSecondary); Text(video.duration).font(.caption2).foregroundStyle(AppColors.textTertiary) }; Spacer() }.padding(.vertical, 5) }
}

