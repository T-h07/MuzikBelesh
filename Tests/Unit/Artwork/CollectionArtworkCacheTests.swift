import Foundation
import UIKit
import XCTest
@testable import OFFLINE

/// Phase 11.5 shared artwork pipeline: bounded sizes and memory, shared decodes, safe
/// failures and invalidation. Uses its own pipeline instance and storage root.
final class CollectionArtworkCacheTests: XCTestCase {
    private var root: URL!
    private var paths: AppStoragePaths!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("ArtworkCache-\(UUID().uuidString)", isDirectory: true)
        paths = try AppStoragePaths(root: root)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    func testPixelBucketsFollowTheRenderedTileSize() {
        XCTAssertEqual(ArtworkImagePipeline.bucket(points: 30, scale: 3), 128, "A 60 pt row mosaic tile")
        XCTAssertEqual(ArtworkImagePipeline.bucket(points: 60, scale: 3), 256, "A 60 pt single cover")
        XCTAssertEqual(ArtworkImagePipeline.bucket(points: 110, scale: 3), 512, "A 220 pt header mosaic tile")
        XCTAssertEqual(ArtworkImagePipeline.bucket(points: 220, scale: 3), 768, "A 220 pt single cover")
        XCTAssertEqual(ArtworkImagePipeline.bucket(points: 900, scale: 3), 1024, "Never above 1024 px")
        XCTAssertEqual(ArtworkImagePipeline.bucket(points: 0, scale: 0), 128)
        XCTAssertTrue(ArtworkImagePipeline.usesThumbnail(256))
        XCTAssertFalse(ArtworkImagePipeline.usesThumbnail(512))
    }

    func testDecodedImagesAreBoundedByTheRequestedBucket() async throws {
        try ArtworkTestFiles.write("large.jpg", paths: paths, side: 2048)
        let pipeline = ArtworkImagePipeline()
        for bucket in [128, 512] {
            let loaded = await pipeline.load(path: "large.jpg", bucket: bucket, paths: paths)
            let image = try XCTUnwrap(loaded.image)
            let cgImage = try XCTUnwrap(image.cgImage)
            XCTAssertLessThanOrEqual(max(cgImage.width, cgImage.height), bucket)
        }
    }

    func testSmallTilesUseTheManagedThumbnail() async throws {
        try ArtworkTestFiles.write("thumb-only.jpg", paths: paths, thumbnail: true, original: false)
        let pipeline = ArtworkImagePipeline()
        let small = await pipeline.load(path: "thumb-only.jpg", bucket: 128, paths: paths)
        XCTAssertNotNil(small.image, "Missing full-size artwork: the thumbnail still serves small tiles")
        guard case .missing = await pipeline.load(path: "thumb-only.jpg", bucket: 768, paths: paths) else { return XCTFail("Large requests never upscale a thumbnail") }
        try ArtworkTestFiles.write("original-only.jpg", paths: paths, thumbnail: false, original: true)
        let fallback = await pipeline.load(path: "original-only.jpg", bucket: 128, paths: paths)
        XCTAssertNotNil(fallback.image, "A missing thumbnail falls back to the original")
    }

    func testSimultaneousRequestsShareOneDecodeAndTheCache() async throws {
        try ArtworkTestFiles.write("shared.jpg", paths: paths)
        let pipeline = ArtworkImagePipeline()
        let paths = paths!
        let results = await withTaskGroup(of: Bool.self) { group -> [Bool] in
            for _ in 0..<8 { group.addTask { await pipeline.load(path: "shared.jpg", bucket: 256, paths: paths).image != nil } }
            var collected: [Bool] = []
            for await result in group { collected.append(result) }
            return collected
        }
        XCTAssertEqual(results, Array(repeating: true, count: 8))
        XCTAssertEqual(pipeline.decodeCount, 1, "Tiles sharing a source image reuse one decode")
        XCTAssertNotNil(pipeline.cached(path: "shared.jpg", bucket: 256))
        _ = await pipeline.load(path: "shared.jpg", bucket: 256, paths: paths)
        XCTAssertEqual(pipeline.decodeCount, 1)
    }

