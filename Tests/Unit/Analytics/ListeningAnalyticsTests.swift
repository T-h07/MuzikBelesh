import Foundation
import GRDB
import XCTest
@testable import OFFLINE

// MARK: - Helpers (synchronous, so async tests never pick GRDB's async read overloads)

struct SessionRow: Equatable {
    let id: String
    let trackID: String?
    let listenedMs: Int64
    let contextKind: String
    let contextSourceID: String?
    let qualified: Bool
    let completed: Bool
    let state: String
    let endReason: String?
}

func listeningSessions(_ db: DatabaseQueue) throws -> [SessionRow] {
    try db.read { db in
        try Row.fetchAll(db, sql: "SELECT * FROM listening_sessions ORDER BY startedAt, rowid").map {
            SessionRow(id: $0["id"], trackID: $0["trackID"], listenedMs: $0["listenedMs"], contextKind: $0["contextKind"], contextSourceID: $0["contextSourceID"],
                       qualified: $0["qualified"], completed: $0["completed"], state: $0["state"], endReason: $0["endReason"])
        }
    }
}

func listeningDayTotals(_ db: DatabaseQueue) throws -> [String: Int64] {
    try db.read { db in
        Dictionary(uniqueKeysWithValues: try Row.fetchAll(db, sql: "SELECT day, SUM(listenedMs) AS ms FROM listening_session_days GROUP BY day").map { ($0["day"] as String, $0["ms"] as Int64) })
    }
}

func utcCalendar(_ identifier: String = "UTC") -> Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: identifier)!
    return calendar
}

func date(_ text: String, _ calendar: Calendar = utcCalendar()) -> Date {
    let formatter = DateFormatter()
    formatter.calendar = calendar
    formatter.timeZone = calendar.timeZone
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
    return formatter.date(from: text)!
}

/// Wraps the real repository; can fail a chosen number of writes.
final class FlakyListeningStore: ListeningSessionStore {
    let base: ListeningAnalyticsRepository
    var failingWrites = 0
    var begins = 0
    var writes = 0
    init(base: ListeningAnalyticsRepository) { self.base = base }
    func recoverInterrupted() throws -> Int { try base.recoverInterrupted() }
    func begin(_ start: ListeningSessionStart) throws { begins += 1; try base.begin(start) }
    func write(_ update: ListeningSessionUpdate) throws {
        if failingWrites > 0 { failingWrites -= 1; throw StorageError.databaseUnavailable("injected") }
        writes += 1
        try base.write(update)
    }
}

// MARK: - Policy and formatting

final class ListeningPolicyTests: XCTestCase {
    func testQualifiedPlayThresholds() {
        XCTAssertFalse(ListeningPolicy.isQualified(listenedMs: 29_999, durationMs: 200_000))
        XCTAssertTrue(ListeningPolicy.isQualified(listenedMs: 30_000, durationMs: 200_000))
        XCTAssertTrue(ListeningPolicy.isQualified(listenedMs: 30_000, durationMs: nil))
        // Under 60 s: half the track qualifies.
        XCTAssertTrue(ListeningPolicy.isQualified(listenedMs: 20_000, durationMs: 40_000))
        XCTAssertFalse(ListeningPolicy.isQualified(listenedMs: 19_999, durationMs: 40_000))
        XCTAssertFalse(ListeningPolicy.isQualified(listenedMs: 0, durationMs: 40_000))
    }

    func testCompletedRequiresNaturalEndAndMostOfTheSong() {
        XCTAssertTrue(ListeningPolicy.isCompleted(listenedMs: 170_000, durationMs: 200_000, natural: true))
        XCTAssertFalse(ListeningPolicy.isCompleted(listenedMs: 170_000, durationMs: 200_000, natural: false), "Stopping is never a completion")
        XCTAssertFalse(ListeningPolicy.isCompleted(listenedMs: 40_000, durationMs: 200_000, natural: true), "Seeking near the end then finishing is not a completion")
        XCTAssertTrue(ListeningPolicy.isCompleted(listenedMs: 1_700, durationMs: 2_000, natural: true))
    }

