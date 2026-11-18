import Combine
import SwiftUI

enum LibrarySearchField: Hashable { case search, library }

struct RootView: View {
    @EnvironmentObject private var container: AppContainer
    @Environment(\.scenePhase) private var scenePhase
    let coordinator: AppCoordinator
    var body: some View {
        KeyboardSafeHost(content: ThemeRoot(theme: container.theme, content: ProfileGate(scenePhase: scenePhase, coordinator: coordinator, profile: container.profile)
            .environmentObject(container)
            .environmentObject(coordinator)
            .environmentObject(container.audioPlayer)
            .environmentObject(container.library)
            .environmentObject(container.profile)
            .environmentObject(container.listening)
            .environmentObject(container.collectionArtwork)))
            .ignoresSafeArea().preferredColorScheme(.dark)
            // Phase 11.4: a `.mbelesh` file opened from Files, Mail or AirDrop is staged
            // privately at once; the tab interface presents it after the profile gate.
            .onOpenURL { url in container.sharing.receive(url) }
    }
}

/// Phase 11.1 launch gate. The destination is resolved from a committed profile read in
/// `AppContainer`, so the tabs never appear before onboarding. The tab interface (and its
/// share-inbox delivery) mounts only after a profile exists; pending shares wait in the App
/// Group inbox meanwhile. App lifecycle forwarding lives here so it keeps running during
/// onboarding: downloads, playback and migrations are never paused by the profile flow.
private struct ProfileGate: View {
    let scenePhase: ScenePhase
    let coordinator: AppCoordinator
    @ObservedObject var profile: LocalProfileService
    @EnvironmentObject private var container: AppContainer
    @EnvironmentObject private var audioPlayer: AudioPlayerService
    @EnvironmentObject private var library: MusicLibraryService
    var body: some View {
        Group {
            switch profile.launchDestination {
            case .loading: ProgressView().tint(AppColors.textSecondary).frame(maxWidth: .infinity, maxHeight: .infinity).screenBackground()
            case .onboarding: LocalProfileOnboardingView()
            case .failure(let message): ProfileStorageErrorView(message: message)
            case .main: RootTabsView(scenePhase: scenePhase, coordinator: coordinator)
            }
        }
        .preferredColorScheme(.dark)
        .onChange(of: scenePhase) { _, phase in
            if phase != .inactive {
                if let coordinator = container.migrationCoordinator {
                    let active = phase == .active
                    Task {
                        if active { await coordinator.applicationDidBecomeActive() }
                        else { await coordinator.applicationDidEnterBackground() }
                    }
                } else { container.playlistMatching?.setForeground(phase == .active) }
            }
            if phase != .active { container.theme.commitCustomColor() }
            // Artwork rotation and decoding pause in the background; nothing wakes the app for it.
            if phase != .inactive { container.collectionArtwork.setForeground(phase == .active) }
            if phase != .inactive { container.downloads.setForeground(phase == .active); audioPlayer.setForeground(phase == .active) }
            if phase == .active {
                audioPlayer.reconcileLifecycle(); Task { await library.reconcileFiles() }; container.playlistAcquisition?.requestReconcile()
                container.migrationIssues?.applicationDidBecomeActive()
            }
        }
    }
}

