import Foundation
import GRDB

struct ListeningSessionStart: Equatable, Sendable {
    let id: String
    let trackID: String
    let startedAt: Date
    let startDay: String
    let durationMs: Int64?
    let context: ListeningContext
}

/// An absolute session total plus the per-day deltas credited since the last write.
struct ListeningSessionUpdate: Equatable, Sendable {
    let id: String
    let listenedMs: Int64
    let durationMs: Int64?
    let qualified: Bool
    let completed: Bool
    let dayDeltas: [String: Int64]
    let at: Date
    /// Non-nil finalizes the session; finalization happens at most once.
    let endReason: String?
}

/// The writes the tracker needs. Tests substitute failing stores; failures never reach playback.
protocol ListeningSessionStore: AnyObject {
    @discardableResult func recoverInterrupted() throws -> Int
    func begin(_ start: ListeningSessionStart) throws
    func write(_ update: ListeningSessionUpdate) throws
}

enum ListeningRange: String, CaseIterable, Identifiable, Sendable {
    case last7, last30, allTime
    var id: String { rawValue }
    var title: String {
        switch self { case .last7: return "Last 7 Days"; case .last30: return "Last 30 Days"; case .allTime: return "All Time" }
    }
    var shortTitle: String {
        switch self { case .last7: return "7 Days"; case .last30: return "30 Days"; case .allTime: return "All Time" }
    }
    /// Number of local calendar days including today, or nil for all time.
    var dayCount: Int? {
        switch self { case .last7: return 7; case .last30: return 30; case .allTime: return nil }
    }

    /// Inclusive day-key bounds. "Last 7 Days" is today plus the six previous calendar days,
    /// computed with calendar arithmetic so daylight-saving days are still one day each.
    func bounds(now: Date, calendar: Calendar) -> (start: String, end: String) {
        let keys = ListeningDayKey(calendar: calendar)
        guard let dayCount else { return ("0000-01-01", "9999-12-31") }
        let today = calendar.startOfDay(for: now)
        let first = calendar.date(byAdding: .day, value: -(dayCount - 1), to: today) ?? today
        return (keys.key(for: first), keys.key(for: today))
    }
}

struct RankedSong: Identifiable, Equatable, Sendable {
    let trackID: String
    let title: String
    let artistName: String
    let artworkPath: String?
    let isAvailable: Bool
    let listenedMs: Int64
    let plays: Int
    var id: String { trackID }
}

struct RankedCollection: Identifiable, Equatable, Sendable {
    let id: String
    let title: String
    let subtitle: String
    let artworkPath: String?
    let listenedMs: Int64
    let plays: Int
}

struct ListeningDayTotal: Identifiable, Equatable, Sendable {
    let day: String
    let listenedMs: Int64
    var id: String { day }
}

struct LibraryOverview: Equatable, Sendable {
    var songs = 0
    var availableOffline = 0
    var playlists = 0
    var storageBytes: Int64 = 0
}

struct ListeningSummary: Equatable, Sendable {
    var range: ListeningRange
    var startDay: String
    var endDay: String
    var listenedMs: Int64 = 0
    var playbackStarts = 0
    var qualifiedPlays = 0
    var completedPlays = 0
    var uniqueSongs = 0
    var longestSessionMs: Int64 = 0
    var mostReplayed: RankedSong?
    var days: [ListeningDayTotal] = []
    var topSongs: [RankedSong] = []
    var topArtists: [RankedCollection] = []
    var topAlbums: [RankedCollection] = []
    var topPlaylists: [RankedCollection] = []
    var library = LibraryOverview()
    var trackingStartedAt: Date?
    /// True once any listening has ever been recorded, in any range.
    var hasAnyListening = false

    var isEmpty: Bool { listenedMs == 0 && playbackStarts == 0 }
    var busiestDay: ListeningDayTotal? { days.filter { $0.listenedMs > 0 }.max { ($0.listenedMs, $1.day) < ($1.listenedMs, $0.day) } }
}

/// All analytics SQL. Parameterized throughout; aggregation happens in SQLite with indexes
/// on day, start day, track and context, so it scales to 100k+ sessions.
final class ListeningAnalyticsRepository: ListeningSessionStore {
    private let db: DatabaseQueue
    static let rankingLimit = 5

    init(db: DatabaseQueue) { self.db = db }

    // MARK: Writes

