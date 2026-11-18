import Foundation
import GRDB

/// Phase 11.2 append-only analytics schema. Registered after `v024_local_user_profile`;
/// `v023` stays reserved for the canceled Phase 10.8 build.
///
/// - `listening_sessions`: one row per playback that actually produced audio. A row is never
///   created for a selection that never played. `trackID` is `ON DELETE SET NULL`, so deleting
///   a song keeps its listening time in totals but removes it from rankings.
/// - `listening_session_days`: the credited milliseconds of each session per local calendar day,
///   so a session that crosses midnight is split between both days.
/// - `listening_analytics_state`: the single row holding when accurate tracking began.
///
/// Legacy `playback_history` is not read, migrated or changed: its durations are not reliable.
enum ListeningAnalyticsSchema {
    static let version = "v025_listening_analytics"

    static func register(in migrator: inout DatabaseMigrator) {
        migrator.registerMigration(version) { db in
            try db.execute(sql: """
                CREATE TABLE listening_sessions (
                    id TEXT PRIMARY KEY NOT NULL CHECK(length(id) = 36),
                    trackID TEXT REFERENCES tracks(id) ON DELETE SET NULL,
                    startedAt DATETIME NOT NULL,
                    startDay TEXT NOT NULL CHECK(length(startDay) = 10),
                    lastCheckpointAt DATETIME NOT NULL,
                    endedAt DATETIME,
                    listenedMs INTEGER NOT NULL DEFAULT 0 CHECK(listenedMs >= 0),
                    durationMs INTEGER CHECK(durationMs IS NULL OR durationMs >= 0),
                    contextKind TEXT NOT NULL CHECK(length(contextKind) BETWEEN 1 AND 64),
                    contextSourceID TEXT,
                    qualified INTEGER NOT NULL DEFAULT 0 CHECK(qualified IN (0, 1)),
                    completed INTEGER NOT NULL DEFAULT 0 CHECK(completed IN (0, 1)),
                    state TEXT NOT NULL CHECK(state IN ('active', 'finished', 'recovered')),
                    endReason TEXT
                );
                CREATE INDEX listening_sessions_start_day ON listening_sessions(startDay);
                CREATE INDEX listening_sessions_track ON listening_sessions(trackID);
                CREATE INDEX listening_sessions_context ON listening_sessions(contextKind, contextSourceID);
                CREATE INDEX listening_sessions_active ON listening_sessions(state) WHERE state = 'active';
                CREATE TABLE listening_session_days (
                    sessionID TEXT NOT NULL REFERENCES listening_sessions(id) ON DELETE CASCADE,
                    day TEXT NOT NULL CHECK(length(day) = 10),
                    listenedMs INTEGER NOT NULL CHECK(listenedMs >= 0),
                    PRIMARY KEY (sessionID, day)
                );
                CREATE INDEX listening_session_days_day ON listening_session_days(day, sessionID, listenedMs);
                CREATE TABLE listening_analytics_state (
                    slot INTEGER PRIMARY KEY NOT NULL CHECK(slot = 1),
                    trackingStartedAt DATETIME NOT NULL
                );
                """)
            try db.execute(sql: "INSERT INTO listening_analytics_state (slot, trackingStartedAt) VALUES (1, ?)", arguments: [Date()])
        }
    }
}

/// Where a playback came from. Unknown context stays unknown; nothing is guessed.
struct ListeningContext: Equatable, Sendable {
    let kind: String
    let sourceID: String?
    static let unknown = ListeningContext(kind: "unknown", sourceID: nil)
    static let manualQueue = ListeningContext(kind: "queue", sourceID: nil)
    /// Kinds whose `sourceID` is a `playlists.id`.
    static let playlistKinds = ["playlist", "migrationPlaylist"]
}

/// Explicit play-counting policy (documented in Docs/PHASE_11_02_LISTENING_ANALYTICS.md).
enum ListeningPolicy {
    /// A qualified play: at least 30 s of real audio, or half of a track shorter than 60 s.
    static let qualifiedMs: Int64 = 30_000
    static let shortTrackMs: Int64 = 60_000
    /// A completed play: playback reached the natural end of the item and at least this
    /// share of the song was actually heard. Seeking to the end never counts.
    static let completedShare = 0.8
    /// Unflushed credited time after which a checkpoint is written.
    static let checkpointMs: Int64 = 15_000

    static func isQualified(listenedMs: Int64, durationMs: Int64?) -> Bool {
        if listenedMs >= qualifiedMs { return true }
        if let durationMs, durationMs > 0, durationMs < shortTrackMs { return listenedMs * 2 >= durationMs }
        return false
    }

    static func isCompleted(listenedMs: Int64, durationMs: Int64?, natural: Bool) -> Bool {
        guard natural, isQualified(listenedMs: listenedMs, durationMs: durationMs) else { return false }
        guard let durationMs, durationMs > 0 else { return true }
        return Double(listenedMs) >= Double(durationMs) * completedShare
    }
}

/// Local calendar-day keys (`yyyy-MM-dd`) in the calendar's time zone at the moment of listening.
struct ListeningDayKey {
    var calendar: Calendar

    func key(for date: Date) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    func date(for key: String) -> Date? {
        let parts = key.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        return calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2]))
    }

    /// Splits `[start, end]` at local midnights, returning milliseconds per day key.
    func split(start: Date, end: Date, milliseconds: Double) -> [(String, Double)] {
        guard end > start else { return [(key(for: end), milliseconds)] }
        var result: [(String, Double)] = []
        var cursor = start
        let total = end.timeIntervalSince(start)
        while cursor < end {
            let nextMidnight = calendar.nextDate(after: cursor, matching: DateComponents(hour: 0, minute: 0, second: 0), matchingPolicy: .nextTime) ?? end
            let segmentEnd = min(nextMidnight, end)
            let share = segmentEnd.timeIntervalSince(cursor) / total
            result.append((key(for: cursor), milliseconds * share))
            guard segmentEnd > cursor else { break }
            cursor = segmentEnd
        }
        return result.isEmpty ? [(key(for: end), milliseconds)] : result
    }
}
