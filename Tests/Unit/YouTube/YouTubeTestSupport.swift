import Foundation
import XCTest
@testable import OFFLINE

enum YTFixture {
    static let id = "9bZkp7q19f0"
    static let secondID = "dQw4w9WgXcQ"
    static let video = YouTubeVideo(id: id, title: "Original title", channel: "Fixture artist", duration: 253, availability: .available)
    static func option(_ id: Int = 140, rate: Int? = 128_000, container: String = "m4a", codec: String? = "mp4a.40.2", native: Bool = true, audioOnly: Bool = true) -> AudioStreamOption {
        AudioStreamOption(id: id, container: container, codec: codec, bitrate: rate, isAudioOnly: audioOnly, isNativelyPlayable: native)
    }
    static func resolved(video: YouTubeVideo = video, date: Date = Date()) -> ResolvedAudioStream {
        ResolvedAudioStream(video: video, options: [option()], selected: option(), url: URL(string: "https://test.googlevideo.com/videoplayback?token=secret")!, resolvedAt: date, expiresAt: date.addingTimeInterval(600))
    }
    static func renderer(id: String = id, title: String = "Real result") -> [String: Any] {
        ["videoRenderer": ["videoId": id, "title": ["runs": [["text": title]]], "ownerText": ["runs": [["text": "Artist", "navigationEndpoint": ["browseEndpoint": ["browseId": "UC-example"]]]]],
                           "lengthText": ["simpleText": "4:13"], "thumbnail": ["thumbnails": [["url": "https://i.ytimg.com/vi/\(id)/hqdefault.jpg"]]]]]
    }
    static func initial(_ items: [[String: Any]]) -> [String: Any] {
        ["contents": ["twoColumnSearchResultsRenderer": ["primaryContents": ["sectionListRenderer": ["contents": [["itemSectionRenderer": ["contents": items]], ["continuationItemRenderer": ["continuationEndpoint": ["continuationCommand": ["token": "next"]]]]]]]]]]
    }
    static func watch(status: String = "OK", id: String = id) -> [String: Any] {
        ["playabilityStatus": ["status": status], "videoDetails": ["videoId": id, "title": "Watch title", "author": "Watch artist", "channelId": "UC-example", "lengthSeconds": "253", "thumbnail": ["thumbnails": [["url": "https://i.ytimg.com/vi/\(id)/hqdefault.jpg"]]]]]
    }
    static func json(_ object: [String: Any]) throws -> String { String(decoding: try JSONSerialization.data(withJSONObject: object), as: UTF8.self) }
}

actor YTSearchStub: YouTubeSearchProvider {
    var pages: [Result<YouTubeSearchPage, YouTubeError>]
    private(set) var calls: [String] = []
    init(_ pages: [Result<YouTubeSearchPage, YouTubeError>]) { self.pages = pages }
    func search(query: String, continuationToken: String?) async throws -> YouTubeSearchPage {
        calls.append(query + ":" + (continuationToken ?? "first"))
        guard !pages.isEmpty else { throw YouTubeError.searchUnavailable }
        return try pages.removeFirst().get()
    }
}
actor YTSuspendedSearch: YouTubeSearchProvider {
    private(set) var calls: [String] = []
    private var pending: [String: CheckedContinuation<YouTubeSearchPage, Error>] = [:]
    func search(query: String, continuationToken: String?) async throws -> YouTubeSearchPage {
        calls.append(query)
        return try await withCheckedThrowingContinuation { pending[query] = $0 }
    }
    func finish(_ query: String, video: YouTubeVideo) { pending.removeValue(forKey: query)?.resume(returning: YouTubeSearchPage(videos: [video], continuationToken: nil)) }
}
actor YTTransportStub: YouTubeTransport {
    private var responses: [YouTubeHTTPResponse]
    private(set) var requests: [URLRequest] = []
    init(_ responses: [YouTubeHTTPResponse]) { self.responses = responses }
    func send(_ request: URLRequest) async throws -> YouTubeHTTPResponse {
        requests.append(request)
        guard !responses.isEmpty else { throw URLError(.timedOut) }
        return responses.removeFirst()
    }
    static func response(_ body: String = "", status: Int = 200, contentType: String? = "text/html") -> YouTubeHTTPResponse {
        YouTubeHTTPResponse(data: Data(body.utf8), status: status, url: URL(string: "https://www.youtube.com/results")!, contentType: contentType)
    }
}
actor YTResolverStub: YouTubeAudioResolver {
    private(set) var calls = 0
    let error: YouTubeError?
    let stale: Bool
    init(error: YouTubeError? = nil, stale: Bool = false) { self.error = error; self.stale = stale }
    func resolve(video: YouTubeVideo, quality: AudioQuality) async throws -> ResolvedAudioStream {
        calls += 1
        if let error { throw error }
        return YTFixture.resolved(video: video.merging(title: "Extractor title", thumbnail: nil), date: Date().addingTimeInterval(stale ? -120 : 0))
    }
}
actor YTMetadataStub: YouTubeMetadataProvider {
    private(set) var calls = 0
    func metadata(videoID: String) async throws -> YouTubeVideo { calls += 1; return YTFixture.video }
}
struct YTLibraryStub: YouTubeLibraryChecking {
    func status(videoID: String) async throws -> YouTubeLibraryStatus { .notDownloaded }
}
final class YTClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value = Date(timeIntervalSince1970: 1000)
    func now() -> Date { lock.lock(); defer { lock.unlock() }; return value }
    func advance(_ seconds: TimeInterval) { lock.lock(); defer { lock.unlock() }; value.addTimeInterval(seconds) }
}
func ytEventually(_ condition: () async -> Bool, file: StaticString = #filePath, line: UInt = #line) async {
    for _ in 0..<100 { if await condition() { return }; try? await Task.sleep(for: .milliseconds(10)) }
    XCTFail("Expected YouTube state was not reached", file: file, line: line)
}
