import Foundation
import GRDB

enum StoredTrackAvailability: String, Codable, DatabaseValueConvertible { case available, missing, modified }
enum StoredDownloadState: String, Codable, DatabaseValueConvertible { case queued, interrupted, completed, cancelled, failed }

struct StoredArtist: Codable, FetchableRecord, PersistableRecord, Identifiable, Equatable {
    static let databaseTableName = "artists"
    var id: String
    var name: String
    var normalizedName: String
    var artworkRelativePath: String?
    var dateAdded: Date
    var dateModified: Date
}

struct StoredAlbum: Codable, FetchableRecord, PersistableRecord, Identifiable, Equatable {
    static let databaseTableName = "albums"
    var id: String
    var title: String
    var normalizedTitle: String
    var artistID: String?
    var artworkRelativePath: String?
    var dateAdded: Date
    var dateModified: Date
}

struct StoredTrack: Codable, FetchableRecord, PersistableRecord, Identifiable, Equatable {
    static let databaseTableName = "tracks"
    var id: String
    var title: String
    var artistID: String?
    var albumID: String?
    var durationMs: Int64?
    var fileRelativePath: String
    var fileExtension: String
    var fileSizeBytes: Int64
    var contentSHA256: String
    var artworkRelativePath: String?
    var availability: StoredTrackAvailability
    var dateAdded: Date
    var dateModified: Date
    var originalFilename: String?
    var metadataSource: String
}

struct StoredPlaylist: Codable, FetchableRecord, PersistableRecord, Identifiable, Equatable {
    static let databaseTableName = "playlists"
    var id: String
    var name: String
    var description: String?
    var artworkRelativePath: String?
    var dateAdded: Date
    var dateModified: Date
}

struct StoredLikedTrack: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "liked_tracks"
    var trackID: String
    var dateLiked: Date
}

struct StoredPlaybackState: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "playback_state"
    var scope: String
    var currentTrackID: String?
    var positionMs: Int64
    var shuffleEnabled: Bool
    var repeatMode: String
    var contextTrackIDsJSON: String? = nil
    var shuffleOrderJSON: String? = nil
    var shufflePosition: Int? = nil
    var sleepTimerDeadlineMs: Int64? = nil
    var sleepTimerDurationMs: Int64? = nil
    var dateModified: Date
}

struct StoredQueueEntry: Codable, FetchableRecord, PersistableRecord, Identifiable {
    static let databaseTableName = "playback_queue_entries"
    var id: String
    var trackID: String
    var position: Int
    var dateAdded: Date
    var origin: String = "addToQueue"
}

struct StoredHistoryEntry: Codable, FetchableRecord, PersistableRecord, Identifiable {
    static let databaseTableName = "playback_history"
    var id: String
    var trackID: String
    var startedAt: Date
    var completedAt: Date?
    var durationListenedMs: Int64?
    var source: String?
}

struct StoredDownloadJob: Codable, FetchableRecord, PersistableRecord, Identifiable {
    static let databaseTableName = "download_jobs"
    var id: String
    var sourceType: String
    var sourceIdentifier: String?
    var trackID: String?
    var state: StoredDownloadState
    var progress: Double
    var errorMessage: String?
    var quality: String
    var dateAdded: Date
    var dateModified: Date
}

struct StoredSetting: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "settings"
    var key: String
    var value: String
    var valueType: String
    var dateModified: Date
}

struct StoredTrackSource: Codable, FetchableRecord, PersistableRecord, Identifiable {
    static let databaseTableName = "track_sources"
    var id: String
    var trackID: String
    var sourceType: String
    var sourceIdentifier: String?
    var canonicalURL: String?
    var dateRecorded: Date
}

struct StoredImportOperation: Codable, FetchableRecord, PersistableRecord, Identifiable {
    static let databaseTableName = "import_operations"
    var id: String
    var sourceFilename: String
    var stagingRelativePath: String
    var state: String
    var errorMessage: String?
    var dateStarted: Date
    var dateUpdated: Date
}
