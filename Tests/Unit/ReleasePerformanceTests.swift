import Combine
import Foundation
import GRDB
import XCTest
@testable import OFFLINE

/// Classifies every traced statement so the clock test can enforce per-table invariants
/// instead of one total that silently absorbs new work.
private final class SQLCounts: @unchecked Sendable {
    private let lock = NSLock()
    private var selects = 0
    private var positionWrites = 0
    private var listeningWrites = 0
    private var otherWrites: [String] = []
    func record(_ sql: String) {
        lock.lock()
        defer { lock.unlock() }
        let upper = sql.uppercased()
        if upper.hasPrefix("SELECT") { selects += 1; return }
        guard ["UPDATE", "INSERT", "DELETE"].contains(where: upper.hasPrefix) else { return }
        if upper.hasPrefix("UPDATE PLAYBACK_STATE SET POSITIONMS") { positionWrites += 1 }
        else if upper.contains("LISTENING_SESSION") { listeningWrites += 1 }
        else { otherWrites.append(sql) }
    }
    var values: (selects: Int, position: Int, listening: Int, other: [String]) {
        lock.lock(); defer { lock.unlock() }
        return (selects, positionWrites, listeningWrites, otherWrites)
    }
    var summary: String {
        let v = values
        return "selects=\(v.selects) positionWrites=\(v.position) listeningWrites=\(v.listening) otherWrites=\(v.other.count)"
    }
}

final class ReleasePerformanceTests: XCTestCase {
    /// One minute of playback clock samples (two per second).
    ///
    /// Invariants (Phase 12): the clock path performs no reads; the playback position is
    /// checkpointed once per 5 s of progress (12 per minute); listening analytics write one
    /// session INSERT plus one UPDATE and one day upsert per 15 s checkpoint (Phase 11.2,
    /// `ListeningPolicy.checkpointMs`); nothing else is written; publications stay bounded.
    /// Before Phase 12 this asserted a single total of 12 writes, which became stale when
    /// analytics checkpoints were added (CI #294/#298 measured 15 with real-time credit).
    @MainActor func testPlaybackClockDatabaseAndPublicationWork() async throws {
        let fixture = try LibraryFixture(count: 1)
        let transport = LibraryTestTransport()
        let player = AudioPlayerService(storage: fixture.storage, player: transport, registerRemoteCommands: false)
        // Deterministic clocks: monotonic time advances with the samples; a fixed midday
        // wall clock keeps every credited millisecond on one calendar day.
        var uptime: TimeInterval = 1_000
        player.listening.uptime = { uptime }
        let midday = Calendar.current.date(bySettingHour: 12, minute: 0, second: 0, of: Date(timeIntervalSince1970: 1_700_000_000))!
        player.listening.now = { midday }
        try await player.play(trackID: fixture.ids[0])
        for _ in 0..<20 { player.queue.addToQueue(trackID: fixture.ids[0]) }
        let counts = SQLCounts()
        try await fixture.storage.database.dbQueue.write { db in db.trace { counts.record($0.description) } }
        var publications = 0
        let token = player.objectWillChange.sink { publications += 1 }
        let start = ProcessInfo.processInfo.systemUptime
        for tick in 1...120 { uptime += 0.5; player.samplePlaybackTime(Double(tick) / 2) }
        let elapsed = ProcessInfo.processInfo.systemUptime - start
        token.cancel()
        try await fixture.storage.database.dbQueue.write { $0.trace(nil) }
        print("PHASE12 clock60s workElapsedSeconds=\(elapsed) publications=\(publications) credited=\(player.listening.currentListenedMs) \(counts.summary)")
        XCTAssertEqual(try fixture.storage.playback.queue().count, 20)
        XCTAssertEqual(player.state.elapsedTime, 60)
        let values = counts.values
        XCTAssertEqual(values.selects, 0, "The playback clock never reads the database")
        XCTAssertEqual(values.position, 12, "Position is checkpointed once per 5 s of progress")
        XCTAssertEqual(values.other, [], "The clock writes nothing except position and listening checkpoints")
        let credited = player.listening.currentListenedMs
        XCTAssertGreaterThanOrEqual(credited, 59_000)
        XCTAssertLessThanOrEqual(credited, 60_000, "Never more listening than playback progressed")
        let checkpoints = Int(credited / ListeningPolicy.checkpointMs)
        XCTAssertEqual(values.listening, 1 + 2 * checkpoints, "One session row, then one update and one day upsert per checkpoint")
        XCTAssertLessThanOrEqual(publications, 123)
    }

    func testSearchCPUAndMemoryMetrics() throws {
        let fixture = try LibraryFixture(count: 1)
        let original = try XCTUnwrap(fixture.storage.tracks.find(id: fixture.ids[0]))
        var snapshot = LibrarySnapshot()
        snapshot.tracks = (0..<10000).map { index in
            var track = original
            track.id = "metric-\(index)"
            track.title = "Synthetic Song \(index)"
            return track
        }
        let options = XCTMeasureOptions()
        options.iterationCount = 5
        measure(metrics: [XCTClockMetric(), XCTCPUMetric(), XCTMemoryMetric()], options: options) {
            XCTAssertFalse(LibrarySearchEngine.search("Synthetic Song 9", in: snapshot).isEmpty)
        }
    }

    func testLargeLibraryAndQueueBaseline() throws {
        let fixture = try LibraryFixture(count: 1)
        let original = try XCTUnwrap(fixture.storage.tracks.find(id: fixture.ids[0]))
        for count in [100, 1000, 5000, 10000] {
            var snapshot = LibrarySnapshot()
            snapshot.tracks = (0..<count).map { index in
                var track = original
                track.id = "stress-\(index)"
                track.title = "Synthetic Song \(index)"
                return track
            }
            let ids = snapshot.tracks.map(\.id)
            let navigation = PlaybackNavigationEngine(makeShuffle: { $0 })
            let start = ProcessInfo.processInfo.systemUptime
            navigation.setContext(ids, currentID: ids[0])
            let navigationSeconds = ProcessInfo.processInfo.systemUptime - start
            let searchStart = ProcessInfo.processInfo.systemUptime
            let result = LibrarySearchEngine.search("Synthetic Song 9", in: snapshot)
            let searchSeconds = ProcessInfo.processInfo.systemUptime - searchStart
            XCTAssertFalse(result.songs.isEmpty)
            XCTAssertEqual(navigation.context.count, count)
            navigation.setShuffleEnabled(true)
            XCTAssertNotEqual(navigation.next(), ids[0])
            print("PHASE9 library tracks=\(count) navigationSeconds=\(navigationSeconds) searchSeconds=\(searchSeconds)")
        }
    }
}