    func testDurationFormatting() {
        XCTAssertEqual(ListeningFormat.duration(0), "0m")
        XCTAssertEqual(ListeningFormat.duration(30_000), "<1m")
        XCTAssertEqual(ListeningFormat.duration(42 * 60_000), "42m")
        XCTAssertEqual(ListeningFormat.duration(3 * 3_600_000), "3h")
        XCTAssertEqual(ListeningFormat.duration(128 * 3_600_000 + 42 * 60_000 + 59_000), "128h 42m")
        XCTAssertEqual(ListeningFormat.plays(1), "1 play")
    }

    func testDayKeysSplitAtMidnight() {
        let calendar = utcCalendar()
        let keys = ListeningDayKey(calendar: calendar)
        let parts = keys.split(start: date("2026-03-01 23:59:50"), end: date("2026-03-02 00:00:10"), milliseconds: 20_000)
        XCTAssertEqual(parts.map(\.0), ["2026-03-01", "2026-03-02"])
        XCTAssertEqual(parts[0].1, 10_000, accuracy: 0.5)
        XCTAssertEqual(parts[1].1, 10_000, accuracy: 0.5)
    }

    func testRangesAreCalendarDaysIncludingTodayAcrossDaylightSaving() {
        // US daylight saving began on 8 March 2026; the 23-hour day is still one day.
        let calendar = utcCalendar("America/New_York")
        let now = date("2026-03-10 08:00:00", calendar)
        XCTAssertEqual(ListeningRange.last7.bounds(now: now, calendar: calendar).start, "2026-03-04")
        XCTAssertEqual(ListeningRange.last7.bounds(now: now, calendar: calendar).end, "2026-03-10")
        XCTAssertEqual(ListeningRange.last30.bounds(now: now, calendar: calendar).start, "2026-02-09")
        let late = date("2026-03-10 23:59:59", calendar)
        XCTAssertEqual(ListeningRange.last7.bounds(now: late, calendar: calendar).end, "2026-03-10")
    }

    func testChartBucketsFillGapsAndAggregateAllTime() {
        let calendar = Calendar.current
        let now = Date()
        let keys = ListeningDayKey(calendar: calendar)
        let today = calendar.startOfDay(for: now)
        let twoDaysAgo = calendar.date(byAdding: .day, value: -2, to: today)!
        var week = ListeningSummary(range: .last7, startDay: "", endDay: "")
        week.days = [ListeningDayTotal(day: keys.key(for: twoDaysAgo), listenedMs: 90_000)]
        let (granularity, buckets) = ListeningChartModel.buckets(for: week, now: now, calendar: calendar)
        XCTAssertEqual(granularity, .day)
        XCTAssertEqual(buckets.count, 7)
        XCTAssertEqual(buckets.reduce(0) { $0 + $1.listenedMs }, 90_000, "Chart totals equal the stored totals")
        XCTAssertEqual(buckets.first { $0.start == twoDaysAgo }?.listenedMs, 90_000)

        var all = ListeningSummary(range: .allTime, startDay: "", endDay: "")
        let longAgo = calendar.date(byAdding: .day, value: -400, to: today)!
        all.days = [ListeningDayTotal(day: keys.key(for: longAgo), listenedMs: 60_000), ListeningDayTotal(day: keys.key(for: today), listenedMs: 120_000)]
        let (allGranularity, allBuckets) = ListeningChartModel.buckets(for: all, now: now, calendar: calendar)
        XCTAssertEqual(allGranularity, .month)
        XCTAssertLessThanOrEqual(allBuckets.count, 15, "All Time never draws hundreds of daily bars")
        XCTAssertEqual(allBuckets.reduce(0) { $0 + $1.listenedMs }, 180_000)
        XCTAssertEqual(ListeningChartModel.granularity(for: .allTime, spanDays: 90), .week)
    }
}

// MARK: - Tracker

@MainActor final class ListeningSessionTrackerTests: XCTestCase {
    private var fixture: LibraryFixture!
    private var repository: ListeningAnalyticsRepository!
    private var clock: TimeInterval = 1_000
    private var wall = Date(timeIntervalSince1970: 1_800_000_000)

    override func setUpWithError() throws {
        fixture = try LibraryFixture(count: 3)
        repository = ListeningAnalyticsRepository(db: fixture.storage.database.dbQueue)
    }