private struct RootTabsView: View {
    @Environment(\.themePalette) private var palette
    let scenePhase: ScenePhase
    @EnvironmentObject private var container: AppContainer
    @EnvironmentObject private var audioPlayer: AudioPlayerService
    @EnvironmentObject private var library: MusicLibraryService
    @ObservedObject var coordinator: AppCoordinator
    @State private var shareRevision = 0
    @State private var shareReadFailed = false
    @State private var inboxRevision = 0
    @FocusState private var searchFocus: LibrarySearchField?
    var body: some View {
        TabView(selection: $coordinator.selectedTab) {
                TabContent(coordinator: coordinator) { NavigationStack { HomeView(coordinator: coordinator) } }.tabItem { Label("Home", systemImage: "house.fill") }.tag(RootTab.home)
                TabContent(coordinator: coordinator, onPresent: { searchFocus = nil }) { NavigationStack { SearchView(coordinator: coordinator, searchFocus: $searchFocus) } }.tabItem { Label("Search", systemImage: "magnifyingglass") }.tag(RootTab.search)
                TabContent(coordinator: coordinator, onPresent: { searchFocus = nil }) { NavigationStack { LibraryView(coordinator: coordinator, searchFocus: $searchFocus) } }.tabItem { Label("Library", systemImage: "square.stack") }.tag(RootTab.library)
                TabContent(coordinator: coordinator) { NavigationStack { DownloadsView(manager: container.downloads) } }.tabItem { Label("Downloads", systemImage: "arrow.down.circle") }.tag(RootTab.downloads)
        }
        .tint(palette.accent)
        .onChange(of: coordinator.selectedTab) { _, _ in searchFocus = nil }
        .onChange(of: coordinator.showingNowPlaying) { _, presented in if presented { searchFocus = nil } }
        .onChange(of: coordinator.sheet?.id) { _, presented in if presented != nil { searchFocus = nil } }
        // Lifecycle forwarding is in ProfileGate, which stays mounted during onboarding.
        .onChange(of: scenePhase) { _, phase in if phase != .active { searchFocus = nil } }
        .preferredColorScheme(.dark)
        .alert("Library", isPresented: Binding(get: { library.error != nil }, set: { if !$0 { library.error = nil } })) {
            Button("OK") { library.error = nil }
            Button("Retry Recovery") { Task { await library.reconcileFiles() } }
        } message: { Text(library.error ?? "") }
        .task(id: "\(scenePhase)-\(shareRevision)") {
            guard scenePhase == .active else { return }
            if let coordinator = container.migrationCoordinator { await coordinator.restoreUnfinishedMigrations() }
            else { await container.playlistMatching?.restoreIfNeeded() }
            do {
                guard let share = try await coordinator.shareHandoff.next() else { return }
                // A library editor, document picker, or nested sheet may own the presentation.
                // Wait only while a real delivery is pending. The scene task cancels on background.
                while coordinator.sheet != nil || coordinator.showingNowPlaying || Self.hasModal {
                    try await Task.sleep(for: .milliseconds(350))
                }
                try Task.checkCancellation()
                coordinator.sheet = .sharedLink(share)
            } catch is CancellationError { }
            catch SharedLinkInbox.Failure.unavailable { } // Manual import remains usable without a group.
            catch { shareReadFailed = true }
        }
        .onReceive(container.playlistAcquisition.map { $0.$requestedPlaylistID.eraseToAnyPublisher() } ?? Empty<String?, Never>().eraseToAnyPublisher()) { id in
            // A playlist-ready notification was opened.
            guard let id, library.snapshot.playlists.contains(where: { $0.id == id }) else { return }
            container.playlistAcquisition?.requestedPlaylistID = nil
            coordinator.selectedTab = .library
            coordinator.sheet = .playlist(id)
        }
        .onReceive(container.migrationIssues.map { $0.$requestedIssuesPlaylistID.eraseToAnyPublisher() } ?? Empty<String?, Never>().eraseToAnyPublisher()) { id in
            // A migration attention notification was opened. A deleted playlist is ignored.
            guard let id else { return }
            container.migrationIssues?.requestedIssuesPlaylistID = nil
            openMigrationIssues(id)
        }
        .onReceive(container.sharing.$inbox) { _ in inboxRevision += 1 }
        .task(id: "\(scenePhase)-\(inboxRevision)-\(shareRevision)") {
            // Opened library documents wait for any presentation in progress, like shared links.
            guard scenePhase == .active, let document = container.sharing.inbox else { return }
            do {
                while coordinator.sheet != nil || coordinator.showingNowPlaying || Self.hasModal {
                    try await Task.sleep(for: .milliseconds(350))
                }
                try Task.checkCancellation()
                guard container.sharing.inbox?.id == document.id else { return }
                coordinator.sheet = .libraryImport(document)
            } catch { }
        }
        .alert("Could not read the shared link inbox", isPresented: $shareReadFailed) {
            Button("Retry") { shareRevision += 1 }
            Button("Close", role: .cancel) { }
        }
        .sheet(item: $coordinator.sheet, onDismiss: { shareRevision += 1 }) { sheet in
            switch sheet {
            case .settings: SettingsView()
            case .importLink: ImportLinkView()
            case .sleepTimer: SleepTimerSheet(timer: audioPlayer.sleepTimer).presentationDetents([.height(390)])
            case .profile: LocalProfileView()
            case .playlist(let id): NotificationPlaylistSheet(playlistID: id)
            case .migrationIssues(let id): NotificationMigrationIssuesSheet(playlistID: id)
            case .librarySharing: LibrarySharingHubView()
            case .libraryImport(let document): LibraryImportView(inbox: document)
            case .sharedLink(let share):
                ImportLinkView(initialURL: share.url).onAppear {
                    Task {
                        do { try await coordinator.shareHandoff.acknowledge(share.id) }
                        catch { shareReadFailed = true }
                    }
                }
            }
        }
        .fullScreenCover(isPresented: $coordinator.showingNowPlaying) { NowPlayingView(coordinator: coordinator) }
    }

    /// On a cold launch the library snapshot may still be loading: wait a bounded time
    /// for the playlist, then give up silently if it was deleted (no invalid destination).
    private func openMigrationIssues(_ id: String) {
        Task { @MainActor in
            for _ in 0..<40 {
                if library.snapshot.playlists.contains(where: { $0.id == id }) {
                    guard library.isMigrationPlaylist(id) else { return }
                    coordinator.selectedTab = .library
                    coordinator.sheet = .migrationIssues(id)
                    return
                }
                try? await Task.sleep(for: .milliseconds(250))
            }
        }
    }

    private static var hasModal: Bool {
        UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .filter { $0.activationState == .foregroundActive }
            .contains { $0.keyWindow?.rootViewController?.presentedViewController != nil }
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
        // Give every navigation destination a viewport ending above the playback controls.
        VStack(spacing: 0) {
            content.frame(maxWidth: .infinity, maxHeight: .infinity)
            VStack(spacing: AppSpacing.xs) {
                SleepTimerStatusIndicator(timer: audioPlayer.sleepTimer, showsLabel: true) { onPresent(); showingTimer = true }
                if audioPlayer.state.currentTrackID != nil { MiniPlayer(coordinator: coordinator).padding(.horizontal, AppSpacing.sm) }
            }.padding(.top, AppSpacing.sm).fixedSize(horizontal: false, vertical: true)
        }
        .sheet(isPresented: $showingTimer) { SleepTimerSheet(timer: audioPlayer.sleepTimer).presentationDetents([.height(390)]) }
    }
}

struct SearchBar: View {
    @Environment(\.themePalette) private var palette
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
            if focus == field {
                Button("Done") { focus = nil }.frame(minHeight: 44)
                    .foregroundStyle(palette.accent).accessibilityIdentifier("keyboard-done")
            }
        }.frame(minHeight: 44).padding(.horizontal, AppSpacing.md).padding(.vertical, 4).background(AppColors.backgroundSecondary).clipShape(RoundedRectangle(cornerRadius: AppRadius.medium))
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
