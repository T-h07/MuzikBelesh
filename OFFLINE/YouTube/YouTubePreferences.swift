import Foundation
import Combine
import GRDB

@MainActor final class YouTubePreferences: ObservableObject {
    private let defaults: UserDefaults
    private let key = "youtube.audioQuality"
    @Published var quality: AudioQuality { didSet { defaults.set(quality.rawValue, forKey: key) } }
    @Published var wifiOnly: Bool { didSet { defaults.set(wifiOnly, forKey: "downloads.wifiOnly") } }
    @Published var simultaneous: Int { didSet { defaults.set(simultaneous, forKey: "downloads.simultaneous") } }
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        wifiOnly = (defaults.object(forKey: "downloads.wifiOnly") as? Bool) ?? true
        let limit = defaults.integer(forKey: "downloads.simultaneous")
        simultaneous = (1...3).contains(limit) ? limit : 2
        switch defaults.string(forKey: key) {
        case "High": quality = .high
        case "Standard": quality = .standard
        case let value: quality = value.flatMap(AudioQuality.init(rawValue:)) ?? .standard
        }
        defaults.set(quality.rawValue, forKey: key)
    }
}

enum YouTubeLibraryStatus: Equatable, Sendable { case notDownloaded, downloaded(trackID: String), fileUnavailable, unknown }
protocol YouTubeLibraryChecking: Sendable { func status(videoID: String) async throws -> YouTubeLibraryStatus }

struct YouTubeLibraryLookup: YouTubeLibraryChecking, @unchecked Sendable {
    let database: DatabaseQueue?
    let paths: AppStoragePaths?
    func status(videoID: String) async throws -> YouTubeLibraryStatus {
        guard let database, let paths else { return .unknown }
        let track = try await database.read { db in try LibraryRepository.sourceTrack(type: "youtube", identifier: videoID, db: db) }
        guard let track else { return .notDownloaded }
        guard track.availability == .available, let url = try? paths.musicURL(relativePath: track.fileRelativePath), FileManager.default.fileExists(atPath: url.path) else { return .fileUnavailable }
        guard (try? AudioFileService().sha256(url: url)) == track.contentSHA256 else { return .fileUnavailable }
        return .downloaded(trackID: track.id)
    }
}

actor CachedYouTubeMetadataProvider: YouTubeMetadataProvider {
    private let provider: any YouTubeMetadataProvider
    private var cache: [String: (YouTubeVideo, Date)] = [:]
    init(provider: any YouTubeMetadataProvider) { self.provider = provider }
    func metadata(videoID: String) async throws -> YouTubeVideo {
        try Task.checkCancellation()
        let now = Date()
        cache = cache.filter { $0.value.1 > now }
        if let hit = cache[videoID] { return hit.0 }
        let video = try await provider.metadata(videoID: videoID)
        try Task.checkCancellation()
        if cache.count >= 20, let key = cache.min(by: { $0.value.1 < $1.value.1 })?.key { cache.removeValue(forKey: key) }
        cache[videoID] = (video, Date().addingTimeInterval(30))
        return video
    }
}
