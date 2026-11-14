import Foundation
import GRDB

struct MatchingLocalRecording: Sendable {
    let track: StoredTrack
    let recording: SongRecording
}
struct MatchingLibrarySnapshot: Sendable {
    let tracks: [StoredTrack]
    let artists: [StoredArtist]
    let albums: [StoredAlbum]
    func unchanged(in db: Database) throws -> Bool {
        try tracks == StoredTrack.order(Column("id")).fetchAll(db)
            && artists == StoredArtist.order(Column("id")).fetchAll(db)
            && albums == StoredAlbum.order(Column("id")).fetchAll(db)
    }
}

/// Rebuilt once per run, never a persistent cache. All competitors are considered
/// before truncation; overflow explicitly prevents automatic acceptance.
struct LocalLibraryCandidateProvider: Sendable {
    let recordings: [String: MatchingLocalRecording]
    let snapshot: MatchingLibrarySnapshot
    private let byTitle: [String: [String]]
    private let byArtist: [String: [String]]
    init(_ values: [MatchingLocalRecording], snapshot: MatchingLibrarySnapshot) {
        self.snapshot = snapshot
        recordings = Dictionary(uniqueKeysWithValues: values.map { ($0.track.id, $0) })
        byTitle = Dictionary(grouping: values, by: { SongMetadataNormalizer.cleanTitle($0.recording.title) }).mapValues { $0.map(\.track.id).sorted() }
        byArtist = Dictionary(grouping: values, by: { SongMetadataNormalizer.artist($0.recording.artist).0 }).mapValues { $0.map(\.track.id).sorted() }
    }
    func candidates(for source: PlaylistMigrationSourceTrack) -> (values: [SongRecording], truncated: Bool) {
        let titleIDs = byTitle[SongMetadataNormalizer.cleanTitle(source.title)] ?? []
        let artistIDs = byArtist[SongMetadataNormalizer.artist(source.primaryArtist).0] ?? []
        let ids = Array(Set(titleIDs + artistIDs)).sorted()
        // Exact titles first, but never claim uniqueness if competitors are omitted.
        let exact = Set(titleIDs)
        let ordered = ids.sorted { exact.contains($0) == exact.contains($1) ? $0 < $1 : exact.contains($0) }
        return (ordered.prefix(100).compactMap { recordings[$0]?.recording }, ids.count > 100)
    }
}

struct MatchingDiscoveryResult: Sendable {
    var recordings: [SongRecording] = []
    var failures: [String] = []
    var truncated = false
    var failure: YouTubeError? = nil
    var pauseDiscovery = false
    var searchFailed = false
}
protocol ExternalCandidateDiscovery: Sendable {
    /// Providers must honor cancellation and return bounded metadata only.
    func discover(_ source: PlaylistMigrationSourceTrack) async throws -> MatchingDiscoveryResult
    func forRun() -> any ExternalCandidateDiscovery
}
extension ExternalCandidateDiscovery {
    func forRun() -> any ExternalCandidateDiscovery { self }
}

/// Successful responses only, bounded and discarded after each run. Duplicate
/// occurrences still receive separate scoring, leases, candidates and decisions.
private actor MatchingYouTubeResponseCache: YouTubeSearchProvider, YouTubeMetadataProvider {
    let searchProvider: any YouTubeSearchProvider
    let metadataProvider: (any YouTubeMetadataProvider)?
    private var pages: [String: YouTubeSearchPage] = [:]
    private var videos: [String: YouTubeVideo] = [:]
    init(search: any YouTubeSearchProvider, metadata: (any YouTubeMetadataProvider)?) {
        searchProvider = search; metadataProvider = metadata
    }
    func search(query: String, continuationToken: String?) async throws -> YouTubeSearchPage {
        try Task.checkCancellation()
        if continuationToken == nil, let cached = pages[query] { return cached }
        let page = try await searchProvider.search(query: query, continuationToken: continuationToken)
        try Task.checkCancellation()
        if continuationToken == nil, pages.count < 200 { pages[query] = page }
        return page
    }
    func metadata(videoID: String) async throws -> YouTubeVideo {
        try Task.checkCancellation()
        if let cached = videos[videoID] { return cached }
        guard let metadataProvider else { throw YouTubeError.metadataUnavailable }
        let video = try await metadataProvider.metadata(videoID: videoID)
        try Task.checkCancellation()
        if video.id == videoID, videos.count < 200 { videos[videoID] = video }
        return video
    }
}

/// Count failed occurrences, never the retries within one occurrence. Successful
/// searches reset the streak; individual watch failures do not trip the breaker.
struct MatchingDiscoveryFailurePolicy {
    private var streaks: [Int: Set<UUID>] = [:]
    static func immediate(_ error: YouTubeError?) -> Bool {
        error == .rateLimited || error == .accessRestricted || error == .providerRestricted || error == .redirectUnavailable
    }
    mutating func observe(provider: Int, entry: UUID, searchFailed: Bool, restricted: Bool) -> Bool {
        if restricted { return true }
        if searchFailed { streaks[provider, default: []].insert(entry) }
        else { streaks[provider] = [] }
        return (streaks[provider]?.count ?? 0) >= 3
    }
}