    private func tracker(_ store: ListeningSessionStore? = nil) -> ListeningSessionTracker {
        let tracker = ListeningSessionTracker(store: store ?? repository)
        tracker.uptime = { [unowned self] in self.clock }
        tracker.now = { [unowned self] in self.wall }
        tracker.calendar = utcCalendar()
        return tracker
    }

    private func advance(_ seconds: TimeInterval) { clock += seconds; wall = wall.addingTimeInterval(seconds) }

    /// Simulates continuous playback from `from` for `seconds`, observed every half second.
    private func play(_ tracker: ListeningSessionTracker, from: Double = 0, seconds: Double, duration: Double = 200) {
        tracker.observe(position: from, duration: duration, playing: true)
        var position = from
        for _ in 0..<Int(seconds * 2) {
            advance(0.5); position += 0.5
            tracker.observe(position: position, duration: duration, playing: true)
        }
    }

    private var db: DatabaseQueue { fixture.storage.database.dbQueue }

    func testCreditsOnlyProgressingAudio() throws {
        let tracker = tracker()
        tracker.prepare(trackID: fixture.ids[0], durationSeconds: 200, context: .unknown)
        play(tracker, seconds: 10)
        // Paused: the position does not move however long the wall clock runs.
        tracker.observe(position: 10, duration: 200, playing: false)
        advance(600)
        tracker.observe(position: 10, duration: 200, playing: false)
        // Buffering: playing intent but no progress.
        tracker.observe(position: 10, duration: 200, playing: true)
        advance(30)
        tracker.observe(position: 10, duration: 200, playing: true)
        tracker.finish(reason: "stopped", natural: false)
        let rows = try listeningSessions(db)
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].listenedMs, 10_000)
        XCTAssertEqual(rows[0].state, "finished")
        XCTAssertEqual(try listeningDayTotals(db).values.reduce(0, +), 10_000, "Day rows equal the session total")
    }

    func testSeeksAndJumpsAreNeverCredited() throws {
        let tracker = tracker()
        tracker.prepare(trackID: fixture.ids[0], durationSeconds: 200, context: .unknown)
        play(tracker, seconds: 5)
        tracker.discontinuity()
        advance(0.5)
        tracker.observe(position: 150, duration: 200, playing: true) // after a seek forward
        play(tracker, from: 150, seconds: 5)
        // A jump the player did not announce is capped at the elapsed time plus jitter.
        advance(1)
        tracker.observe(position: 190, duration: 200, playing: true)
        tracker.finish(reason: "stopped", natural: false)
        let listened = try XCTUnwrap(listeningSessions(db).first).listenedMs
        XCTAssertEqual(listened, 11_250)
    }

    func testSelectionWithoutAudioCreatesNoSession() throws {
        let tracker = tracker()
        tracker.prepare(trackID: fixture.ids[0], durationSeconds: 200, context: .unknown)
        tracker.observe(position: 0, duration: 200, playing: false)
        tracker.prepare(trackID: fixture.ids[1], durationSeconds: 200, context: .unknown)
        tracker.finish(reason: "stopped", natural: false)
        XCTAssertEqual(try listeningSessions(db).count, 0)
    }

    func testCheckpointsWhilePlayingAndRecoveryKeepsCheckpointedTime() throws {
        let tracker = tracker()
        tracker.prepare(trackID: fixture.ids[0], durationSeconds: 200, context: .unknown)
        play(tracker, seconds: 40)
        // Simulated crash: the tracker disappears without finishing.
        let stored = try XCTUnwrap(listeningSessions(db).first)
        XCTAssertEqual(stored.state, "active")
        XCTAssertGreaterThanOrEqual(stored.listenedMs, 30_000, "Checkpoints happen every 15 s of audio")
        let relaunched = ListeningSessionTracker(store: repository)
        XCTAssertEqual(relaunched.recoveredSessions, 1)
        let recovered = try XCTUnwrap(listeningSessions(db).first)
        XCTAssertEqual(recovered.state, "recovered")
        XCTAssertEqual(recovered.listenedMs, stored.listenedMs)
        XCTAssertTrue(recovered.qualified)
        XCTAssertFalse(recovered.completed)
        XCTAssertEqual(try repository.recoverInterrupted(), 0, "Recovery is idempotent")
    }

    func testNaturalEndCompletesAndReplacementDoesNot() throws {
        let tracker = tracker()
        tracker.prepare(trackID: fixture.ids[0], durationSeconds: 40, context: .unknown)
        play(tracker, seconds: 39, duration: 40)
        tracker.finish(reason: "completed", natural: true)
        tracker.prepare(trackID: fixture.ids[1], durationSeconds: 200, context: .unknown)
        play(tracker, seconds: 31)
        tracker.prepare(trackID: fixture.ids[2], durationSeconds: 200, context: .unknown) // skipped
        let rows = try listeningSessions(db)
        XCTAssertEqual(rows.map(\.completed), [true, false])
        XCTAssertEqual(rows.map(\.qualified), [true, true])
        XCTAssertEqual(rows[1].endReason, "replaced")
    }

    func testRepeatedPlaysOfOneSongAreSeparateSessionsButReloadsContinue() throws {
        let tracker = tracker()
        tracker.prepare(trackID: fixture.ids[0], durationSeconds: 200, context: .unknown)
        play(tracker, seconds: 5)
        tracker.prepare(trackID: fixture.ids[0], durationSeconds: 200, context: .unknown, continuing: true) // failure reload
        play(tracker, from: 5, seconds: 5)
        tracker.finish(reason: "completed", natural: true)
        tracker.prepare(trackID: fixture.ids[0], durationSeconds: 200, context: .unknown) // Repeat One
        play(tracker, seconds: 5)
        tracker.finish(reason: "stopped", natural: false)
        XCTAssertEqual(try listeningSessions(db).map(\.listenedMs), [10_000, 5_000])
    }

    func testMidnightCrossingSplitsListeningByDay() throws {
        wall = date("2026-05-01 23:59:50")
        let tracker = tracker()
        tracker.prepare(trackID: fixture.ids[0], durationSeconds: 200, context: .unknown)
        play(tracker, seconds: 20)
        tracker.finish(reason: "stopped", natural: false)
        let days = try listeningDayTotals(db)
        XCTAssertEqual(days["2026-05-01"], 10_000)
        XCTAssertEqual(days["2026-05-02"], 10_000)
    }

    func testStoreFailureNeverThrowsAndIsRetriedWithoutDuplication() throws {
        let store = FlakyListeningStore(base: repository)
        let tracker = tracker(store)
        tracker.prepare(trackID: fixture.ids[0], durationSeconds: 200, context: .unknown)
        store.failingWrites = 1
        play(tracker, seconds: 15) // the 15 s checkpoint fails
        XCTAssertNotNil(tracker.lastError)
        play(tracker, from: 15, seconds: 17) // retried on the next observation
        tracker.finish(reason: "stopped", natural: false)
        tracker.finish(reason: "stopped", natural: false) // duplicate finalization is a no-op
        XCTAssertNil(tracker.lastError)
        let rows = try listeningSessions(db)
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].listenedMs, 32_000)
        XCTAssertEqual(try listeningDayTotals(db).values.reduce(0, +), 32_000)
    }

    func testMissingStorageIsHarmless() {
        let tracker = ListeningSessionTracker(store: nil)
        tracker.prepare(trackID: "x", durationSeconds: 10, context: .unknown)
        tracker.observe(position: 0, duration: 10, playing: true)
        tracker.observe(position: 1, duration: 10, playing: true)
        tracker.finish(reason: "stopped", natural: false)
        XCTAssertNil(tracker.activeTrackID)
    }
}

