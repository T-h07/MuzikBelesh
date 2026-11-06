import XCTest
import YouTubeKit
@testable import OFFLINE

final class YouTubeAudioTests: XCTestCase {
    func testLocalExtractionConfigurationCannotEnableRemoteFallback() {
        XCTAssertEqual(YouTubeKitAudioResolver.extractionMethods, [.local])
        // Compiles against the exact pinned API rather than a parallel fake kit model.
        let local = YouTube(videoID: YTFixture.id, methods: YouTubeKitAudioResolver.extractionMethods)
        XCTAssertEqual(local.videoID, YTFixture.id)
    }
    func testAudioOnlyCompatibilityAndM4APreferenceBeforeBitrate() throws {
        let m4a = YTFixture.option(140, rate: 128_000)
        let choices = [YTFixture.option(1, rate: 999_000, audioOnly: false), YTFixture.option(2, rate: 256_000, container: "webm", codec: "opus", native: false), YTFixture.option(3, rate: 320_000, container: "mp4", codec: "ac-3"), m4a]
        XCTAssertEqual(try AudioStreamSelector.select(choices, quality: .high), m4a)
        XCTAssertFalse(YTFixture.option(codec: nil).isCompatible)
        XCTAssertFalse(YTFixture.option(codec: "unknown").isCompatible)
        XCTAssertFalse(YTFixture.option(native: false).isCompatible)
        XCTAssertFalse(YTFixture.option(container: "webm").isCompatible)
        XCTAssertEqual(try AudioStreamSelector.select([choices[2]], quality: .standard), choices[2])
    }
    func testQualityRankingStandardFallbackAndUnknownBitrate() throws {
        let choices = [YTFixture.option(1, rate: 48_000), YTFixture.option(2, rate: 128_000), YTFixture.option(3, rate: 256_000), YTFixture.option(4, rate: nil)]
        XCTAssertEqual(try AudioStreamSelector.select(choices, quality: .dataSaver).id, 1)
        XCTAssertEqual(try AudioStreamSelector.select(choices, quality: .standard).id, 2)
        XCTAssertEqual(try AudioStreamSelector.select(choices, quality: .high).id, 3)
        XCTAssertEqual(try AudioStreamSelector.select([choices[0], choices[2]], quality: .standard).id, 1)
        XCTAssertEqual(try AudioStreamSelector.select([choices[2]], quality: .standard).id, 3)
        XCTAssertNil(try AudioStreamSelector.select([choices[3]], quality: .high).bitrate)
        XCTAssertThrowsError(try AudioStreamSelector.select([], quality: .high)) { XCTAssertEqual($0 as? YouTubeError, .noAudioStreams) }
        XCTAssertThrowsError(try AudioStreamSelector.select([YTFixture.option(native: false)], quality: .high)) { XCTAssertEqual($0 as? YouTubeError, .noCompatibleAudio) }
        XCTAssertThrowsError(try AudioStreamSelector.select([YTFixture.option(rate: -1)], quality: .high))
    }
    func testReadinessWaitsBoundedlyUsesHEADAndRejectsExpiredOrForeignURLs() async throws {
        let transport = YTTransportStub([YTTransportStub.response(status: 403), YTTransportStub.response(status: 503), YTTransportStub.response(contentType: "audio/mp4")])
        let readiness = YouTubeStreamReadiness(transport: transport, delay: {})
        _ = try await readiness.verify(YTFixture.resolved().url)
        let requests = await transport.requests
        XCTAssertEqual(requests.count, 3); XCTAssertTrue(requests.allSatisfy { $0.httpMethod == "HEAD" && $0.httpBody == nil })
        for url in ["https://test.googlevideo.com/videoplayback?expire=1", "https://evil.example/videoplayback", "https://test.googlevideo.com/videoplayback?expire=NaN"] {
            do { _ = try await readiness.verify(URL(string: url)!); XCTFail() } catch { XCTAssertTrue(error is YouTubeError) }
        }
        let rejected = YTTransportStub(Array(repeating: YTTransportStub.response(status: 403), count: 3))
        do { _ = try await YouTubeStreamReadiness(transport: rejected, delay: {}).verify(YTFixture.resolved().url); XCTFail() }
        catch { XCTAssertEqual(error as? YouTubeError, .streamExpired) }
        let count = await rejected.requests.count; XCTAssertEqual(count, 3)
    }
    func testPreparedContractRefreshesAndRedactsSignedURL() async throws {
        let resolver = YTResolverStub(), preparer = YouTubeDownloadPreparer(resolver: YTResolverStub())
        let request = try await preparer.prepare(video: YTFixture.video, quality: .high)
        XCTAssertEqual(request.videoID, YTFixture.id); XCTAssertEqual(request.quality, .high); XCTAssertEqual(request.metadata.title, "Extractor title")
        XCTAssertFalse(String(describing: request).contains("secret")); XCTAssertFalse(String(reflecting: request.stream).contains("secret"))
        _ = try await YouTubeDownloadPreparer(resolver: resolver).prepare(video: YTFixture.video, quality: .standard)
        _ = try await YouTubeDownloadPreparer(resolver: resolver).prepare(video: YTFixture.video, quality: .standard)
        let count = await resolver.calls; XCTAssertEqual(count, 2)
        do { _ = try await YouTubeDownloadPreparer(resolver: YTResolverStub(stale: true)).prepare(video: YTFixture.video, quality: .high); XCTFail() }
        catch { XCTAssertEqual(error as? YouTubeError, .streamExpired) }
    }
    @MainActor func testDetailsStatesMetadataReuseAndRealPreparationBoundary() async {
        let metadata = YTMetadataStub(), resolver = YTResolverStub()
        let model = VideoDetailsViewModel(video: YTFixture.video, metadata: metadata, resolver: resolver, preparer: YouTubeDownloadPreparer(resolver: resolver), library: YTLibraryStub())
        model.load(quality: .standard); model.load(quality: .standard)
        XCTAssertEqual(model.state, .loadingMetadata)
        await model.waitForRequest(); XCTAssertEqual(model.state, .ready); XCTAssertEqual(model.video.title, "Extractor title")
        model.prepare(quality: .high); await model.waitForRequest()
        XCTAssertEqual(model.preparedRequest?.quality, .high); XCTAssertEqual(model.libraryStatus, .notDownloaded)
        let metadataCalls = await metadata.calls, resolveCalls = await resolver.calls
        XCTAssertEqual(metadataCalls, 1); XCTAssertEqual(resolveCalls, 2)
        model.cancel(); XCTAssertNil(model.preparedRequest)
    }
    @MainActor func testDetailsRecoverableAndUnavailableErrorsAndPreferencesPersist() async throws {
        for error in [YouTubeError.networkUnavailable, .noCompatibleAudio, .accessRestricted, .cancelled] {
            let resolver = YTResolverStub(error: error)
            let model = VideoDetailsViewModel(video: YTFixture.video, metadata: YTMetadataStub(), resolver: resolver, preparer: YouTubeDownloadPreparer(resolver: resolver), library: YTLibraryStub())
            model.load(quality: .standard); await model.waitForRequest()
            XCTAssertNil(model.preparedRequest); XCTAssertNil(model.stream)
            XCTAssertEqual(model.state, error == .cancelled ? .idle : error.canRetry ? .failed(error) : .unavailable(error))
        }
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "Phase6-\(UUID().uuidString)"))
        // Only this test's preference key is touched; library storage is independent.
        defer { defaults.removeObject(forKey: "youtube.audioQuality") }
        defaults.set("Lossless", forKey: "youtube.audioQuality")
        XCTAssertEqual(YouTubePreferences(defaults: defaults).quality, .standard)
        let preferences = YouTubePreferences(defaults: defaults); preferences.quality = .dataSaver
        XCTAssertEqual(YouTubePreferences(defaults: defaults).quality, .dataSaver)
        XCTAssertFalse(AudioQuality.allCases.map(\.rawValue).contains("Lossless"))
    }
}
