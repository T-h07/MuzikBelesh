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
}
protocol ExternalCandidateDiscovery: Sendable {
    /// Providers must honor cancellation and return bounded metadata only.
    func discover(_ source: PlaylistMigrationSourceTrack) async throws -> MatchingDiscoveryResult
}

struct YouTubeSearchProviderAdapter: ExternalCandidateDiscovery {
    let search: any YouTubeSearchProvider
    var metadata: (any YouTubeMetadataProvider)? = nil
    private static func credits(_ title: String) -> (title: String, artist: String?) {
        for separator in [" - ", " – ", " — "] {
            let parts = title.components(separatedBy: separator)
            if parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty { return (parts[1], parts[0]) }
        }
        return (title, nil)
    }
    static func queries(_ source: PlaylistMigrationSourceTrack) -> [String] {
        let base = YouTubeSearchService.normalize((source.primaryArtist ?? "") + " " + source.title)
        guard !base.isEmpty else { return [] }
        // Source version words stay in the base; never invent a live/remix query.
        return [String(base.prefix(400)), String((base + " Official Audio").prefix(500))]
    }
    func discover(_ source: PlaylistMigrationSourceTrack) async throws -> MatchingDiscoveryResult {
        var result = MatchingDiscoveryResult(), seen = Set<String>()
        for query in Self.queries(source) {
            try Task.checkCancellation()
            do {
                let page = try await search.search(query: query, continuationToken: nil)
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
                                                  available: video.availability == .available)
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
                break // No immediate retry after timeout/rate limiting/offline failure.
            }
            if result.recordings.count >= 20 { break }
        }
        // Search availability is normally unknown. Inspect at most three likely
        // results through the existing watch-metadata provider, never the resolver.
        if let metadata, result.failures.isEmpty {
            let scorer = CandidateScoringEngine()
            let order = result.recordings.indices.sorted {
                let left = scorer.score(source: source, candidate: result.recordings[$0]).score
                let right = scorer.score(source: source, candidate: result.recordings[$1]).score
                return left == right ? result.recordings[$0].identity < result.recordings[$1].identity : left > right
            }
            for index in order.prefix(3) {
                try Task.checkCancellation()
                do {
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
                    result.recordings[index].durationMs = video.duration.flatMap { $0.isFinite && $0 > 0 && $0 < 86_400 ? Int64($0 * 1000) : nil }
                } catch {
                    if Task.isCancelled || (error as? YouTubeError) == .cancelled { throw CancellationError() }
                    result.recordings[index].available = false
                    let error = YouTubeError.map(error, fallback: .metadataUnavailable)
                    if [.networkUnavailable, .requestTimeout, .rateLimited].contains(error) {
                        result.failures.append(error.localizedDescription); break
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
