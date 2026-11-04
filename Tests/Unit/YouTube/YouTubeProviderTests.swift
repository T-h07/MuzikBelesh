import XCTest
@testable import OFFLINE

final class YouTubeProviderTests: XCTestCase {
    func testSearchParsingDeduplicationOptionalFieldsAndUnsupportedLayout() throws {
        let page = try YouTubeWebParser.search(YTFixture.initial([YTFixture.renderer(), YTFixture.renderer(), YTFixture.renderer(id: YTFixture.secondID)]))
        XCTAssertEqual(page.videos.map(\.id), [YTFixture.id, YTFixture.secondID]); XCTAssertEqual(page.continuationToken, "next")
        XCTAssertEqual(page.videos.first?.channelID, "UC-example"); XCTAssertEqual(page.videos.first?.duration, 253)
        let minimal: [String: Any] = ["videoRenderer": ["videoId": YTFixture.id, "title": ["simpleText": "Title"]]]
        let video = try XCTUnwrap(YouTubeWebParser.search(YTFixture.initial([minimal])).videos.first)
        XCTAssertNil(video.channel); XCTAssertNil(video.duration); XCTAssertNil(video.thumbnailURL)
        XCTAssertThrowsError(try YouTubeWebParser.search(["changedSchema": true]))
        XCTAssertThrowsError(try YouTubeWebParser.search(YTFixture.initial([["unknownRenderer": [:]]])))
        XCTAssertTrue(try YouTubeWebParser.search(YTFixture.initial([["messageRenderer": ["text": ["simpleText": "No results"]]]])).videos.isEmpty)
    }
    func testBalancedJSONHandlesStringsEscapesAndEarlierNonJSONMarker() throws {
        let value = "quoted \" } \\ { value"
        let html = "ytcfg.set(config); ytcfg.set(\(try YTFixture.json(["value": value]))); trailing"
        XCTAssertEqual(try YouTubeWebParser.object(in: html, markers: ["ytcfg.set("])["value"] as? String, value)
        XCTAssertThrowsError(try YouTubeWebParser.object(in: "ytcfg.set({ broken", markers: ["ytcfg.set("]))
    }
    func testProviderBootstrapsDynamicContextAndPaginationWithoutCredentials() async throws {
        let html = "var ytInitialData = \(try YTFixture.json(YTFixture.initial([YTFixture.renderer()])));ytcfg.set(\(try YTFixture.json(["INNERTUBE_CONTEXT": ["client": ["clientName": "WEB", "clientVersion": "observed-version"]]])));"
        let second: [String: Any] = ["onResponseReceivedCommands": [["appendContinuationItemsAction": ["continuationItems": [YTFixture.renderer(id: YTFixture.secondID)]]]]]
        let transport = YTTransportStub([.init(data: Data(html.utf8), status: 200, url: URL(string: "https://www.youtube.com/results")!, contentType: "text/html"), YTTransportStub.response(try YTFixture.json(second))])
        let provider = YouTubeWebProvider(transport: transport)
        let page = try await provider.search(query: "Artist & song", continuationToken: nil)
        let more = try await provider.search(query: "Artist & song", continuationToken: page.continuationToken)
        XCTAssertEqual(more.videos.first?.id, YTFixture.secondID); XCTAssertNil(more.continuationToken)
        let requests = await transport.requests
        XCTAssertEqual(requests.count, 2); XCTAssertEqual(requests[1].httpMethod, "POST")
        XCTAssertNil(requests[1].value(forHTTPHeaderField: "Cookie")); XCTAssertNil(requests[1].value(forHTTPHeaderField: "Authorization"))
        let body = try XCTUnwrap(requests[1].httpBody)
        XCTAssertTrue(String(decoding: body, as: UTF8.self).contains("observed-version"))
        do { _ = try await provider.search(query: "different query", continuationToken: page.continuationToken); XCTFail() } catch { XCTAssertEqual(error as? YouTubeError, .searchUnavailable) }
    }
    func testWatchMetadataAndRestrictionFailures() throws {
        let video = try YouTubeWebParser.watch(YTFixture.watch(), videoID: YTFixture.id)
        XCTAssertEqual(video.title, "Watch title"); XCTAssertEqual(video.channel, "Watch artist"); XCTAssertEqual(video.durationLabel, "4:13")
        XCTAssertEqual(video.availability, .available)
        for status in ["LOGIN_REQUIRED", "AGE_CHECK_REQUIRED", "CONTENT_CHECK_REQUIRED", "ERROR", "UNPLAYABLE", "LIVE_STREAM_OFFLINE", "UNKNOWN"] {
            XCTAssertThrowsError(try YouTubeWebParser.watch(YTFixture.watch(status: status), videoID: YTFixture.id))
        }
        XCTAssertThrowsError(try YouTubeWebParser.watch(YTFixture.watch(id: YTFixture.secondID), videoID: YTFixture.id))
        XCTAssertEqual(video.merging(title: "", thumbnail: URL(string: "https://attacker.example/image")).title, video.title)
        XCTAssertEqual(video.merging(title: "Extractor", thumbnail: nil).channel, video.channel)
    }
    func testHTTPAndNetworkErrorsAreSanitizedAndRedirectHostsRestricted() async throws {
        for (status, expected) in [(403, YouTubeError.accessRestricted), (429, .rateLimited), (504, .requestTimeout), (500, .searchUnavailable)] {
            let provider = YouTubeWebProvider(transport: YTTransportStub([YTTransportStub.response(status: status)]))
            do { _ = try await provider.search(query: "song", continuationToken: nil); XCTFail() } catch { XCTAssertEqual(error as? YouTubeError, expected) }
        }
        XCTAssertEqual(YouTubeError.map(URLError(.notConnectedToInternet), fallback: .extractionFailed), .networkUnavailable)
        XCTAssertEqual(YouTubeError.map(CancellationError(), fallback: .extractionFailed), .cancelled)
        for url in ["http://www.youtube.com", "https://youtube.com.evil.example", "https://consent.youtube.com", "https://accounts.google.com", "https://user:pass@www.youtube.com"] {
            XCTAssertFalse(YouTubeURLSessionTransport.permitted(URL(string: url)!))
        }
    }
}
