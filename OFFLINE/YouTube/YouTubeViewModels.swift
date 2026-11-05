import Foundation
import Combine

@MainActor final class YouTubeSearchViewModel: ObservableObject {
    enum State: Equatable { case idle, loading, results, empty, failed(YouTubeError) }
    @Published private(set) var state: State = .idle
    @Published private(set) var videos: [YouTubeVideo] = []
    @Published private(set) var loadingMore = false
    @Published private(set) var pageError: YouTubeError?
    @Published private(set) var continuation: String?
    private let provider: any YouTubeSearchProvider
    private let debounce: @Sendable () async throws -> Void
    private var task: Task<Void, Never>?
    private var generation = 0
    private var query = ""
    private var consumed = Set<String>()
    init(provider: any YouTubeSearchProvider, debounce: @escaping @Sendable () async throws -> Void = { try await Task.sleep(for: .milliseconds(400)) }) {
        self.provider = provider; self.debounce = debounce
    }
    func search(_ input: String, force: Bool = false) {
        let normalized = YouTubeSearchService.normalize(input)
        if !force, normalized == query, state == .results || state == .empty { return }
        cancel()
        query = normalized; videos = []; continuation = nil; consumed = []; pageError = nil
        guard !query.isEmpty else { state = .idle; return }
        state = .loading
        let revision = generation, query = query
        task = Task {
            do {
                if !force { try await debounce() }
                try Task.checkCancellation()
                let page = try await provider.search(query: query, continuationToken: nil)
                try Task.checkCancellation()
                guard revision == generation else { return }
                var ids = Set<String>()
                videos = page.videos.filter { ids.insert($0.id).inserted }
                continuation = page.continuationToken
                state = videos.isEmpty ? .empty : .results
            } catch {
                guard revision == generation else { return }
                let mapped = YouTubeError.map(error, fallback: .searchUnavailable)
                state = mapped == .cancelled ? .idle : .failed(mapped)
            }
        }
    }
    func retry() { search(query, force: true) }
    func loadMore() {
        guard !loadingMore, state == .results, let token = continuation, !consumed.contains(token) else { return }
        loadingMore = true; pageError = nil
        let revision = generation, query = query
        task = Task {
            defer { if revision == generation { loadingMore = false } }
            do {
                let page = try await provider.search(query: query, continuationToken: token)
                try Task.checkCancellation()
                guard revision == generation else { return }
                consumed.insert(token)
                var ids = Set(videos.map(\.id))
                videos += page.videos.filter { ids.insert($0.id).inserted }
                continuation = page.continuationToken.flatMap { consumed.contains($0) ? nil : $0 }
            } catch {
                guard revision == generation else { return }
                let mapped = YouTubeError.map(error, fallback: .searchUnavailable)
                if mapped != .cancelled { pageError = mapped }
            }
        }
    }
    func cancel() {
        generation += 1; task?.cancel(); task = nil; loadingMore = false
        if state == .loading { state = .idle }
    }
    func waitForRequest() async { await task?.value }
}

@MainActor final class VideoDetailsViewModel: ObservableObject {
    enum State: Equatable { case idle, local, loadingMetadata, resolvingStreams, ready, unavailable(YouTubeError), failed(YouTubeError) }
    @Published private(set) var video: YouTubeVideo
    @Published private(set) var state: State = .idle
    @Published private(set) var stream: ResolvedAudioStream?
    @Published private(set) var preparedRequest: PreparedYouTubeDownload?
    @Published private(set) var libraryStatus: YouTubeLibraryStatus = .unknown
    @Published private(set) var preparing = false
    private let metadata: any YouTubeMetadataProvider
    private let resolver: any YouTubeAudioResolver
    private let preparer: any YouTubeDownloadPreparing
    private let library: any YouTubeLibraryChecking
    private var metadataLoaded = false
    private var resolvedQuality: AudioQuality?
    private var generation = 0
    private var task: Task<Void, Never>?
    init(video: YouTubeVideo, metadata: any YouTubeMetadataProvider, resolver: any YouTubeAudioResolver, preparer: any YouTubeDownloadPreparing, library: any YouTubeLibraryChecking) {
        self.video = video; self.metadata = metadata; self.resolver = resolver; self.preparer = preparer; self.library = library
    }
    var busy: Bool { state == .loadingMetadata || state == .resolvingStreams || preparing }
    func load(quality: AudioQuality, force: Bool = false) {
        guard !busy else { return }
        begin(quality: quality, prepare: false, cached: force ? nil : stream)
    }
    func prepare(quality: AudioQuality) {
        guard !busy else { return }
        begin(quality: quality, prepare: true)
    }
    private func begin(quality: AudioQuality, prepare: Bool, cached: ResolvedAudioStream? = nil) {
        cancel(); preparedRequest = nil; stream = nil; preparing = prepare
        state = .loadingMetadata
        let revision = generation
        task = Task {
            defer { if revision == generation { preparing = false } }
            do {
                let local = try? await library.status(videoID: video.id)
                guard revision == generation else { return }
                libraryStatus = local ?? .unknown
                if case .downloaded = libraryStatus, !prepare {
                    state = .local
                    return
                }
                if let cached, cached.isFresh(at: Date()), resolvedQuality == quality {
                    stream = cached; state = .ready
                    return
                }
                if !metadataLoaded {
                    let details = try await metadata.metadata(videoID: video.id)
                    try Task.checkCancellation()
                    guard revision == generation else { return }
                    guard details.id == video.id else { throw YouTubeError.metadataUnavailable }
                    video = details; metadataLoaded = true
                }
                state = .resolvingStreams
                let result: ResolvedAudioStream
                if prepare {
                    let request = try await preparer.prepare(video: video, quality: quality)
                    try Task.checkCancellation()
                    guard revision == generation else { return }
                    preparedRequest = request; result = request.stream
                } else { result = try await resolver.resolve(video: video, quality: quality) }
                try Task.checkCancellation()
                guard revision == generation else { return }
                video = result.video; stream = result; resolvedQuality = quality; state = .ready
            } catch {
                guard revision == generation else { return }
                let mapped = YouTubeError.map(error, fallback: .extractionFailed)
                if mapped == .cancelled { state = .idle }
                else { state = mapped.canRetry ? .failed(mapped) : .unavailable(mapped) }
            }
        }
    }
    func cancel() {
        generation += 1; task?.cancel(); task = nil; preparing = false; preparedRequest = nil
        if state == .loadingMetadata || state == .resolvingStreams { state = .idle }
    }
    func waitForRequest() async { await task?.value }
}
