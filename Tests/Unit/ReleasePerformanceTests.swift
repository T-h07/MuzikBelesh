import Combine
import Foundation
import GRDB
import XCTest
@testable import OFFLINE

private final class SQLCounts: @unchecked Sendable {
    private let lock = NSLock()
    private var selects = 0
    private var writes = 0
    func record(_ sql: String) {
        lock.lock()
        defer { lock.unlock() }
        let sql = sql.uppercased()
        if sql.hasPrefix("SELECT") { selects += 1 }
        if ["UPDATE", "INSERT", "DELETE"].contains(where: sql.hasPrefix) { writes += 1 }
    }
    var summary: String {
        lock.lock()
        defer { lock.unlock() }
        return "selects=\(selects) writes=\(writes)"
    }
}

final class ReleasePerformanceTests: XCTestCase {
    @MainActor func testPlaybackClockDatabaseAndPublicationWork() async throws {
        let fixture = try LibraryFixture(count: 1)
        let transport = LibraryTestTransport()
        let player = AudioPlayerService(storage: fixture.storage, player: transport, registerRemoteCommands: false)
        try await player.play(trackID: fixture.ids[0])
        for _ in 0..<20 { player.queue.addToQueue(trackID: fixture.ids[0]) }
        let counts = SQLCounts()
        try await fixture.storage.database.dbQueue.write { db in db.trace { counts.record($0.description) } }
        var publications = 0
        let token = player.objectWillChange.sink { publications += 1 }
        let start = ProcessInfo.processInfo.systemUptime
        for tick in 1...120 { player.samplePlaybackTime(Double(tick) / 2) }
        let elapsed = ProcessInfo.processInfo.systemUptime - start
        token.cancel()
        try await fixture.storage.database.dbQueue.write { $0.trace(nil) }
        print("PHASE9 clock60s cpuWorkSeconds=\(elapsed) publications=\(publications) \(counts.summary)")
        XCTAssertEqual(try fixture.storage.playback.queue().count, 20)
        XCTAssertEqual(player.state.elapsedTime, 60)
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