/// One shared monotonic request budget for matching, including retries and watch reads.
actor MatchingRequestPacer {
    static let shared = MatchingRequestPacer()
    private let clock = ContinuousClock()
    private let interval: Duration
    private var next: ContinuousClock.Instant?
    init(interval: Duration = .seconds(1)) { self.interval = interval }
    func wait() async throws {
        try Task.checkCancellation()
        let deadline = max(next ?? clock.now, clock.now)
        next = deadline.advanced(by: interval)
        try await clock.sleep(until: deadline)
        try Task.checkCancellation()
    }
}

struct YouTubeSearchProviderAdapter: ExternalCandidateDiscovery {
    let search: any YouTubeSearchProvider
    var metadata: (any YouTubeMetadataProvider)? = nil
    var pacer: MatchingRequestPacer = .shared
    func forRun() -> any ExternalCandidateDiscovery {
        let cache = MatchingYouTubeResponseCache(search: search, metadata: metadata)
        return Self(search: cache, metadata: metadata == nil ? nil : cache, pacer: pacer)
    }
    static func browserSearchURL(_ source: PlaylistMigrationSourceTrack) -> URL? {
        guard let query = queries(source).first else { return nil }
        var url = URLComponents(string: "https://www.youtube.com/results")
        url?.queryItems = [URLQueryItem(name: "search_query", value: query)]
        return url?.url
    }
    private static func credits(_ value: String) -> (title: String, artist: String?) {
        let title = SongMetadataNormalizer.withoutTrackNumber(value)
        if let range = title.range(of: "\\s+[-–—|:]\\s+|[–—]", options: .regularExpression) {
            let artist = String(title[..<range.lowerBound]).trimmingCharacters(in: .whitespaces)
            let song = String(title[range.upperBound...]).trimmingCharacters(in: .whitespaces)
            if !artist.isEmpty, !song.isEmpty { return (song, artist) }
        }
        return (title, nil)
    }
    static func queries(_ source: PlaylistMigrationSourceTrack) -> [String] {
        let base = YouTubeSearchService.normalize((source.primaryArtist ?? "") + " " + SongMetadataNormalizer.withoutTrackNumber(source.title))
        guard !base.isEmpty else { return [] }
        // Source version words stay in the base; never invent a live/remix query.
        let normalized = YouTubeSearchService.normalize((source.primaryArtist ?? "") + " " + SongMetadataNormalizer.cleanTitle(source.title)
            + " " + (source.additionalArtists + SongMetadataNormalizer.splitFeature(source.title).1).joined(separator: " "))
        return [String(base.prefix(400)), SongMetadataNormalizer.words(normalized) == SongMetadataNormalizer.words(base)
            ? String((base + " Official Audio").prefix(500)) : String(normalized.prefix(500))]
    }
    private func searchWithRetry(_ query: String) async throws -> YouTubeSearchPage {
        try await pacer.wait()
        do { return try await search.search(query: query, continuationToken: nil) }
        catch {
            // One paced retry for ambiguous search/transport failures. Access
            // restrictions and rate limits are never retried here.
            guard let failure = error as? YouTubeError, [.networkUnavailable, .requestTimeout, .searchUnavailable].contains(failure) else { throw error }
            try await Task.sleep(for: .seconds(1))
            try await pacer.wait()
            return try await search.search(query: query, continuationToken: nil)
        }
    }
    func discover(_ source: PlaylistMigrationSourceTrack) async throws -> MatchingDiscoveryResult {
        var result = MatchingDiscoveryResult(), seen = Set<String>()
        for query in Self.queries(source) {
            try Task.checkCancellation()
            do {
                let page = try await searchWithRetry(query)
                try Task.checkCancellation()
                for video in page.videos.prefix(30) {
                    guard YouTubeURLValidator.isValidID(video.id), seen.insert(video.id).inserted,
                          ![.live, .upcoming, .unavailable].contains(video.availability),
                          !video.isShort, !video.title.isEmpty, video.title.count <= 500 else { continue }
                    let credits = Self.credits(video.title)
                    let hasCredit = credits.artist != nil
                    let title = credits.title, artist = credits.artist
                    let duration = video.duration.flatMap { $0.isFinite && $0 > 0 && $0 < 86_400 ? Int64($0 * 1000) : nil }
                    let recording = SongRecording(provider: "youtube", identity: video.id, title: title, artist: artist,
                                                  durationMs: duration, performerEstablished: hasCredit,
                                                  available: video.availability == .available,
                                                  fullTitle: video.title, channel: video.channel,
                                                  thumbnailURL: MatchingCandidateArtwork.safe(video.thumbnailURL))
                    // Obviously unrelated titles have no review value.
                    let sourceWords = Set(SongMetadataNormalizer.cleanTitle(source.title).split(separator: " "))
                    let candidateWords = Set(SongMetadataNormalizer.cleanTitle(title).split(separator: " "))
                    guard !sourceWords.intersection(candidateWords).isEmpty else { continue }
                    result.recordings.append(recording)
                    if result.recordings.count == 20 { result.truncated = true; break }
                }
            } catch {
                if Task.isCancelled || (error as? YouTubeError) == .cancelled { throw CancellationError() }
                // Typed messages only: no raw transport errors, URLs or credentials.
                let failure = YouTubeError.map(error, fallback: .searchUnavailable)
                result.failures.append(failure.localizedDescription)
                result.failure = failure
                result.searchFailed = true
                result.pauseDiscovery = MatchingDiscoveryFailurePolicy.immediate(failure)
                break // No alternate-query requests after an exhausted or restricted search.
            }
            if result.recordings.count >= 20 { break }
            // A fallback query is useful only when no plausible candidates survived.
            if !result.recordings.isEmpty { break }
        }
        // Reuse title, duration, channel and artwork from search. Watch-check only
        // one candidate that could meet every recommendation gate except availability.
        // Missing duration may justify one enrichment request. Unknown availability
        // stays unverified; no confidence thresholds or identity gates are relaxed.
        if let metadata, result.failures.isEmpty {
            let scorer = CandidateScoringEngine()
            let eligible = result.recordings.indices.filter { index in
                var candidate = result.recordings[index]
                guard !candidate.available else { return false }
                if candidate.durationMs == nil { return true }
                candidate.available = true
                return scorer.score(source: source, candidate: candidate).gates.isEmpty
            }
            let order = eligible.sorted {
                let left = scorer.score(source: source, candidate: result.recordings[$0]).score
                let right = scorer.score(source: source, candidate: result.recordings[$1]).score
                return left == right ? result.recordings[$0].identity < result.recordings[$1].identity : left > right
            }
            for index in order.prefix(1) {
                try Task.checkCancellation()
                do {
                    try await pacer.wait()
                    let video = try await metadata.metadata(videoID: result.recordings[index].identity)
                    try Task.checkCancellation()
                    guard video.id == result.recordings[index].identity else { continue }
                    // Keep title/credits from the evaluated search response. If the
                    // watch title changes, it needs review instead of combining identities.
                    let watch = Self.credits(video.title)
                    let sameTitle = SongMetadataNormalizer.cleanTitle(watch.title) == SongMetadataNormalizer.cleanTitle(result.recordings[index].title)
                    let watchArtist = SongMetadataNormalizer.artist(watch.artist)
                    let searchArtist = SongMetadataNormalizer.artist(result.recordings[index].artist)
                    let sameArtist = watch.artist != nil && watchArtist.0 == searchArtist.0 && watchArtist.1 == searchArtist.1
                    result.recordings[index].available = sameTitle && sameArtist && video.availability == .available && !video.isShort
                    result.recordings[index].durationMs = video.duration.flatMap { $0.isFinite && $0 > 0 && $0 < 86_400 ? Int64($0 * 1000) : nil } ?? result.recordings[index].durationMs
                    result.recordings[index].channel = video.channel ?? result.recordings[index].channel
                    result.recordings[index].thumbnailURL = MatchingCandidateArtwork.safe(video.thumbnailURL) ?? result.recordings[index].thumbnailURL
                } catch {
                    if Task.isCancelled || (error as? YouTubeError) == .cancelled { throw CancellationError() }
                    result.recordings[index].available = false
                    let error = YouTubeError.map(error, fallback: .metadataUnavailable)
                    result.failures.append(error.localizedDescription); result.failure = error
                    if [.rateLimited, .providerRestricted, .redirectUnavailable].contains(error) {
                        result.pauseDiscovery = true
                        break
                    }
                }
            }
        }
        return result
    }
}

