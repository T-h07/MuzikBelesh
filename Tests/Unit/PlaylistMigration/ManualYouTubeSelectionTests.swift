import XCTest
@testable import OFFLINE

private actor RestrictingDiscovery: ExternalCandidateDiscovery {
    var calls: [Int] = []
    var restrictAt: Int?
    init(restrictAt: Int?) { self.restrictAt = restrictAt }
    func heal() { restrictAt = nil }
    func discover(_ source: PlaylistMigrationSourceTrack) async throws -> MatchingDiscoveryResult {
        calls.append(source.position)
        if source.position == restrictAt { throw YouTubeError.providerRestricted }
        return .init(recordings: [.init(provider: "fixture", identity: String(source.position), title: source.title, artist: source.primaryArtist)])
    }
}

private struct FixedMetadata: YouTubeMetadataProvider {
    let result: Result<YouTubeVideo, YouTubeError>
    func metadata(videoID: String) async throws -> YouTubeVideo {
        var video = try result.get(); video = YouTubeVideo(id: videoID, title: video.title, channel: video.channel,
            thumbnailURL: video.thumbnailURL, duration: video.duration, availability: video.availability)
        return video
    }
}

private struct FixedTransport: YouTubeTransport {
    let status: Int
    let body: String
    func send(_ request: URLRequest) async throws -> YouTubeHTTPResponse {
        guard request.url?.path == "/oembed" else { throw YouTubeError.invalidURL }
        return .init(data: Data(body.utf8), status: status, url: request.url!, contentType: "application/json")
    }
}

final class ManualYouTubeSelectionTests: XCTestCase {
    private let id = "dQw4w9WgXcQ"
    private func source(_ count: Int, duplicate: Bool = false) -> PlaylistMigrationSourcePlaylist {
        .init(source: .exportify, name: "Manual", entries: (0..<count).map {
            .init(position: $0, title: duplicate ? "Same Song" : "Song \($0)", primaryArtist: "Artist", album: "Album", durationMs: 180_000)
        })
    }
    private func video(_ id: String? = nil) -> YouTubeVideo {
        .init(id: id ?? self.id, title: "Artist - Song 3", channel: "Artist", thumbnailURL: URL(string: "https://i.ytimg.com/vi/\(id ?? self.id)/hqdefault.jpg"),
              duration: 181, availability: .available)
    }

    func testTwoHundredSongsSurviveProviderRestrictionAndResumeOnlyUnfinishedEntries() async throws {
        let f = try LibraryFixture(count: 2), repo = f.storage.playlistMigrations, input = source(200)
        let tracksBefore = try await f.storage.database.dbQueue.read { try StoredTrack.fetchCount($0) }
        let session = try await repo.createPlaylist(from: input, operationID: "200-restricted")
        let provider = RestrictingDiscovery(restrictAt: 10)
        let service = PlaylistMigrationMatchingService(repository: repo, providers: [provider])
        try await service.run(migrationID: session.id) { _ in }
        var summary = try await repo.matchingSummary(migrationID: session.id)
        XCTAssertEqual(summary.processed, 11); XCTAssertEqual(summary.discoveryFailed, 1)
        XCTAssertEqual(summary.deferred, 189); XCTAssertEqual(summary.noMatch, 0)
        XCTAssertTrue(summary.discoveryPaused)
        let savedCandidates = summary.candidates

        // Manual resolution while discovery is paused.
        var entries = try await repo.entries(migrationID: session.id)
        try await repo.confirmYouTubeCandidate(for: entries[150], video: video(), metadataVerified: true)

        await provider.heal()
        try await service.run(migrationID: session.id) { _ in }
        let calls = await provider.calls
        XCTAssertEqual(calls, Array(0...10) + [10] + Array(11..<200).filter { $0 != 150 })
        entries = try await repo.entries(migrationID: session.id)
        XCTAssertEqual(entries.map(\.source), input.entries)
        XCTAssertEqual(entries[150].status, .matched); XCTAssertNil(entries[150].localTrackID)
        summary = try await repo.matchingSummary(migrationID: session.id)
        XCTAssertEqual(summary.processed, 200); XCTAssertEqual(summary.deferred, 0)
        XCTAssertEqual(summary.selected, 1); XCTAssertEqual(summary.discoveryFailed, 0)
        XCTAssertEqual(summary.alreadyLocal + summary.localMatches, 0, "A selected video is not offline-ready")
        XCTAssertGreaterThan(summary.candidates, savedCandidates)
        let tracksAfter = try await f.storage.database.dbQueue.read { try StoredTrack.fetchCount($0) }
        XCTAssertEqual(tracksAfter, tracksBefore, "Manual selection never creates or removes audio")
    }

