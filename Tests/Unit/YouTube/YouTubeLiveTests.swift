import AVFoundation
import XCTest
@testable import OFFLINE

// Opt-in only: these measure external compatibility, never ordinary CI correctness.
final class YouTubeLiveTests: XCTestCase {
    override func setUpWithError() throws {
        guard ProcessInfo.processInfo.environment["MB_YOUTUBE_LIVE"] == "1" else { throw XCTSkip("Live YouTube checks require explicit opt-in") }
        executionTimeAllowance = 120
    }
    func testLiveSearchAndContinuation() async throws {
        let provider = YouTubeWebProvider(transport: YouTubeURLSessionTransport())
        do {
            let page = try await provider.search(query: "PSY GANGNAM STYLE", continuationToken: nil)
            XCTAssertTrue(page.videos.contains { $0.id == "9bZkp7q19f0" })
            let token = try XCTUnwrap(page.continuationToken)
            let more = try await provider.search(query: "PSY GANGNAM STYLE", continuationToken: token)
            XCTAssertFalse(more.videos.isEmpty)
        } catch { XCTFail("Live search compatibility: \(YouTubeError.map(error, fallback: .searchUnavailable).localizedDescription)") }
    }
    func testLivePSYLocalResolution() async { await resolve("9bZkp7q19f0") }
    func testLiveNEKOLocalResolution() async throws {
        let provider = YouTubeWebProvider(transport: YouTubeURLSessionTransport())
        do {
            let page = try await provider.search(query: "NEKO N'FRONT", continuationToken: nil)
            let video = try XCTUnwrap(page.videos.first(where: { $0.title.localizedCaseInsensitiveContains("NEKO") && $0.title.localizedCaseInsensitiveContains("FRONT") }))
            await resolve(video.id)
        } catch { XCTFail("Live NEKO discovery: \(YouTubeError.map(error, fallback: .searchUnavailable).localizedDescription)") }
    }
    func testLiveOpenMovieLocalResolution() async { await resolve("aqz-KE-bpKQ") }
    func testAuthorizedOpenMovieTransferAndOfflineDecode() async throws {
        let transport = YouTubeURLSessionTransport()
        let resolver = YouTubeKitAudioResolver(metadata: YouTubeWebProvider(transport: transport), transport: transport)
        let video = YouTubeVideo(id: "aqz-KE-bpKQ", title: "Big Buck Bunny")
        let stream = try await resolver.resolve(video: video, quality: .dataSaver)
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".m4a")
        defer { try? FileManager.default.removeItem(at: file) }
        try await TransferService().download(stream.url, to: file, wifiOnly: true) { _, _ in }
        try await DownloadMedia.validate(file)
        let decoder = try AVAudioFile(forReading: file)
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: decoder.processingFormat, frameCapacity: 4096))
        try decoder.read(into: buffer)
        XCTAssertGreaterThan(buffer.frameLength, 0)
    }
    func testLiveUnavailableVideoFailsExplicitly() async {
        do {
            _ = try await YouTubeWebProvider(transport: YouTubeURLSessionTransport()).metadata(videoID: "___________")
            XCTFail("Expected unavailable sample to fail")
        } catch { XCTAssertTrue(error is YouTubeError) }
    }
    private func resolve(_ id: String) async {
        let transport = YouTubeURLSessionTransport(), video = YouTubeVideo(id: id, title: "Live sample")
        let resolver = YouTubeKitAudioResolver(metadata: YouTubeWebProvider(transport: transport), transport: transport)
        do {
            let result = try await resolver.resolve(video: video, quality: .high)
            XCTAssertFalse(result.video.title.isEmpty); XCTAssertTrue(result.selected.isCompatible)
            XCTAssertTrue(result.options.allSatisfy(\.isAudioOnly)); XCTAssertTrue(result.isFresh(at: Date()))
        } catch { XCTFail("Live local extraction for \(id): \(YouTubeError.map(error, fallback: .extractionFailed).localizedDescription)") }
    }
}