extension GRDBPlaylistMigrationRepository {
    func matchingLibrary() async throws -> LocalLibraryCandidateProvider {
        try await db.read { [self] db in
            let snapshot = try MatchingLibrarySnapshot(tracks: StoredTrack.order(Column("id")).fetchAll(db),
                artists: StoredArtist.order(Column("id")).fetchAll(db), albums: StoredAlbum.order(Column("id")).fetchAll(db))
            let artists = Dictionary(uniqueKeysWithValues: snapshot.artists.map { ($0.id, $0.name) })
            let albums = Dictionary(uniqueKeysWithValues: snapshot.albums.map { ($0.id, $0.title) })
            let deleting = Set(try String.fetchAll(db, sql: "SELECT ownerID FROM library_file_operations WHERE kind = 'delete-track'"))
            let values = snapshot.tracks.compactMap { track -> MatchingLocalRecording? in
                guard !deleting.contains(track.id), MigrationLocalAudio.isAvailable(track, paths: paths) else { return nil }
                return MatchingLocalRecording(track: track, recording: SongRecording(provider: "local", identity: track.id,
                    title: track.title, artist: track.artistID.flatMap { artists[$0] }, album: track.albumID.flatMap { albums[$0] },
                    durationMs: track.durationMs, local: true))
            }
            return LocalLibraryCandidateProvider(values, snapshot: snapshot)
        }
    }
}
