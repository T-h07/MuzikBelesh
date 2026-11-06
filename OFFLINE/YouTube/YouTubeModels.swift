import Foundation

struct YouTubeVideo: Identifiable, Hashable, Sendable {
    enum Availability: String, Hashable, Sendable { case unknown, available, live, upcoming, unavailable }
    let id: String
    var title: String
    var channel: String?
    var channelID: String?
    var thumbnailURL: URL?
    var duration: TimeInterval?
    var availability: Availability = .unknown
    var isShort: Bool = false
    var canonicalURL: URL? { URL(string: "https://www.youtube.com/watch?v=\(id)") }
    var durationLabel: String {
        guard let duration, duration.isFinite, duration >= 0, duration < 10_000_000 else { return availability == .live ? "Live" : "Duration unavailable" }
        let seconds = Int(duration)
        return seconds >= 3600 ? String(format: "%d:%02d:%02d", seconds / 3600, seconds / 60 % 60, seconds % 60) : String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
    // Extractor values win only when present; retain useful search/watch metadata.
    func merging(title: String?, thumbnail: URL?) -> Self {
        var result = self
        if let title, !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { result.title = title }
        if let thumbnail = YouTubeImageURL.valid(thumbnail) { result.thumbnailURL = thumbnail }
        return result
    }
}

struct YouTubeSearchPage: Equatable, Sendable {
    let videos: [YouTubeVideo]
    let continuationToken: String?
}

enum AudioQuality: String, CaseIterable, Sendable { case dataSaver = "Data Saver", standard = "Balanced", high = "Best Available" }

struct AudioStreamOption: Equatable, Sendable, Identifiable {
    // Identity is scoped to one extraction; upstream 0.4.10 does not expose raw itags.
    let id: Int
    let container: String
    let codec: String?
    let bitrate: Int?
    let isAudioOnly: Bool
    let isNativelyPlayable: Bool
    var isCompatible: Bool {
        guard isAudioOnly, isNativelyPlayable, let codec else { return false }
        return ["m4a", "mp4"].contains(container) && (codec.hasPrefix("mp4a.") || ["ac-3", "ec-3"].contains(codec))
    }
    var isPreferred: Bool { container == "m4a" && codec?.hasPrefix("mp4a.") == true }
}

struct ResolvedAudioStream: Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    let video: YouTubeVideo
    let options: [AudioStreamOption]
    let selected: AudioStreamOption
    let url: URL
    let resolvedAt: Date
    let expiresAt: Date?
    var description: String { "Resolved audio: \(video.id), \(selected.container) (URL redacted)" }
    var debugDescription: String { description }
    func isFresh(at date: Date) -> Bool { date.timeIntervalSince(resolvedAt) < 60 && (expiresAt.map { $0.timeIntervalSince(date) > 30 } ?? true) }
}

// Deliberately not Codable. Signed URLs remain in memory and are never download_jobs data.
struct PreparedYouTubeDownload: Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    let videoID: String
    let metadata: YouTubeVideo
    let quality: AudioQuality
    let stream: ResolvedAudioStream
    var description: String { "Prepared YouTube audio: \(videoID), \(quality.rawValue) (URL redacted)" }
    var debugDescription: String { description }
}

protocol YouTubeSearchProvider: Sendable {
    func search(query: String, continuationToken: String?) async throws -> YouTubeSearchPage
}
protocol YouTubeMetadataProvider: Sendable {
    func metadata(videoID: String) async throws -> YouTubeVideo
}
protocol YouTubeAudioResolver: Sendable {
    func resolve(video: YouTubeVideo, quality: AudioQuality) async throws -> ResolvedAudioStream
}
protocol YouTubeDownloadPreparing: Sendable {
    func prepare(video: YouTubeVideo, quality: AudioQuality) async throws -> PreparedYouTubeDownload
}
struct YouTubeDownloadPreparer: YouTubeDownloadPreparing {
    let resolver: any YouTubeAudioResolver
    func prepare(video: YouTubeVideo, quality: AudioQuality) async throws -> PreparedYouTubeDownload {
        let stream = try await resolver.resolve(video: video, quality: quality)
        try Task.checkCancellation()
        guard stream.video.id == video.id, stream.selected.isCompatible else { throw YouTubeError.extractionFailed }
        guard stream.isFresh(at: Date()) else { throw YouTubeError.streamExpired }
        return PreparedYouTubeDownload(videoID: video.id, metadata: stream.video, quality: quality, stream: stream)
    }
}

enum YouTubeError: String, Error, LocalizedError, Equatable, Sendable {
    case invalidURL, invalidVideoID, networkUnavailable, requestTimeout, rateLimited, searchUnavailable
    case metadataUnavailable, videoUnavailable, regionRestricted, accessRestricted, noAudioStreams
    case noCompatibleAudio, streamNotReady, streamExpired, extractionFailed, cancelled
    var errorDescription: String? {
        switch self {
        case .invalidURL: "Enter a supported HTTPS YouTube video link."
        case .invalidVideoID: "A YouTube video ID must contain 11 letters, digits, hyphens or underscores."
        case .networkUnavailable: "YouTube requires an internet connection. Check your connection and retry."
        case .requestTimeout: "YouTube took too long to respond. Try again."
        case .rateLimited: "YouTube is limiting requests. Wait a little before trying again."
        case .searchUnavailable: "YouTube search is temporarily unavailable. Try again or paste a video link."
        case .metadataUnavailable: "Video details could not be read. Try again."
        case .videoUnavailable: "This video is unavailable, private or removed."
        case .regionRestricted: "This video is unavailable in your region."
        case .accessRestricted: "This video requires access or verification that this app cannot provide."
        case .noAudioStreams: "No audio-only streams were found for this video."
        case .noCompatibleAudio: "No iPhone-compatible audio stream was found."
        case .streamNotReady: "The audio stream is not ready. Try again shortly."
        case .streamExpired: "The temporary audio link expired or was rejected. Resolve it again."
        case .extractionFailed: "Audio could not be resolved locally. YouTube compatibility may have changed."
        case .cancelled: ""
        }
    }
    var canRetry: Bool { [.networkUnavailable, .requestTimeout, .rateLimited, .searchUnavailable, .metadataUnavailable, .streamNotReady, .streamExpired, .extractionFailed].contains(self) }
    static func map(_ error: Error, fallback: Self) -> Self {
        if error is CancellationError { return .cancelled }
        if let error = error as? Self { return error }
        if let error = error as? URLError {
            switch error.code {
            case .cancelled: return .cancelled
            case .timedOut: return .requestTimeout
            case .notConnectedToInternet, .networkConnectionLost, .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed: return .networkUnavailable
            default: break
            }
        }
        return fallback
    }
}

enum YouTubeImageURL {
    static func valid(_ url: URL?) -> URL? {
        guard let url, url.scheme == "https", url.user == nil, url.password == nil,
              let host = url.host?.lowercased(), host == "i.ytimg.com" || host == "img.youtube.com" || host == "i9.ytimg.com" else { return nil }
        return url
    }
}
