import Foundation
import GRDB

final class DatabaseManager {
    let dbQueue: DatabaseQueue

    init(url: URL) throws {
        dbQueue = try DatabaseQueue(path: url.path)
        try dbQueue.write { db in
            try db.execute(sql: "PRAGMA foreign_keys = ON")
        }
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v001_initial_library") { db in
            try db.create(table: "artists") { t in
                t.column("id", .text).primaryKey(); t.column("name", .text).notNull(); t.column("normalizedName", .text).notNull(); t.column("artworkRelativePath", .text); t.column("dateAdded", .datetime).notNull(); t.column("dateModified", .datetime).notNull()
            }
            try db.create(table: "albums") { t in
                t.column("id", .text).primaryKey(); t.column("title", .text).notNull(); t.column("normalizedTitle", .text).notNull(); t.column("artistID", .text).references("artists", onDelete: .setNull); t.column("artworkRelativePath", .text); t.column("dateAdded", .datetime).notNull(); t.column("dateModified", .datetime).notNull()
            }
            try db.create(table: "tracks") { t in
                t.column("id", .text).primaryKey(); t.column("title", .text).notNull(); t.column("artistID", .text).references("artists", onDelete: .setNull); t.column("albumID", .text).references("albums", onDelete: .setNull); t.column("durationMs", .integer); t.column("fileRelativePath", .text).notNull(); t.column("fileExtension", .text).notNull(); t.column("fileSizeBytes", .integer).notNull(); t.column("contentSHA256", .text).notNull(); t.column("artworkRelativePath", .text); t.column("availability", .text).notNull(); t.column("dateAdded", .datetime).notNull(); t.column("dateModified", .datetime).notNull(); t.column("originalFilename", .text); t.column("metadataSource", .text).notNull()
            }
            try db.create(index: "tracks_contentSHA256", on: "tracks", columns: ["contentSHA256"], options: .unique)
            try db.create(index: "tracks_availability", on: "tracks", columns: ["availability"])
        }
        migrator.registerMigration("v002_playlists_and_likes") { db in
            try db.create(table: "playlists") { t in
                t.column("id", .text).primaryKey(); t.column("name", .text).notNull(); t.column("description", .text); t.column("artworkRelativePath", .text); t.column("dateAdded", .datetime).notNull(); t.column("dateModified", .datetime).notNull()
            }
            try db.create(table: "playlist_tracks") { t in
                t.column("playlistID", .text).notNull().references("playlists", onDelete: .cascade); t.column("trackID", .text).notNull().references("tracks", onDelete: .cascade); t.column("position", .integer).notNull(); t.column("dateAdded", .datetime).notNull(); t.primaryKey(["playlistID", "trackID"])
            }
            try db.create(table: "liked_tracks") { t in
                t.column("trackID", .text).primaryKey().references("tracks", onDelete: .cascade); t.column("dateLiked", .datetime).notNull()
            }
            try db.create(index: "playlist_tracks_position", on: "playlist_tracks", columns: ["playlistID", "position"])
        }
        migrator.registerMigration("v003_playback_and_history") { db in
            try db.create(table: "playback_state") { t in
                t.column("scope", .text).primaryKey(); t.column("currentTrackID", .text).references("tracks", onDelete: .setNull); t.column("positionMs", .integer).notNull(); t.column("shuffleEnabled", .boolean).notNull(); t.column("repeatMode", .text).notNull(); t.column("dateModified", .datetime).notNull()
            }
            try db.create(table: "playback_queue_entries") { t in
                t.column("id", .text).primaryKey(); t.column("trackID", .text).notNull().references("tracks", onDelete: .cascade); t.column("position", .integer).notNull(); t.column("dateAdded", .datetime).notNull()
            }
            try db.create(table: "playback_history") { t in
                t.column("id", .text).primaryKey(); t.column("trackID", .text).notNull().references("tracks", onDelete: .cascade); t.column("startedAt", .datetime).notNull(); t.column("completedAt", .datetime); t.column("durationListenedMs", .integer); t.column("source", .text)
            }
            try db.create(index: "playback_history_startedAt", on: "playback_history", columns: ["startedAt"])
        }
        migrator.registerMigration("v004_download_jobs") { db in
            try db.create(table: "download_jobs") { t in
                t.column("id", .text).primaryKey(); t.column("sourceType", .text).notNull(); t.column("sourceIdentifier", .text); t.column("trackID", .text).references("tracks", onDelete: .setNull); t.column("state", .text).notNull(); t.column("progress", .double).notNull(); t.column("errorMessage", .text); t.column("quality", .text).notNull(); t.column("dateAdded", .datetime).notNull(); t.column("dateModified", .datetime).notNull()
            }
            try db.create(index: "download_jobs_state", on: "download_jobs", columns: ["state"])
        }
        migrator.registerMigration("v005_settings_sources_imports") { db in
            try db.create(table: "settings") { t in
                t.column("key", .text).primaryKey(); t.column("value", .text).notNull(); t.column("valueType", .text).notNull(); t.column("dateModified", .datetime).notNull()
            }
            try db.create(table: "track_sources") { t in
                t.column("id", .text).primaryKey(); t.column("trackID", .text).notNull().references("tracks", onDelete: .cascade); t.column("sourceType", .text).notNull(); t.column("sourceIdentifier", .text); t.column("canonicalURL", .text); t.column("dateRecorded", .datetime).notNull()
            }
            try db.create(table: "import_operations") { t in
                t.column("id", .text).primaryKey(); t.column("sourceFilename", .text).notNull(); t.column("stagingRelativePath", .text).notNull(); t.column("state", .text).notNull(); t.column("errorMessage", .text); t.column("dateStarted", .datetime).notNull(); t.column("dateUpdated", .datetime).notNull()
            }
            try db.create(index: "track_sources_lookup", on: "track_sources", columns: ["sourceType", "sourceIdentifier"])
        }
        migrator.registerMigration("v006_phase4_playback_state") { db in
            try db.alter(table: "playback_state") { t in
                t.add(column: "contextTrackIDsJSON", .text)
                t.add(column: "shuffleOrderJSON", .text)
                t.add(column: "shufflePosition", .integer)
                t.add(column: "sleepTimerDeadlineMs", .integer)
            }
            try db.alter(table: "playback_queue_entries") { t in
                t.add(column: "origin", .text).notNull().defaults(to: "addToQueue")
            }
        }
        migrator.registerMigration("v007_sleep_timer_duration") { db in
            try db.alter(table: "playback_state") { t in t.add(column: "sleepTimerDurationMs", .integer) }
        }
        try migrator.migrate(dbQueue)
    }

    static func live(paths: AppStoragePaths) throws -> DatabaseManager { try DatabaseManager(url: paths.database) }
    static func isolated(at url: URL) throws -> DatabaseManager { try DatabaseManager(url: url) }
}
