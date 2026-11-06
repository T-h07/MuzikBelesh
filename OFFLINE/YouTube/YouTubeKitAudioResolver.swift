import Foundation
import YouTubeKit

enum AudioStreamSelector {
    static func select(_ options: [AudioStreamOption], quality: AudioQuality) throws -> AudioStreamOption {
        let audio = options.filter(\.isAudioOnly)
        guard !audio.isEmpty else { throw YouTubeError.noAudioStreams }
        let compatible = audio.filter { $0.isCompatible && ($0.bitrate == nil || ($0.bitrate ?? 0) > 0) }
        guard !compatible.isEmpty else { throw YouTubeError.noCompatibleAudio }
        let preferred = compatible.filter(\.isPreferred)
        let pool = preferred.isEmpty ? compatible : preferred
        // Unknown rates are a final fallback, never represented as high quality.
        let known = pool.filter { $0.bitrate != nil }
        let ordered = (known.isEmpty ? pool : known).sorted {
            if $0.bitrate == $1.bitrate { return $0.id < $1.id }
            return ($0.bitrate ?? 0) < ($1.bitrate ?? 0)
        }
        guard let low = ordered.first, let high = ordered.last else { throw YouTubeError.noCompatibleAudio }
        switch quality {
        case .dataSaver: return low
        case .high: return high
        case .standard: return ordered.min { abs(($0.bitrate ?? 0) - 128_000) < abs(($1.bitrate ?? 0) - 128_000) } ?? low
        }
    }
}

struct YouTubeStreamReadiness: Sendable {
    let transport: any YouTubeTransport
    let delay: @Sendable () async throws -> Void
    init(transport: any YouTubeTransport, delay: @escaping @Sendable () async throws -> Void = { try await Task.sleep(for: .seconds(2)) }) { self.transport = transport; self.delay = delay }
    func verify(_ url: URL, now: Date = Date()) async throws -> Date? {
        guard url.scheme == "https", let host = url.host, host.hasSuffix(".googlevideo.com"), YouTubeURLSessionTransport.permitted(url) else { throw YouTubeError.extractionFailed }
        let expiryValue = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "expire" })?.value
        let expiry: Date?
        if let expiryValue {
            guard let seconds = TimeInterval(expiryValue), seconds.isFinite else { throw YouTubeError.extractionFailed }
            expiry = Date(timeIntervalSince1970: seconds)
        } else { expiry = nil }
        if let expiry, expiry.timeIntervalSince(now) <= 30 { throw YouTubeError.streamExpired }
        for attempt in 0..<3 {
            try Task.checkCancellation()
            var request = URLRequest(url: url); request.httpMethod = "HEAD"
            let response = try await transport.send(request)
            if (200..<300).contains(response.status) {
                guard let type = response.contentType?.lowercased(), type.hasPrefix("audio/") || type.hasPrefix("video/mp4") || type.hasPrefix("application/octet-stream") else { throw YouTubeError.extractionFailed }
                return expiry
            }
            if [403, 503].contains(response.status), attempt < 2 { try await delay(); continue }
            if response.status == 403 { throw YouTubeError.streamExpired }
            if response.status == 503 { throw YouTubeError.streamNotReady }
            try YouTubeHTTP.successful(response, fallback: .streamNotReady)
        }
        throw YouTubeError.streamNotReady
    }
}

// One shared instance serializes access to YouTubeKit's process-wide JS cache.
// Waiting callers are cancellable and never execute extraction on MainActor.
actor YouTubeKitAudioResolver: YouTubeAudioResolver {
    static var extractionMethods: [YouTube.ExtractionMethod] { [.local] }
    private let metadata: any YouTubeMetadataProvider
    private let readiness: YouTubeStreamReadiness
    private var pending: Task<ResolvedAudioStream, Error>?
    private var pendingID: UUID?
    init(metadata: any YouTubeMetadataProvider, transport: any YouTubeTransport) {
        self.metadata = metadata; self.readiness = YouTubeStreamReadiness(transport: transport)
    }
    func resolve(video: YouTubeVideo, quality: AudioQuality) async throws -> ResolvedAudioStream {
        let previous = pending, id = UUID(), metadata = metadata, readiness = readiness
        let task = Task {
            if let previous { _ = await previous.result }
            try Task.checkCancellation()
            return try await Self.extract(videoID: video.id, quality: quality, metadata: metadata, readiness: readiness)
        }
        pending = task; pendingID = id
        defer { if pendingID == id { pending = nil; pendingID = nil } }
        return try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
    }
    private nonisolated static func extract(videoID: String, quality: AudioQuality, metadata: any YouTubeMetadataProvider, readiness: YouTubeStreamReadiness) async throws -> ResolvedAudioStream {
        do {
            return try await withThrowingTaskGroup(of: ResolvedAudioStream.self) { group in
                group.addTask {
                    // Check the ordinary anonymous watch response before calling the extractor.
                    let authorized = try await metadata.metadata(videoID: videoID)
                    guard authorized.availability == .available else { throw YouTubeError.streamNotReady }
                    let youtube = YouTube(videoID: videoID, methods: extractionMethods)
                    let ageRestricted = try await youtube.ageRestricted
                    guard !ageRestricted else { throw YouTubeError.accessRestricted }
                    try Task.checkCancellation()
                    let streams = try await youtube.streams
                    try Task.checkCancellation()
                    let options = streams.enumerated().map { option($0.element, id: $0.offset) }
                    let selected = try AudioStreamSelector.select(options, quality: quality)
                    guard streams.indices.contains(selected.id) else { throw YouTubeError.extractionFailed }
                    let stream = streams[selected.id]
                    // 0.4.10 has no waitUntilAvailable API: bounded HEAD only, no media bytes.
                    let expiry = try await readiness.verify(stream.url)
                    let extracted = try await youtube.metadata
                    try Task.checkCancellation()
                    return ResolvedAudioStream(video: authorized.merging(title: extracted?.title, thumbnail: extracted?.thumbnail?.url), options: options.filter(\.isAudioOnly), selected: selected, url: stream.url, resolvedAt: Date(), expiresAt: expiry)
                }
                group.addTask { try await Task.sleep(for: .seconds(45)); throw YouTubeError.requestTimeout }
                defer { group.cancelAll() }
                guard let result = try await group.next() else { throw YouTubeError.extractionFailed }
                return result
            }
        } catch let error as YouTubeKitError {
            switch error {
            case .videoPrivate, .videoUnavailable, .recordingUnavailable: throw YouTubeError.videoUnavailable
            case .videoAgeRestricted, .membersOnly: throw YouTubeError.accessRestricted
            case .videoRegionBlocked: throw YouTubeError.regionRestricted
            case .liveStreamError: throw YouTubeError.noAudioStreams
            default: throw YouTubeError.extractionFailed
            }
        } catch { throw YouTubeError.map(error, fallback: .extractionFailed) }
    }
    nonisolated static func option(_ stream: YouTubeKit.Stream, id: Int) -> AudioStreamOption {
        let codec: String?
        switch stream.audioCodec {
        case .mp4a(let version): codec = "mp4a.\(version)"
        case .ac3: codec = "ac-3"
        case .ec3: codec = "ec-3"
        case .opus: codec = "opus"
        case .unknown, .none: codec = nil
        }
        return AudioStreamOption(id: id, container: stream.fileExtension.rawValue, codec: codec,
                                 bitrate: stream.averageBitrate ?? stream.bitrate, isAudioOnly: stream.includesAudioTrack && !stream.includesVideoTrack,
                                 isNativelyPlayable: stream.isNativelyPlayable)
    }
}
