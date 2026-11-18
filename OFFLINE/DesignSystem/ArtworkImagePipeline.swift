import Foundation
import ImageIO
import UIKit

/// The outcome of one managed-artwork load.
enum ArtworkLoadResult: Sendable {
    case image(UIImage)
    /// Neither the thumbnail nor the full-size file exists (or the path is not a managed path).
    case missing
    /// A file exists but ImageIO cannot decode it (corrupt or not an image).
    case undecodable
    /// Every requester went away before decoding finished.
    case cancelled

    var image: UIImage? { if case .image(let image) = self { return image }; return nil }
    /// A missing or corrupt file: the caller should stop offering this path.
    var isUnusable: Bool {
        switch self { case .missing, .undecodable: return true; case .image, .cancelled: return false }
    }
}

/// The one decoded-artwork cache of the app, shared by single covers and mosaic tiles.
///
/// - Reads only managed files under the Artwork directory, never the network.
/// - Decodes with ImageIO thumbnails on a background task, at a bounded pixel bucket chosen
///   from the rendered size, preferring the 256 px managed thumbnail for small requests.
/// - One `NSCache` with a 32 MiB cost budget (as before Phase 11.5) that also empties on a
///   memory warning: decoded artwork is reproducible and is discarded first.
/// - Simultaneous requests for the same image share one decode; a decode is cancelled when
///   every requester is cancelled. Missing and corrupt results are remembered briefly.
final class ArtworkImagePipeline: @unchecked Sendable {
    static let shared = ArtworkImagePipeline()
    static let memoryBudget = 32 * 1024 * 1024
    /// Pixel buckets. Near-identical sizes share one decoded image instead of many.
    static let buckets = [128, 256, 512, 768, 1024]
    /// Managed thumbnails are written at 256 px (`ManagedLibraryFiles.stageArtwork`, imports).
    static let thumbnailPixels = 256

    private struct Flight {
        let task: Task<ArtworkLoadResult, Never>
        var waiters: Int
    }
    private struct Failure {
        let result: ArtworkLoadResult
        let date: Date
    }

    private let cache = NSCache<NSString, UIImage>()
    private let lock = NSLock()
    private var flights: [String: Flight] = [:]
    private var failures: [String: Failure] = [:]
    private var generations: [String: Int] = [:]
    private var decodes = 0
    private var memoryWarning: NSObjectProtocol?
    let failureLifetime: TimeInterval
    let costLimit: Int

    init(costLimit: Int = ArtworkImagePipeline.memoryBudget, countLimit: Int = 300, failureLifetime: TimeInterval = 60) {
        self.costLimit = costLimit
        self.failureLifetime = failureLifetime
        cache.totalCostLimit = costLimit
        cache.countLimit = countLimit
        memoryWarning = NotificationCenter.default.addObserver(forName: UIApplication.didReceiveMemoryWarningNotification, object: nil, queue: nil) { [weak self] _ in
            self?.removeAll()
        }
    }
    deinit { if let memoryWarning { NotificationCenter.default.removeObserver(memoryWarning) } }

    /// The smallest bucket covering `points` at `scale`, capped at 1024 px.
    static func bucket(points: CGFloat, scale: CGFloat) -> Int {
        let pixels = (max(points, 1) * max(scale, 1)).rounded(.up)
        guard pixels.isFinite else { return buckets[0] }
        return buckets.first { CGFloat($0) >= pixels } ?? buckets[buckets.count - 1]
    }
    static func usesThumbnail(_ bucket: Int) -> Bool { bucket <= thumbnailPixels }

    /// Number of decodes performed (diagnostics and tests).
    var decodeCount: Int { lock.withLock { decodes } }

    private func key(_ path: String, _ bucket: Int) -> String {
        let generation = lock.withLock { generations[path] ?? 0 }
        return "\(generation)|\(bucket)|\(path)"
    }

    /// A synchronous cache hit, so already-decoded artwork is drawn on the first frame.
    func cached(path: String, bucket: Int) -> UIImage? { cache.object(forKey: key(path, bucket) as NSString) }

