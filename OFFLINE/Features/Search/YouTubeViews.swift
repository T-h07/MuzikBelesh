import SwiftUI

struct YouTubeSearchResultsView: View {
    @StateObject private var model: YouTubeSearchViewModel
    @EnvironmentObject private var container: AppContainer
    let query: String
    let onOpen: () -> Void
    let onPaste: () -> Void
    init(provider: any YouTubeSearchProvider, query: String, onOpen: @escaping () -> Void, onPaste: @escaping () -> Void) {
        _model = StateObject(wrappedValue: YouTubeSearchViewModel(provider: provider))
        self.query = query; self.onOpen = onOpen; self.onPaste = onPaste
    }
    var body: some View {
        LazyVStack(alignment: .leading, spacing: AppSpacing.md) {
            Button("Paste a Video Link", action: onPaste).foregroundStyle(AppColors.accentPrimary).accessibilityIdentifier("youtube-paste-link")
            switch model.state {
            case .idle: EmptyState(icon: "magnifyingglass", title: "Search YouTube", message: "Find videos by song title, artist, channel or keywords.")
            case .loading: ProgressView("Searching YouTube…").accessibilityIdentifier("youtube-search-loading")
            case .empty: EmptyState(icon: "magnifyingglass", title: "No videos found", message: "Try another title, artist or keyword.")
            case .failed(let error):
                Text(error.localizedDescription).foregroundStyle(AppColors.textSecondary).accessibilityIdentifier("youtube-search-error")
                if error.canRetry { Button("Retry") { model.retry() }.accessibilityIdentifier("youtube-search-retry") }
            case .results:
                ForEach(model.videos) { video in
                    NavigationLink { VideoDetailView(video: video, container: container) } label: { YouTubeVideoRow(video: video) }
                        .accessibilityIdentifier("youtube-result-\(video.id)")
                        .simultaneousGesture(TapGesture().onEnded { _ in onOpen() })
                }
                if let error = model.pageError { Text(error.localizedDescription).font(.caption).foregroundStyle(AppColors.textSecondary) }
                if model.loadingMore { ProgressView("Loading more…") }
                else if model.continuation != nil {
                    Button { model.loadMore() } label: {
                        Text(model.pageError == nil ? "Load More" : "Retry Load More")
                            .frame(minHeight: 44).contentShape(Rectangle())
                    }.accessibilityIdentifier("youtube-load-more")
                }
            }
        }.padding(.top, AppSpacing.md)
        .task(id: query) { model.search(query) }
        .onDisappear { model.cancel() }
    }
}

private struct YouTubeVideoRow: View {
    let video: YouTubeVideo
    var body: some View {
        HStack(spacing: AppSpacing.md) {
            YouTubeArtwork(url: video.thumbnailURL).frame(width: 110, height: 66).clipShape(RoundedRectangle(cornerRadius: AppRadius.small))
            VStack(alignment: .leading, spacing: 4) {
                Text(video.title).font(.subheadline.weight(.semibold)).foregroundStyle(AppColors.textPrimary).lineLimit(2)
                Text(video.channel ?? "Channel unavailable").font(.caption).foregroundStyle(AppColors.textSecondary).lineLimit(1)
                Text(video.durationLabel).font(.caption2).foregroundStyle(AppColors.textTertiary)
            }
            Spacer(minLength: 0)
        }.padding(.vertical, 4).contentShape(Rectangle())
    }
}