// MARK: - Repository and aggregation

final class ListeningAnalyticsRepositoryTests: XCTestCase {
    private var fixture: LibraryFixture!
    private var repository: ListeningAnalyticsRepository!
    private let calendar = utcCalendar()
    private var db: DatabaseQueue { fixture.storage.database.dbQueue }

    override func setUpWithError() throws {
        fixture = try LibraryFixture(count: 4)
        repository = ListeningAnalyticsRepository(db: fixture.storage.database.dbQueue)
    }

    @discardableResult
    private func session(_ trackID: String, day: String, ms: Int64, context: ListeningContext = .unknown, qualified: Bool? = nil, completed: Bool = false) throws -> String {
        let id = UUID().uuidString
        let at = date(day + " 12:00:00")
        try repository.begin(ListeningSessionStart(id: id, trackID: trackID, startedAt: at, startDay: day, durationMs: 200_000, context: context))
        try repository.write(ListeningSessionUpdate(id: id, listenedMs: ms, durationMs: 200_000, qualified: qualified ?? (ms >= 30_000), completed: completed,
                                                    dayDeltas: [day: ms], at: at, endReason: "stopped"))
        return id
    }

    private let now = date("2026-06-15 10:00:00")

    func testMigrationCreatesAnalyticsTablesAndRecordsTrackingStart() throws {
        let tables = try db.read { try String.fetchAll($0, sql: "SELECT name FROM sqlite_master WHERE type = 'table' AND name LIKE 'listening_%' ORDER BY name") }
        XCTAssertEqual(tables, ["listening_analytics_state", "listening_session_days", "listening_sessions"])
        XCTAssertNotNil(try repository.summary(range: .allTime).trackingStartedAt)
        XCTAssertNotEqual(ListeningAnalyticsSchema.version, CanceledPhase108UpgradeTests.canceledMigration)
        XCTAssertEqual(ListeningAnalyticsSchema.version, "v025_listening_analytics")
        XCTAssertEqual(try fixture.foreignKeys(), 0)
    }

