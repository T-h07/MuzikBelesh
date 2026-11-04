import XCTest
@testable import OFFLINE

final class YouTubeSearchStateTests: XCTestCase {
    func testNormalizationCacheExpiryInvalidationAndBound() async throws {
        XCTAssertEqual(YouTubeSearchService.normalize("  PSY\n \tGangnam   Style  "), "PSY Gangnam Style")
        XCTAssertEqual(YouTubeSearchService.normalize(String(repeating: "a", count: 600)).count, 500)
        let page = YouTubeSearchPage(videos: [YTFixture.video, YTFixture.video], continuationToken: nil)
        let stub = YTSearchStub(Array(repeating: .success(page), count: 6)), clock = YTClock()
        let service = YouTubeSearchService(provider: stub, lifetime: 10, capacity: 1, now: { clock.now() })
        let first = try await service.search(query: " song ", continuationToken: nil)
        XCTAssertEqual(first.videos.count, 1)
        _ = try await service.search(query: "song", continuationToken: nil)
        var count = await stub.calls.count; XCTAssertEqual(count, 1)
        clock.advance(11); _ = try await service.search(query: "song", continuationToken: nil)
        count = await stub.calls.count; XCTAssertEqual(count, 2)
        await service.invalidate(); _ = try await service.search(query: "song", continuationToken: nil)
        count = await stub.calls.count; XCTAssertEqual(count, 3)
        _ = try await service.search(query: "other", continuationToken: nil)
        _ = try await service.search(query: "song", continuationToken: nil)
        count = await stub.calls.count; XCTAssertEqual(count, 5, "Capacity eviction must bound memory")
        _ = try await service.search(query: " \n ", continuationToken: nil)
        count = await stub.calls.count; XCTAssertEqual(count, 5)
    }
    @MainActor func testDebounceCancelsSupersededQueryBeforeNetwork() async {
        let stub = YTSearchStub([.success(YouTubeSearchPage(videos: [YTFixture.video], continuationToken: nil))])
        let model = YouTubeSearchViewModel(provider: stub)
        model.search("first"); model.search(" second  query ")
        let early = await stub.calls; XCTAssertTrue(early.isEmpty)
        await model.waitForRequest()
        let calls = await stub.calls; XCTAssertEqual(calls, ["second query:first"])
        XCTAssertEqual(model.state, .results)
    }
    @MainActor func testOldUncooperativeResponseCannotOverwriteNewQueryOrCancellation() async {
        let stub = YTSuspendedSearch()
        // Each model has one authoritative generation, even when a provider ignores cancellation.
        let subject = YouTubeSearchViewModel(provider: stub, debounce: {})
        subject.search("old"); await ytEventually { await stub.calls.contains("old") }
        subject.search("new"); await ytEventually { await stub.calls.contains("new") }
        var newer = YTFixture.video; newer.title = "New"
        await stub.finish("new", video: newer); await subject.waitForRequest()
        await stub.finish("old", video: YTFixture.video)
        await Task.yield()
        XCTAssertEqual(subject.videos.first?.title, "New")
        subject.search("cancelled"); await ytEventually { await stub.calls.contains("cancelled") }
        subject.cancel(); await stub.finish("cancelled", video: YTFixture.video); await Task.yield()
        XCTAssertEqual(subject.state, .idle); XCTAssertTrue(subject.videos.isEmpty)
    }
    @MainActor func testPaginationDeduplicatesAndRejectsRepeatedTokensAndDoubleTap() async {
        let second = YouTubeVideo(id: YTFixture.secondID, title: "Second")
        let stub = YTSearchStub([.success(YouTubeSearchPage(videos: [YTFixture.video], continuationToken: "next")), .success(YouTubeSearchPage(videos: [YTFixture.video, second], continuationToken: "next"))])
        let model = YouTubeSearchViewModel(provider: stub, debounce: {})
        model.search("query"); await model.waitForRequest()
        model.loadMore(); model.loadMore(); await model.waitForRequest()
        XCTAssertEqual(model.videos.map(\.id), [YTFixture.id, YTFixture.secondID]); XCTAssertNil(model.continuation)
        model.loadMore(); let count = await stub.calls.count; XCTAssertEqual(count, 2)
        model.search("query"); let after = await stub.calls.count; XCTAssertEqual(after, 2, "Returning from details preserves results")
    }
    @MainActor func testEmptyErrorRetryAndPageFailurePreserveEarlierResults() async {
        let stub = YTSearchStub([.failure(.networkUnavailable), .success(YouTubeSearchPage(videos: [], continuationToken: nil)), .success(YouTubeSearchPage(videos: [YTFixture.video], continuationToken: "page2")), .failure(.requestTimeout), .success(YouTubeSearchPage(videos: [], continuationToken: nil))])
        let model = YouTubeSearchViewModel(provider: stub, debounce: {})
        model.search("query"); await model.waitForRequest(); XCTAssertEqual(model.state, .failed(.networkUnavailable))
        model.retry(); await model.waitForRequest(); XCTAssertEqual(model.state, .empty)
        model.search("new"); await model.waitForRequest()
        model.loadMore(); await model.waitForRequest(); XCTAssertEqual(model.pageError, .requestTimeout); XCTAssertEqual(model.videos.count, 1)
        model.loadMore(); await model.waitForRequest(); XCTAssertNil(model.pageError); XCTAssertNil(model.continuation); XCTAssertEqual(model.videos.count, 1)
    }
}