struct VideoDetailView: View {
    @StateObject private var model: VideoDetailsViewModel
    @EnvironmentObject private var coordinator: AppCoordinator
    @EnvironmentObject private var library: MusicLibraryService
    @ObservedObject private var downloads: DownloadManager
    @ObservedObject private var preferences: YouTubePreferences
    init(video: YouTubeVideo, container: AppContainer) {
        _model = StateObject(wrappedValue: VideoDetailsViewModel(video: video, metadata: container.youtubeMetadata, resolver: container.youtubeResolver, preparer: container.youtubePreparer, library: container.youtubeLibrary))
        downloads = container.downloads
        preferences = container.youtubePreferences
    }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: AppSpacing.lg) {
                if let localTrack {
                    StoredArtworkView(track: localTrack, size: 160)
                } else if model.libraryStatus != .unknown {
                    YouTubeArtwork(url: model.video.thumbnailURL).aspectRatio(16 / 9, contentMode: .fit).clipShape(RoundedRectangle(cornerRadius: AppRadius.medium))
                }
                Text(localTrack?.title ?? model.video.title).font(.title2.bold()).foregroundStyle(AppColors.textPrimary).accessibilityIdentifier("youtube-detail-title")
                Text(localTrack.map { library.artistName($0.artistID) } ?? model.video.channel ?? "Channel unavailable").foregroundStyle(AppColors.textSecondary)
                Text(localTrack?.durationMs.map { String(format: "%d:%02d", $0 / 60000, ($0 / 1000) % 60) } ?? model.video.durationLabel).foregroundStyle(AppColors.textSecondary)
                Text(libraryLabel).font(.subheadline).accessibilityIdentifier("youtube-library-status")
                if localTrack == nil {
                Picker("Audio Quality", selection: $preferences.quality) {
                    ForEach(AudioQuality.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }.tint(AppColors.accentPrimary).disabled(model.busy).accessibilityIdentifier("youtube-quality")
                status
                }
                if case .downloaded(let id) = model.libraryStatus, library.track(id)?.availability == .available {
                    Button("Play in Library") { Task { await library.play(id, ids: [id], kind: "library") } }
                }
                if let job = downloads.job(for: model.video.id), job.state != .completed || model.libraryStatus != .fileUnavailable && job.trackID != nil && library.track(job.trackID)?.availability == .available {
                    Button("View in Downloads · " + job.state.label) {
                        coordinator.sheet = nil
                        coordinator.selectedTab = .downloads
                    }.accessibilityIdentifier("youtube-view-job")
                } else if localTrack == nil {
                    Button { downloads.enqueue(model.video, quality: preferences.quality) } label: {
                        Label("Download Audio", systemImage: "arrow.down.circle.fill")
                            .frame(maxWidth: .infinity).padding().background(AppColors.accentPrimary).foregroundStyle(.black).clipShape(RoundedRectangle(cornerRadius: AppRadius.medium))
                    }.disabled(model.stream == nil).accessibilityIdentifier("youtube-prepare")
                }
                if let issue = downloads.issue { Text(issue).foregroundStyle(AppColors.error) }
                Text("Save only media you are authorized to download.").font(.caption).foregroundStyle(AppColors.textTertiary)
            }.padding(AppSpacing.xl)
        }.navigationTitle("Video Details").navigationBarTitleDisplayMode(.inline).toolbar(.visible, for: .navigationBar).screenBackground()
        .onAppear { model.load(quality: preferences.quality) }
        .onChange(of: preferences.quality) { _, quality in model.load(quality: quality) }
        .onChange(of: downloads.job(for: model.video.id)?.state) { _, state in
            if state == .completed { model.load(quality: preferences.quality) }
        }
        .onDisappear { model.cancel() }
    }
    private var localTrack: StoredTrack? {
        guard case .downloaded(let id) = model.libraryStatus else { return nil }
        return library.track(id)
    }
    private var libraryLabel: String {
        if model.libraryStatus == .fileUnavailable { return "Local file missing or damaged" }
        if let job = downloads.job(for: model.video.id) {
            if job.state != .completed { return job.state.label }
            return library.track(job.trackID)?.availability == .available ? "Downloaded" : "File unavailable"
        }
        return switch model.libraryStatus {
        case .downloaded: "Downloaded"
        case .notDownloaded: "Not Downloaded"
        case .fileUnavailable: "Library record found · local file unavailable"
        case .unknown: "Library status unavailable"
        }
    }
    @ViewBuilder private var status: some View {
        switch model.state {
        case .local: EmptyView()
        case .idle: Text("Ready to inspect video")
        case .loadingMetadata: ProgressView("Loading metadata…")
        case .resolvingStreams: ProgressView("Resolving compatible audio…")
        case .ready:
            if let stream = model.stream {
                Text("Audio available · \(stream.selected.container.uppercased()) · \(stream.selected.codec ?? "Unknown codec")").foregroundStyle(AppColors.accentPrimary).accessibilityIdentifier("youtube-stream-ready")
                if let bitrate = stream.selected.bitrate { Text("\(bitrate / 1000) kbps").foregroundStyle(AppColors.textSecondary) }
            }
        case .failed(let error), .unavailable(let error):
            Text(error.localizedDescription).foregroundStyle(AppColors.error).accessibilityIdentifier("youtube-detail-error")
            if error.canRetry { Button("Retry") { model.load(quality: preferences.quality, force: true) }.accessibilityIdentifier("youtube-detail-retry") }
        }
    }
}

struct ImportLinkView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var container: AppContainer
    @State private var urlText = ""
    @State private var message: String?
    @State private var selected: YouTubeVideo?
    @FocusState private var focused: Bool
    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: AppSpacing.lg) {
                Text("Paste a Video Link").font(.title2.bold()).foregroundStyle(AppColors.textPrimary)
                TextField("https://youtube.com/watch?v=…", text: $urlText).textFieldStyle(.roundedBorder)
                    .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL).focused($focused)
                    .submitLabel(.go).onSubmit(inspect).accessibilityIdentifier("youtube-link-input")
                PasteButton(payloadType: String.self) { values in if let value = values.first { urlText = value; message = nil } }
                    .accessibilityIdentifier("youtube-clipboard-paste")
                if let message { Text(message).font(.subheadline).foregroundStyle(AppColors.error).accessibilityIdentifier("youtube-link-error") }
                Button("Inspect Link", action: inspect).buttonStyle(.borderedProminent).tint(AppColors.accentPrimary).foregroundStyle(.black).accessibilityIdentifier("youtube-inspect-link")
                Spacer()
            }.padding(AppSpacing.xl).navigationTitle("Import Link")
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }.screenBackground()
                .navigationDestination(item: $selected) { video in VideoDetailView(video: video, container: container) }
        }
    }
    private func inspect() {
        focused = false
        do {
            let id = try YouTubeURLValidator.parse(urlText)
            message = nil
            selected = YouTubeVideo(id: id, title: "YouTube Video")
        } catch let error as YouTubeURLValidationError {
            message = error == .invalidVideoID ? YouTubeError.invalidVideoID.localizedDescription : YouTubeError.invalidURL.localizedDescription
        } catch { message = YouTubeError.invalidURL.localizedDescription }
    }
}