    func testMissingCorruptAndUnsafePathsFailSafely() async throws {
        let pipeline = ArtworkImagePipeline()
        guard case .missing = await pipeline.load(path: "absent.jpg", bucket: 256, paths: paths) else { return XCTFail("Missing file") }
        try Data("not an image".utf8).write(to: paths.artworkURL(relativePath: "corrupt.jpg"))
        guard case .undecodable = await pipeline.load(path: "corrupt.jpg", bucket: 512, paths: paths) else { return XCTFail("Corrupt JPEG") }
        for unsafe in ["../escape.jpg", "/etc/passwd", "nested/x.jpg"] {
            guard case .missing = await pipeline.load(path: unsafe, bucket: 256, paths: paths) else { return XCTFail("Unsafe path \(unsafe)") }
        }
        XCTAssertEqual(pipeline.decodeCount, 0)
        XCTAssertTrue(ArtworkLoadResult.missing.isUnusable)
        XCTAssertTrue(ArtworkLoadResult.undecodable.isUnusable)
        XCTAssertFalse(ArtworkLoadResult.cancelled.isUnusable)
    }

    func testFailuresAreRememberedUntilInvalidated() async throws {
        let pipeline = ArtworkImagePipeline(failureLifetime: 3600)
        guard case .missing = await pipeline.load(path: "late.jpg", bucket: 256, paths: paths) else { return XCTFail("Missing first") }
        try ArtworkTestFiles.write("late.jpg", paths: paths)
        guard case .missing = await pipeline.load(path: "late.jpg", bucket: 256, paths: paths) else { return XCTFail("No repeated file checks while remembered") }
        pipeline.invalidate(["late.jpg"])
        let retried = await pipeline.load(path: "late.jpg", bucket: 256, paths: paths)
        XCTAssertNotNil(retried.image, "Invalidation (artwork added or replaced) retries")
    }

    func testInvalidationNeverShowsAStaleImage() async throws {
        try ArtworkTestFiles.write("replaced.jpg", paths: paths)
        let pipeline = ArtworkImagePipeline()
        let first = await pipeline.load(path: "replaced.jpg", bucket: 256, paths: paths)
        XCTAssertNotNil(first.image)
        XCTAssertNotNil(pipeline.cached(path: "replaced.jpg", bucket: 256))
        pipeline.invalidate(["replaced.jpg"])
        XCTAssertNil(pipeline.cached(path: "replaced.jpg", bucket: 256))
        XCTAssertNil(pipeline.cached(path: "other.jpg", bucket: 256), "A new path never shows a previous path's image")
        try FileManager.default.removeItem(at: paths.artworkURL(relativePath: "replaced.jpg"))
        try FileManager.default.removeItem(at: paths.artworkURL(relativePath: ManagedLibraryFiles.thumbnailName("replaced.jpg")))
        guard case .missing = await pipeline.load(path: "replaced.jpg", bucket: 256, paths: paths) else { return XCTFail("Deleted artwork is not served from memory") }
    }

    func testMemoryIsBoundedAndReleasedUnderPressure() async throws {
        XCTAssertEqual(ArtworkImagePipeline.memoryBudget, 32 * 1024 * 1024)
        XCTAssertEqual(ArtworkImagePipeline.shared.costLimit, ArtworkImagePipeline.memoryBudget, "One shared, bounded cache")
        try ArtworkTestFiles.write("pressure.jpg", paths: paths)
        let pipeline = ArtworkImagePipeline(costLimit: 1024 * 1024)
        XCTAssertEqual(pipeline.costLimit, 1024 * 1024)
        let loaded = await pipeline.load(path: "pressure.jpg", bucket: 256, paths: paths)
        XCTAssertNotNil(loaded.image)
        NotificationCenter.default.post(name: UIApplication.didReceiveMemoryWarningNotification, object: nil)
        XCTAssertNil(pipeline.cached(path: "pressure.jpg", bucket: 256), "Reproducible artwork is discarded first")
    }

    func testCancellingTheOnlyRequesterCancelsItsDecode() async throws {
        try ArtworkTestFiles.write("cancel.jpg", paths: paths)
        let pipeline = ArtworkImagePipeline()
        let paths = paths!
        let task = Task { await pipeline.load(path: "cancel.jpg", bucket: 512, paths: paths) }
        task.cancel()
        let result = await task.value
        switch result {
        case .cancelled, .image: break // Either cancelled in time, or already decoded.
        case .missing, .undecodable: XCTFail("Cancellation is never reported as an unusable file")
        }
    }
}