    func testFinalizationIsIdempotent() throws {
        let id = try session(fixture.ids[0], day: "2026-06-15", ms: 40_000)
        try repository.write(ListeningSessionUpdate(id: id, listenedMs: 80_000, durationMs: nil, qualified: true, completed: true, dayDeltas: ["2026-06-15": 40_000], at: now, endReason: "stopped"))
        XCTAssertEqual(try listeningSessions(db).first?.listenedMs, 40_000)
        XCTAssertEqual(try listeningDayTotals(db)["2026-06-15"], 40_000)
    }

    func testMetricsAreDistinct() throws {
        try session(fixture.ids[0], day: "2026-06-15", ms: 200_000, completed: true)
        try session(fixture.ids[0], day: "2026-06-14", ms: 45_000)
        try session(fixture.ids[1], day: "2026-06-14", ms: 10_000) // a start, not a qualified play
        let summary = try repository.summary(range: .last7, now: now, calendar: calendar)
        XCTAssertEqual(summary.playbackStarts, 3)
        XCTAssertEqual(summary.qualifiedPlays, 2)
        XCTAssertEqual(summary.completedPlays, 1)
        XCTAssertEqual(summary.uniqueSongs, 2)
        XCTAssertEqual(summary.listenedMs, 255_000)
        XCTAssertEqual(summary.longestSessionMs, 200_000)
        XCTAssertEqual(summary.mostReplayed?.trackID, fixture.ids[0])
        XCTAssertEqual(summary.busiestDay?.day, "2026-06-15")
    }

    func testRangesUseCalendarDaysIncludingToday() throws {
        try session(fixture.ids[0], day: "2026-06-15", ms: 60_000)
        try session(fixture.ids[0], day: "2026-06-09", ms: 60_000) // 7th day back: inside
        try session(fixture.ids[0], day: "2026-06-08", ms: 60_000) // 8th day back: outside 7 days
        try session(fixture.ids[0], day: "2026-05-17", ms: 60_000) // 30th day back
        try session(fixture.ids[0], day: "2026-01-01", ms: 60_000)
        XCTAssertEqual(try repository.summary(range: .last7, now: now, calendar: calendar).listenedMs, 120_000)
        XCTAssertEqual(try repository.summary(range: .last30, now: now, calendar: calendar).listenedMs, 240_000)
        XCTAssertEqual(try repository.summary(range: .allTime, now: now, calendar: calendar).listenedMs, 300_000)
    }

