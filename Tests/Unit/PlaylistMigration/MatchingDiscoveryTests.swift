import XCTest
@testable import OFFLINE

private actor MatchingYouTubeMock: YouTubeSearchProvider, YouTubeMetadataProvider {
    let videos: [YouTubeVideo]
    let failSecond: Bool
    let failFirstMetadata: Bool
    var searches = 0
    var inspections = 0
    var tokens: [String?] = []
    init(_ videos: [YouTubeVideo], failSecond: Bool = false, failFirstMetadata: Bool = false) {
        self.videos = videos; self.failSecond = failSecond; self.failFirstMetadata = failFirstMetadata
    }
    func search(query: String, continuationToken: String?) async throws -> YouTubeSearchPage {
        searches += 1; tokens.append(continuationToken)
        if failSecond && searches == 2 { throw YouTubeError.rateLimited }
        return .init(videos: videos, continuationToken: "never-follow-this")
    }
    func metadata(videoID: String) async throws -> YouTubeVideo {
        inspections += 1
        if failFirstMetadata && inspections == 1 { throw YouTubeError.metadataUnavailable }
        var value = videos.first { $0.id == videoID }!
        value.availability = .available
        return value
    }
}

final class MatchingDiscoveryTests: XCTestCase {
    private let source = PlaylistMigrationSourceTrack(position: 0, title: "Song (Studio)", primaryArtist: "Artist A", durationMs: 180000)
    private func video(_ id: String = "abcdefghijk", title: String = "Artist A - Song (Studio)", availability: YouTubeVideo.Availability = .unknown) -> YouTubeVideo {
        .init(id: id, title: title, channel: "Artist A", channelID: nil, thumbnailURL: nil, duration: 180, availability: availability)
    }
    func testDeduplicationAvailabilityAndBoundedMetadataWithoutPagination() async throws {
        let good = video()
        let provider = MatchingYouTubeMock([good, good, video("xxxxxxxxxxx", availability: .live), video("yyyyyyyyyyy", availability: .upcoming), video("zzzzzzzzzzz", availability: .unavailable), video("invalid"), video("12345678901", title: "Unrelated video")])
        let result = try await YouTubeSearchProviderAdapter(search: provider, metadata: provider).discover(source)
        XCTAssertEqual(result.recordings.count, 1); XCTAssertTrue(result.recordings[0].available)
        let searches = await provider.searches, inspections = await provider.inspections, tokens = await provider.tokens
        XCTAssertEqual(searches, 1); XCTAssertEqual(inspections, 1); XCTAssertTrue(tokens.allSatisfy { $0 == nil })
    }
    func testChannelAloneDoesNotEstablishArtistAndSearchIsNotAvailability() async throws {
        let provider = MatchingYouTubeMock([video(title: "Song (Studio)")])
        let result = try await YouTubeSearchProviderAdapter(search: provider).discover(source)
        XCTAssertNil(result.recordings[0].artist)
        XCTAssertFalse(result.recordings[0].performerEstablished); XCTAssertFalse(result.recordings[0].available)
    }
    func testPartialProviderFailureKeepsEarlierResults() async throws {
        let provider = MatchingYouTubeMock([video(title: "Song (Studio)")], failSecond: true)
        let result = try await YouTubeSearchProviderAdapter(search: provider).discover(source)
        XCTAssertEqual(result.recordings.count, 1); XCTAssertEqual(result.failures.count, 1)
        XCTAssertFalse(result.recordings[0].available)
        XCTAssertTrue(result.pauseDiscovery)
    }
    func testResultAndRequestCaps() async throws {
        let videos = (0..<50).map { video(String(format: "%011d", $0)) }
        let provider = MatchingYouTubeMock(videos)
        let result = try await YouTubeSearchProviderAdapter(search: provider, metadata: provider).discover(source)
        XCTAssertEqual(result.recordings.count, 20); XCTAssertTrue(result.truncated)
        let searches = await provider.searches, inspections = await provider.inspections
        XCTAssertEqual(searches, 1); XCTAssertEqual(inspections, 3)
    }
    func testIndividualMetadataFailureIsReportedAndLaterCandidatesAreInspected() async throws {
        let provider = MatchingYouTubeMock([video(), video("xxxxxxxxxxx")], failFirstMetadata: true)
        let result = try await YouTubeSearchProviderAdapter(search: provider, metadata: provider).discover(source)
        let inspections = await provider.inspections
        XCTAssertEqual(inspections, 2)
        XCTAssertEqual(result.failure, .metadataUnavailable)
        XCTAssertEqual(result.failures.count, 1)
        XCTAssertEqual(result.recordings.filter(\.available).count, 1)
    }
    func testQueriesDoNotInventRecordingVersions() {
        let plain = PlaylistMigrationSourceTrack(position: 0, title: "Song", primaryArtist: "Artist")
        XCTAssertEqual(YouTubeSearchProviderAdapter.queries(plain), ["Artist Song", "Artist Song Official Audio"])
        let live = PlaylistMigrationSourceTrack(position: 0, title: "Song (Live)", primaryArtist: "Artist")
        XCTAssertTrue(YouTubeSearchProviderAdapter.queries(live).allSatisfy { $0.contains("Live") })
    }
}