    /// Sessions left active by a crash or termination keep the time of their last checkpoint.
    /// Idempotent: only `active` rows change.
    @discardableResult func recoverInterrupted() throws -> Int {
        try db.write { db in
            try db.execute(sql: """
                UPDATE listening_sessions SET state = 'recovered', endedAt = lastCheckpointAt, endReason = 'interrupted'
                WHERE state = 'active'
                """)
            return db.changesCount
        }
    }

    func begin(_ start: ListeningSessionStart) throws {
        try db.write { db in
            try db.execute(sql: """
                INSERT INTO listening_sessions (id, trackID, startedAt, startDay, lastCheckpointAt, listenedMs, durationMs, contextKind, contextSourceID, state)
                VALUES (?, ?, ?, ?, ?, 0, ?, ?, ?, 'active')
                ON CONFLICT(id) DO NOTHING
                """, arguments: [start.id, start.trackID, start.startedAt, start.startDay, start.startedAt, start.durationMs, start.context.kind, start.context.sourceID])
        }
    }

    /// Applies an update in one transaction. Day deltas are added only when the session row
    /// was still active, so a repeated or late write after finalization changes nothing.
    func write(_ update: ListeningSessionUpdate) throws {
        try db.write { db in
            let finishing = update.endReason != nil
            try db.execute(sql: """
                UPDATE listening_sessions
                SET listenedMs = ?, durationMs = COALESCE(?, durationMs), qualified = ?, completed = ?, lastCheckpointAt = ?,
                    endedAt = CASE WHEN ? THEN ? ELSE endedAt END,
                    state = CASE WHEN ? THEN 'finished' ELSE state END,
                    endReason = CASE WHEN ? THEN ? ELSE endReason END
                WHERE id = ? AND state = 'active'
                """, arguments: [update.listenedMs, update.durationMs, update.qualified, update.completed, update.at,
                                 finishing, update.at, finishing, finishing, update.endReason, update.id])
            guard db.changesCount == 1 else { return }
            for (day, delta) in update.dayDeltas where delta > 0 {
                try db.execute(sql: """
                    INSERT INTO listening_session_days (sessionID, day, listenedMs) VALUES (?, ?, ?)
                    ON CONFLICT(sessionID, day) DO UPDATE SET listenedMs = listenedMs + excluded.listenedMs
                    """, arguments: [update.id, day, delta])
            }
        }
    }

    // MARK: Reads