    func testRankingsAndPlaylistAttribution() throws {
        let playlist = try fixture.repository.createPlaylist(name: "Road Trip")
        let other = try fixture.repository.createPlaylist(name: "Focus")
        try session(fixture.ids[1], day: "2026-06-15", ms: 300_000, context: ListeningContext(kind: "playlist", sourceID: playlist.id))
        try session(fixture.ids[2], day: "2026-06-15", ms: 100_000, context: ListeningContext(kind: "migrationPlaylist", sourceID: other.id))
        try session(fixture.ids[3], day: "2026-06-15", ms: 500_000, context: .manualQueue)
        try session(fixture.ids[0], day: "2026-06-15", ms: 50_000, context: ListeningContext(kind: "album", sourceID: "x"))
        let summary = try repository.summary(range: .last7, now: now, calendar: calendar)
        XCTAssertEqual(summary.topSongs.map(\.trackID), [fixture.ids[3], fixture.ids[1], fixture.ids[2], fixture.ids[0]])
        XCTAssertEqual(summary.topPlaylists.map(\.title), ["Road Trip", "Focus"], "Queue and album plays are never playlist plays")
        XCTAssertEqual(summary.topPlaylists.first?.plays, 1)
        XCTAssertLessThanOrEqual(summary.topSongs.count, ListeningAnalyticsRepository.rankingLimit)
    }

    func testDeletedSongKeepsTotalsButLeavesRankings() throws {
        try session(fixture.ids[0], day: "2026-06-15", ms: 90_000)
        try session(fixture.ids[1], day: "2026-06-15", ms: 30_000)
        try fixture.storage.database.dbQueue.write { try $0.execute(sql: "DELETE FROM tracks WHERE id = ?", arguments: [fixture.ids[0]]) }
        let summary = try repository.summary(range: .last7, now: now, calendar: calendar)
        XCTAssertEqual(summary.listenedMs, 120_000)
        XCTAssertEqual(summary.topSongs.map(\.trackID), [fixture.ids[1]])
        XCTAssertNil(try listeningSessions(db).first?.trackID)
    }

    func testRenamedSongShowsCurrentMetadata() throws {
        try session(fixture.ids[0], day: "2026-06-15", ms: 90_000)
        try fixture.repository.editMetadata(trackID: fixture.ids[0], draft: TrackMetadataDraft(title: "Renamed", artist: "New Artist", album: "New Album"))
        let summary = try repository.summary(range: .last7, now: now, calendar: calendar)
        XCTAssertEqual(summary.topSongs.first?.title, "Renamed")
        XCTAssertEqual(summary.topArtists.first?.title, "New Artist")
        XCTAssertEqual(summary.topAlbums.first?.title, "New Album")
    }

    func testLegacyPlaybackHistoryIsNotCountedAsListening() throws {
        try fixture.storage.playback.addHistory(StoredHistoryEntry(id: UUID().uuidString, trackID: fixture.ids[0], startedAt: now, completedAt: now, durationListenedMs: 9_000_000, source: "playback"))
        let summary = try repository.summary(range: .allTime, now: now, calendar: calendar)
        XCTAssertEqual(summary.listenedMs, 0)
        XCTAssertFalse(summary.hasAnyListening)
        XCTAssertTrue(summary.isEmpty)
    }

    func testAggregationScalesTo100kSessions() throws {
        try db.write { db in
            for index in 0..<100_000 {
                let id = UUID().uuidString
                let day = String(format: "2026-%02d-%02d", 1 + index % 6, 1 + index % 28)
                try db.execute(sql: """
                    INSERT INTO listening_sessions (id, trackID, startedAt, startDay, lastCheckpointAt, listenedMs, contextKind, qualified, state)
                    VALUES (?, ?, ?, ?, ?, 60000, 'library', 1, 'finished')
                    """, arguments: [id, fixture.ids[index % 4], now, day, now])
                try db.execute(sql: "INSERT INTO listening_session_days (sessionID, day, listenedMs) VALUES (?, ?, 60000)", arguments: [id, day])
            }
        }
        let started = Date()
        let summary = try repository.summary(range: .allTime, now: now, calendar: calendar)
        let elapsed = Date().timeIntervalSince(started)
        XCTAssertEqual(summary.playbackStarts, 100_000)
        XCTAssertEqual(summary.listenedMs, 6_000_000_000)
        XCTAssertEqual(summary.topSongs.count, 4)
        XCTAssertLessThan(elapsed, 5, "All-time aggregation over 100k sessions took \(elapsed) s")
    }
}

// MARK: - Player integration

@MainActor final class ListeningPlaybackIntegrationTests: XCTestCase {
    private var clock: TimeInterval = 50