    func testManualSelectionPersistsAcrossRestartWithMetadataAndEvidence() async throws {
        let f = try LibraryFixture(count: 0), repo = f.storage.playlistMigrations
        let session = try await repo.createPlaylist(from: source(3), operationID: "restart")
        let entry = try await repo.entries(migrationID: session.id)[0]
        try await repo.confirmYouTubeCandidate(for: entry, video: video(), metadataVerified: true)

        let reopened = try StorageCoordinator(paths: f.paths).playlistMigrations
        try reopened.recover()
        let stored = try await reopened.candidates(entryID: entry.id)
        let candidate = try XCTUnwrap(stored.first)
        XCTAssertEqual(candidate.decision, .accepted); XCTAssertEqual(candidate.providerTrackID, id)
        XCTAssertEqual(candidate.title, "Artist - Song 3"); XCTAssertEqual(candidate.durationMs, 181_000)
        XCTAssertEqual(candidate.evidence["channel"], "Artist"); XCTAssertEqual(candidate.evidence["selectionMethod"], "manual")
        XCTAssertNotNil(candidate.evidence["hardGateFailures"], "Strict check results are retained, not relaxed")
        XCTAssertEqual(MatchingCandidateArtwork.watchURL(candidate)?.absoluteString, "https://www.youtube.com/watch?v=\(id)")
        XCTAssertEqual(MatchingCandidateArtwork.thumbnail(candidate)?.host, "i.ytimg.com")
        let status = try await reopened.entries(migrationID: session.id)[0].status
        XCTAssertEqual(status, .matched)
    }

    func testDuplicateOccurrencesKeepIndependentSelections() async throws {
        let f = try LibraryFixture(count: 0), repo = f.storage.playlistMigrations
        let session = try await repo.createPlaylist(from: source(2, duplicate: true), operationID: "dupes")
        var entries = try await repo.entries(migrationID: session.id)
        try await repo.confirmYouTubeCandidate(for: entries[0], video: video(), metadataVerified: true)
        entries = try await repo.entries(migrationID: session.id)
        XCTAssertEqual(entries[0].status, .matched); XCTAssertEqual(entries[1].status, .pending)
        let second = try await repo.candidates(entryID: entries[1].id)
        XCTAssertTrue(second.isEmpty)
        try await repo.confirmYouTubeCandidate(for: entries[1], video: video("abcdefghijk"), metadataVerified: false)
        let first = try await repo.candidates(entryID: entries[0].id).map(\.providerTrackID)
        let other = try await repo.candidates(entryID: entries[1].id)
        XCTAssertEqual(first, [id]); XCTAssertEqual(other.map(\.providerTrackID), ["abcdefghijk"])
        XCTAssertEqual(other.first?.evidence["metadataSource"], "unavailable")
    }