    func summary(range: ListeningRange, now: Date = Date(), calendar: Calendar = .current) throws -> ListeningSummary {
        let bounds = range.bounds(now: now, calendar: calendar)
        var summary = ListeningSummary(range: range, startDay: bounds.start, endDay: bounds.end)
        let args: StatementArguments = ["start": bounds.start, "end": bounds.end]
        try db.read { db in
            summary.listenedMs = try Int64.fetchOne(db, sql: "SELECT COALESCE(SUM(listenedMs), 0) FROM listening_session_days WHERE day BETWEEN :start AND :end", arguments: args) ?? 0
            if let row = try Row.fetchOne(db, sql: """
                SELECT COUNT(*) AS starts, COALESCE(SUM(qualified), 0) AS qualified, COALESCE(SUM(completed), 0) AS completed,
                       COUNT(DISTINCT trackID) AS songs, COALESCE(MAX(listenedMs), 0) AS longest
                FROM listening_sessions WHERE startDay BETWEEN :start AND :end
                """, arguments: args) {
                summary.playbackStarts = row["starts"]
                summary.qualifiedPlays = row["qualified"]
                summary.completedPlays = row["completed"]
                summary.uniqueSongs = row["songs"]
                summary.longestSessionMs = row["longest"]
            }
            summary.days = try Row.fetchAll(db, sql: """
                SELECT day, SUM(listenedMs) AS ms FROM listening_session_days WHERE day BETWEEN :start AND :end GROUP BY day ORDER BY day
                """, arguments: args).map { ListeningDayTotal(day: $0["day"], listenedMs: $0["ms"]) }
            summary.topSongs = try Self.songs(db, args: args, order: "per.ms DESC, per.plays DESC", having: "", limit: Self.rankingLimit)
            summary.mostReplayed = try Self.songs(db, args: args, order: "per.plays DESC, per.ms DESC", having: "WHERE per.plays >= 2", limit: 1).first
            summary.topArtists = try Self.collections(db, args: args, sql: """
                SELECT a.id AS id, a.name AS title, '' AS subtitle,
                       COALESCE(a.artworkRelativePath, MAX(t.artworkRelativePath)) AS artwork,
                       SUM(per.ms) AS ms, SUM(per.plays) AS plays
                FROM per JOIN tracks t ON t.id = per.trackID JOIN artists a ON a.id = t.artistID
                GROUP BY a.id
                """)
            summary.topAlbums = try Self.collections(db, args: args, sql: """
                SELECT al.id AS id, al.title AS title, COALESCE(ar.name, 'Unknown Artist') AS subtitle,
                       COALESCE(al.artworkRelativePath, MAX(t.artworkRelativePath)) AS artwork,
                       SUM(per.ms) AS ms, SUM(per.plays) AS plays
                FROM per JOIN tracks t ON t.id = per.trackID JOIN albums al ON al.id = t.albumID LEFT JOIN artists ar ON ar.id = al.artistID
                GROUP BY al.id
                """)
            summary.topPlaylists = try Row.fetchAll(db, sql: """
                SELECT p.id AS id, p.name AS title, '' AS subtitle, p.artworkRelativePath AS artwork,
                       SUM(d.listenedMs) AS ms,
                       COUNT(DISTINCT CASE WHEN s.qualified = 1 AND s.startDay BETWEEN :start AND :end THEN s.id END) AS plays
                FROM listening_session_days d
                JOIN listening_sessions s ON s.id = d.sessionID
                JOIN playlists p ON p.id = s.contextSourceID
                WHERE d.day BETWEEN :start AND :end AND s.contextKind IN ('playlist', 'migrationPlaylist')
                GROUP BY p.id ORDER BY ms DESC, plays DESC, p.name COLLATE NOCASE, p.id LIMIT \(Self.rankingLimit)
                """, arguments: args).map(Self.collection)
            if let row = try Row.fetchOne(db, sql: """
                SELECT COUNT(*) AS songs, COALESCE(SUM(availability = 'available'), 0) AS available, COALESCE(SUM(fileSizeBytes), 0) AS bytes FROM tracks
                """) {
                summary.library.songs = row["songs"]
                summary.library.availableOffline = row["available"]
                summary.library.storageBytes = row["bytes"]
            }
            summary.library.playlists = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM playlists") ?? 0
            summary.trackingStartedAt = try Date.fetchOne(db, sql: "SELECT trackingStartedAt FROM listening_analytics_state WHERE slot = 1")
            summary.hasAnyListening = try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM listening_session_days)") ?? false
        }
        return summary
    }

    /// Per-song totals in range: time from day rows, qualified plays from sessions started in range.
    private static let perSong = """
        WITH per AS (
            SELECT s.trackID AS trackID, SUM(d.listenedMs) AS ms,
                   COUNT(DISTINCT CASE WHEN s.qualified = 1 AND s.startDay BETWEEN :start AND :end THEN s.id END) AS plays
            FROM listening_session_days d JOIN listening_sessions s ON s.id = d.sessionID
            WHERE d.day BETWEEN :start AND :end AND s.trackID IS NOT NULL
            GROUP BY s.trackID
        )
        """

    private static func songs(_ db: Database, args: StatementArguments, order: String, having: String, limit: Int) throws -> [RankedSong] {
        try Row.fetchAll(db, sql: perSong + """
            SELECT per.trackID AS trackID, per.ms AS ms, per.plays AS plays, t.title AS title, t.artworkRelativePath AS artwork,
                   t.availability AS availability, COALESCE(a.name, 'Unknown Artist') AS artist
            FROM per JOIN tracks t ON t.id = per.trackID LEFT JOIN artists a ON a.id = t.artistID
            \(having)
            ORDER BY \(order), t.title COLLATE NOCASE, t.id LIMIT \(limit)
            """, arguments: args).map { row in
            RankedSong(trackID: row["trackID"], title: row["title"], artistName: row["artist"], artworkPath: row["artwork"],
                       isAvailable: (row["availability"] as String?) == StoredTrackAvailability.available.rawValue,
                       listenedMs: row["ms"], plays: row["plays"])
        }
    }

    private static func collections(_ db: Database, args: StatementArguments, sql: String) throws -> [RankedCollection] {
        try Row.fetchAll(db, sql: perSong + sql + " ORDER BY ms DESC, plays DESC, title COLLATE NOCASE, id LIMIT \(rankingLimit)", arguments: args).map(collection)
    }

    private static func collection(_ row: Row) -> RankedCollection {
        RankedCollection(id: row["id"], title: row["title"], subtitle: row["subtitle"], artworkPath: row["artwork"], listenedMs: row["ms"], plays: row["plays"])
    }
}