    func load(path: String, bucket: Int, paths: AppStoragePaths) async -> ArtworkLoadResult {
        let key = key(path, bucket)
        if let image = cache.object(forKey: key as NSString) { return .image(image) }
        let now = Date()
        let (task, settled): (Task<ArtworkLoadResult, Never>?, ArtworkLoadResult?) = lock.withLock {
            // Re-checked under the lock: a decode that just finished is never repeated.
            if let image = cache.object(forKey: key as NSString) { return (nil, .image(image)) }
            if let failure = failures[key] {
                if now.timeIntervalSince(failure.date) < failureLifetime { return (nil, failure.result) }
                failures[key] = nil
            }
            if var flight = flights[key] {
                flight.waiters += 1; flights[key] = flight
                return (flight.task, nil)
            }
            let task = Task.detached(priority: .userInitiated) { [weak self] () -> ArtworkLoadResult in
                guard let self else { return .cancelled }
                return self.decode(path: path, bucket: bucket, paths: paths, key: key)
            }
            flights[key] = Flight(task: task, waiters: 1)
            return (task, nil)
        }
        if let settled { return settled }
        guard let task else { return .cancelled }
        return await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            self.release(key, task: task)
        }
    }

    private func release(_ key: String, task: Task<ArtworkLoadResult, Never>) {
        let cancel: Bool = lock.withLock {
            guard var flight = flights[key] else { return false }
            flight.waiters -= 1
            if flight.waiters <= 0 { flights[key] = nil; return true }
            flights[key] = flight
            return false
        }
        if cancel { task.cancel() }
    }

    private func decode(path: String, bucket: Int, paths: AppStoragePaths, key: String) -> ArtworkLoadResult {
        defer { lock.withLock { _ = flights.removeValue(forKey: key) } }
        guard !Task.isCancelled else { return .cancelled }
        guard CollectionArtworkSelector.isSafeManagedPath(path) else { return remember(.missing, key: key) }
        var urls: [URL] = []
        if Self.usesThumbnail(bucket), let thumbnail = try? paths.artworkURL(relativePath: ManagedLibraryFiles.thumbnailName(path)) { urls.append(thumbnail) }
        if let original = try? paths.artworkURL(relativePath: path) { urls.append(original) }
        var foundFile = false
        for url in urls where FileManager.default.fileExists(atPath: url.path) {
            foundFile = true
            guard !Task.isCancelled else { return .cancelled }
            guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
                  let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                      kCGImageSourceCreateThumbnailFromImageAlways: true,
                      kCGImageSourceCreateThumbnailWithTransform: true,
                      kCGImageSourceShouldCacheImmediately: true,
                      kCGImageSourceThumbnailMaxPixelSize: bucket,
                  ] as CFDictionary) else { continue }
            let decoded = UIImage(cgImage: image)
            lock.withLock {
                cache.setObject(decoded, forKey: key as NSString, cost: max(1, image.bytesPerRow * image.height))
                decodes += 1
            }
            return .image(decoded)
        }
        return remember(foundFile ? .undecodable : .missing, key: key)
    }

    private func remember(_ result: ArtworkLoadResult, key: String) -> ArtworkLoadResult {
        lock.withLock { failures[key] = Failure(result: result, date: Date()) }
        return result
    }

    /// Artwork replaced or removed: later requests can never see the previous decode.
    func invalidate<S: Sequence>(_ paths: S) where S.Element == String {
        for path in paths {
            let previous: Int = lock.withLock {
                let value = generations[path] ?? 0
                generations[path] = value + 1
                for bucket in Self.buckets { failures["\(value)|\(bucket)|\(path)"] = nil }
                return value
            }
            for bucket in Self.buckets { cache.removeObject(forKey: "\(previous)|\(bucket)|\(path)" as NSString) }
        }
    }

    /// Memory pressure: discard every reproducible decoded image and remembered failure.
    func removeAll() {
        cache.removeAllObjects()
        lock.withLock { failures.removeAll() }
    }
}
