import SwiftUI

enum SearchMode: String, CaseIterable { case youtube = "YouTube", library = "Your Library" }

struct SearchView: View {
    @EnvironmentObject private var container: AppContainer
    @EnvironmentObject private var library: MusicLibraryService
    @State private var localResults: [StoredTrack] = []
    @ObservedObject var coordinator: AppCoordinator
    @State private var mode: SearchMode = .youtube
    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: AppSpacing.lg) {
                Text("Search").font(.system(size: 28, weight: .bold)).foregroundStyle(AppColors.textPrimary)
                SearchBar(text: $coordinator.searchQuery, placeholder: "Songs, artists or video links")
                Picker("Search mode", selection: $mode) { ForEach(SearchMode.allCases, id: \.self) { Text($0.rawValue).tag($0) } }.pickerStyle(.segmented).tint(AppColors.accentPrimary)
            }.padding(.horizontal, AppSpacing.xl).padding(.vertical, AppSpacing.lg)
            ScrollView { resultsContent.padding(.horizontal, AppSpacing.xl).padding(.bottom, 100) }
        }.navigationBarHidden(true).screenBackground()
        .task(id: "\(coordinator.searchQuery)|\(library.revision)") {
            do {
                try await Task.sleep(for: .milliseconds(250))
                let value = try await library.search(coordinator.searchQuery)
                guard !Task.isCancelled else { return }; localResults = value
            } catch is CancellationError { } catch { if !Task.isCancelled { library.report(error) } }
        }
    }
    @ViewBuilder private var resultsContent: some View { if mode == .youtube { youtubeResults } else { libraryResults } }
    @ViewBuilder private var youtubeResults: some View {
        let results = MockMusicCatalog.videos.filter { coordinator.searchQuery.isEmpty || $0.title.localizedCaseInsensitiveContains(coordinator.searchQuery) || $0.channel.localizedCaseInsensitiveContains(coordinator.searchQuery) }
        VStack(alignment: .leading, spacing: AppSpacing.md) {
            HStack { Text("Mock YouTube results").font(.caption).foregroundStyle(AppColors.textTertiary); Spacer(); Button("Paste a Video Link") { coordinator.sheet = .importLink }.font(.caption).foregroundStyle(AppColors.accentPrimary) }
            if results.isEmpty { EmptyState(icon: "magnifyingglass", title: "No videos found", message: "Try another title, artist or channel.") } else { ForEach(results) { video in NavigationLink { VideoDetailView(video: video) } label: { YouTubeResultRow(video: video) } } }
        }.padding(.top, AppSpacing.md)
    }
    @ViewBuilder private var libraryResults: some View {
        let results = coordinator.searchQuery.isEmpty ? library.snapshot.tracks : localResults
        VStack(alignment: .leading, spacing: AppSpacing.md) {
            LibrarySortMenu()
            if results.isEmpty { EmptyState(icon: "music.note", title: "No library matches", message: "Search your imported music by title, artist or album.") }
            else { ForEach(results) { StoredTrackRow(track: $0, contextTrackIDs: results.map(\.id), contextKind: "search") } }
        }.padding(.top, AppSpacing.md)
    }
}

struct ImportLinkView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var urlText = ""
    @State private var message: String?
    var body: some View { NavigationStack { VStack(alignment: .leading, spacing: AppSpacing.lg) { Text("Paste a Video Link").font(.title2.bold()).foregroundStyle(AppColors.textPrimary); TextField("https://youtube.com/watch?v=…", text: $urlText).textFieldStyle(.roundedBorder).textInputAutocapitalization(.never); if let message { Text(message).font(.subheadline).foregroundStyle(AppColors.error) }; Button("Inspect Link") { inspect() }.buttonStyle(.borderedProminent).tint(AppColors.accentPrimary).foregroundStyle(.black); Spacer() }.padding(AppSpacing.xl).navigationTitle("Import Link").toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }.screenBackground() } }
    private func inspect() { message = YouTubeURLValidator.videoID(from: urlText) == nil ? "Enter a valid HTTPS YouTube URL." : "Mock link recognized. No network request was made." }
}

struct VideoDetailView: View {
    @EnvironmentObject private var container: AppContainer
    let video: MockVideo
    var body: some View { ScrollView { VStack(alignment: .leading, spacing: AppSpacing.xl) { ArtworkView(name: video.artwork, size: 340).frame(maxWidth: .infinity); Text(video.title).font(.title2.bold()).foregroundStyle(AppColors.textPrimary); Text("\(video.channel) · \(video.duration)").foregroundStyle(AppColors.textSecondary); Text("Mock fixture · no network request").font(.caption).foregroundStyle(AppColors.textTertiary); Button { container.downloads.add(video) } label: { Label("Add Mock Download", systemImage: "arrow.down.circle.fill").frame(maxWidth: .infinity).padding().background(AppColors.accentPrimary).foregroundStyle(.black).clipShape(RoundedRectangle(cornerRadius: AppRadius.medium)) } }.padding(AppSpacing.xl).padding(.bottom, 100) }.navigationTitle("Video Details").navigationBarTitleDisplayMode(.inline).screenBackground() }
}

