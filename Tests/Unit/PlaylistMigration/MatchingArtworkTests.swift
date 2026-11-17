import XCTest
@testable import OFFLINE

final class MatchingArtworkTests: XCTestCase {
    private func candidate(_ id: String?, thumbnail: String? = nil) -> PlaylistMigrationCandidate {
        .init(id: UUID(), entryID: UUID(), provider: "youtube", providerTrackID: id, title: "Recording", artist: nil,
            durationMs: nil, confidence: nil, evidence: thumbnail.map { ["thumbnailURL": $0] } ?? [:], decision: .pending)
    }
    func testValidMissingUnsafeArtworkAndInvalidIdentity() {
        let valid = "https://i.ytimg.com/vi/abcdefghijk/hqdefault.jpg"
        XCTAssertEqual(MatchingCandidateArtwork.thumbnail(candidate("abcdefghijk", thumbnail: valid))?.absoluteString, valid)
        XCTAssertEqual(MatchingCandidateArtwork.thumbnail(candidate("abcdefghijk"))?.absoluteString, valid)
        for url in ["https://evil.example/image.jpg", valid + "?sig=private", "http://i.ytimg.com/image.jpg", "https://user:pass@i.ytimg.com/image.jpg"] {
            XCTAssertNil(MatchingCandidateArtwork.safe(URL(string: url)))
            XCTAssertEqual(MatchingCandidateArtwork.thumbnail(candidate("abcdefghijk", thumbnail: url))?.absoluteString, valid)
        }
        XCTAssertNil(MatchingCandidateArtwork.thumbnail(candidate("invalid", thumbnail: valid)))
        XCTAssertNil(MatchingCandidateArtwork.watchURL(candidate(nil)))
        XCTAssertEqual(MatchingCandidateArtwork.watchURL(candidate("abcdefghijk"))?.host, "www.youtube.com")
    }
    func testExistingArtworkLoaderCachesAndNetworkFailureIsIndependent() async throws {
        let url = try XCTUnwrap(URL(string: "https://i.ytimg.com/vi/abcdefghijk/hqdefault.jpg"))
        let data = try LibraryFixture.image()
        let transport = YTTransportStub([.init(data: data, status: 200, url: url, contentType: "image/png")])
        let loader = YouTubeArtworkLoader(transport: transport)
        let first = try await loader.image(for: url), second = try await loader.image(for: url)
        XCTAssertNotNil(first); XCTAssertNotNil(second)
        let requests = await transport.requests
        XCTAssertEqual(requests.count, 1)
        let failing = YouTubeArtworkLoader(transport: YTTransportStub([]))
        do { _ = try await failing.image(for: url); XCTFail("Expected artwork transport error") } catch { XCTAssertTrue(error is URLError) }
        // Missing artwork is an optional review aid and never touches migration state.
        let absent = await failing.downloadData(for: nil)
        XCTAssertNil(absent)
    }
}