    func testRejectionAllowsReplacementAndRejectedVideoIsNotReproposed() async throws {
        let f = try LibraryFixture(count: 0), repo = f.storage.playlistMigrations
        let session = try await repo.createPlaylist(from: source(1), operationID: "replace")
        var entry = try await repo.entries(migrationID: session.id)[0]
        let first = try await repo.confirmYouTubeCandidate(for: entry, video: video(), metadataVerified: true)
        entry = try await repo.entries(migrationID: session.id)[0]
        do { try await repo.confirmYouTubeCandidate(for: entry, video: video("abcdefghijk"), metadataVerified: true); XCTFail("Second accept must fail") }
        // A matched entry is no longer selectable: the status guard rejects the
        // replacement before any write, so the existing selection must be rejected first.
        catch { XCTAssertEqual(error as? SongMatchingError, .staleAttempt) }
        let unchanged = try await repo.candidates(entryID: entry.id)
        XCTAssertEqual(unchanged.map(\.providerTrackID), [id]); XCTAssertEqual(unchanged.first?.decision, .accepted)

        try await repo.rejectYouTubeSelection(entryID: entry.id, candidateID: first.id)
        entry = try await repo.entries(migrationID: session.id)[0]
        XCTAssertEqual(entry.status, .needsReview)
        try await repo.confirmYouTubeCandidate(for: entry, video: video("abcdefghijk"), metadataVerified: true)
        let stored = try await repo.candidates(entryID: entry.id)
        XCTAssertEqual(stored.first { $0.providerTrackID == id }?.decision, .rejected)
        XCTAssertEqual(stored.first { $0.providerTrackID == "abcdefghijk" }?.decision, .accepted)
    }

    func testStaleEntryCannotBeConfirmed() async throws {
        let f = try LibraryFixture(count: 0), repo = f.storage.playlistMigrations
        let session = try await repo.createPlaylist(from: source(1), operationID: "stale")
        let stale = try await repo.entries(migrationID: session.id)[0]
        try await repo.updateEntryStatus(entryID: stale.id, to: .skipped)
        do { try await repo.confirmYouTubeCandidate(for: stale, video: video(), metadataVerified: true); XCTFail("Stale entry accepted") }
        catch { XCTAssertTrue(error is SongMatchingError) }
    }

    func testManualLinkValidationAndCredentialFreeMetadataFallbacks() async throws {
        let ok = YouTubeManualLookup(metadata: FixedMetadata(result: .success(video())), transport: FixedTransport(status: 500, body: ""))
        for link in ["https://www.youtube.com/watch?v=\(id)&t=10", "https://youtu.be/\(id)", "https://m.youtube.com/shorts/\(id)", id] {
            let result = try await ok.lookup(link)
            XCTAssertEqual(result.video.id, id); XCTAssertTrue(result.metadataVerified)
            XCTAssertEqual(result.video.canonicalURL?.absoluteString, "https://www.youtube.com/watch?v=\(id)")
        }
        for bad in ["", "http://www.youtube.com/watch?v=\(id)", "https://evil.example/watch?v=\(id)", "https://www.youtube.com/watch?v=short"] {
            do { _ = try await ok.lookup(bad); XCTFail("Accepted \(bad)") }
            catch { XCTAssertEqual(error as? YouTubeError, .invalidURL) }
        }
        let embed = YouTubeManualLookup(metadata: FixedMetadata(result: .failure(.providerRestricted)),
            transport: FixedTransport(status: 200, body: #"{"title":"Artist - Song 3","author_name":"Artist","thumbnail_url":"https://i.ytimg.com/vi/\#(id)/hqdefault.jpg"}"#))
        let fromEmbed = try await embed.lookup(id)
        XCTAssertTrue(fromEmbed.metadataVerified); XCTAssertEqual(fromEmbed.video.channel, "Artist"); XCTAssertNil(fromEmbed.video.duration)

        let blocked = YouTubeManualLookup(metadata: FixedMetadata(result: .failure(.providerRestricted)), transport: FixedTransport(status: 302, body: ""))
        let idOnly = try await blocked.lookup(id)
        XCTAssertFalse(idOnly.metadataVerified); XCTAssertEqual(idOnly.video.thumbnailURL?.host, "i.ytimg.com")

        let missing = YouTubeManualLookup(metadata: FixedMetadata(result: .failure(.metadataUnavailable)), transport: FixedTransport(status: 404, body: ""))
        do { _ = try await missing.lookup(id); XCTFail("Missing video accepted") }
        catch { XCTAssertEqual(error as? YouTubeError, .videoUnavailable) }
    }
}