    private func makePlayer() throws -> (LibraryFixture, AudioPlayerService, LibraryTestTransport) {
        let fixture = try LibraryFixture(count: 3)
        retainUntilTeardown(fixture)
        let (player, transport, _) = fixture.services()
        player.listening.uptime = { [unowned self] in self.clock }
        return (fixture, player, transport)
    }

    private func listen(_ player: AudioPlayerService, from: Double = 0, seconds: Double) {
        var position = from
        player.samplePlaybackTime(position)
        for _ in 0..<Int(seconds * 2) { clock += 0.5; position += 0.5; player.samplePlaybackTime(position) }
    }

    func testPlaylistPlaybackIsAttributedAndPausedTimeIsNot() async throws {
        let (fixture, player, _) = try makePlayer()
        let playlist = try fixture.repository.createPlaylist(name: "Attributed")
        try await player.play(trackID: fixture.ids[0], contextTrackIDs: fixture.ids, contextKind: "playlist", contextSourceID: playlist.id)
        listen(player, seconds: 1)
        player.pause()
        clock += 120 // paused time
        let rows = try listeningSessions(fixture.storage.database.dbQueue)
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].contextKind, "playlist")
        XCTAssertEqual(rows[0].contextSourceID, playlist.id)
        XCTAssertEqual(rows[0].listenedMs, 1_000)
    }

    func testManualQueueSongIsNotCreditedToThePreviousPlaylist() async throws {
        let (fixture, player, _) = try makePlayer()
        let playlist = try fixture.repository.createPlaylist(name: "Context")
        try await player.play(trackID: fixture.ids[0], contextTrackIDs: [fixture.ids[0], fixture.ids[1]], contextKind: "playlist", contextSourceID: playlist.id)
        listen(player, seconds: 1)
        player.queue.addToQueue(trackID: fixture.ids[2])
        await player.next()
        XCTAssertEqual(player.state.currentTrackID, fixture.ids[2])
        listen(player, seconds: 1)
        player.pause()
        let rows = try listeningSessions(fixture.storage.database.dbQueue)
        XCTAssertEqual(rows.map(\.trackID), [fixture.ids[0], fixture.ids[2]])
        XCTAssertEqual(rows.map(\.contextKind), ["playlist", "queue"])
        XCTAssertNil(rows[1].contextSourceID)
    }

    func testUnknownContextStaysUnknownAndSkippedSelectionsRecordNothing() async throws {
        let (fixture, player, _) = try makePlayer()
        try await player.play(trackID: fixture.ids[0])
        await player.next() // never produced audio
        listen(player, seconds: 1)
        player.stop()
        let rows = try listeningSessions(fixture.storage.database.dbQueue)
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].contextKind, "unknown")
        XCTAssertEqual(rows[0].endReason, "stopped")
    }

    func testNaturalCompletionIsRecordedOnce() async throws {
        let (fixture, player, _) = try makePlayer()
        try await player.play(trackID: fixture.ids[0], contextTrackIDs: fixture.ids, contextKind: "library")
        listen(player, seconds: 2)
        let generation = player.activeItemGeneration
        await player.completedItem(generation: generation)
        await player.completedItem(generation: generation) // duplicate end event
        let first = try XCTUnwrap(listeningSessions(fixture.storage.database.dbQueue).first)
        XCTAssertEqual(first.trackID, fixture.ids[0])
        XCTAssertTrue(first.completed)
        XCTAssertEqual(first.endReason, "completed")
        XCTAssertEqual(try listeningSessions(fixture.storage.database.dbQueue).filter { $0.trackID == fixture.ids[0] }.count, 1)
    }

    func testSeekingIsNotListening() async throws {
        let (fixture, player, _) = try makePlayer()
        try await player.play(trackID: fixture.ids[0], contextTrackIDs: fixture.ids, contextKind: "library")
        listen(player, seconds: 0.5)
        await player.seek(to: 1.5)
        clock += 0.5
        player.samplePlaybackTime(1.5)
        listen(player, from: 1.5, seconds: 0.5)
        player.pause()
        XCTAssertEqual(try listeningSessions(fixture.storage.database.dbQueue).first?.listenedMs, 1_000)
    }
}
