import XCTest
@testable import OFFLINE

final class PlaylistMigrationFoundationTests: XCTestCase {
    private func entry(_ position: Int, id: UUID = UUID(), sourceID: String = "same-spotify-track") -> PlaylistMigrationSourceTrack {
        PlaylistMigrationSourceTrack(id: id, position: position, title: "Example Song", primaryArtist: "Example Artist",
                                     album: "Example Album", durationMs: 180_000, sourceTrackID: sourceID)
    }

    private func snapshot(_ entries: [PlaylistMigrationSourceTrack], timestamp: Date = Date()) -> PlaylistMigrationSourcePlaylist {
        PlaylistMigrationSourcePlaylist(source: .spotifyAccountExport, name: "My Playlist",
                                        sourcePlaylistID: "spotify-list", entries: entries, capturedAt: timestamp)
    }

    func testAllSessionStatusesEncodeAndDecode() throws {
        for state in PlaylistMigrationStatus.allCases {
            XCTAssertEqual(try JSONDecoder().decode(PlaylistMigrationStatus.self, from: JSONEncoder().encode(state)), state)
        }
    }

    func testAllEntryStatusesEncodeAndDecode() throws {
        for state in PlaylistMigrationEntryStatus.allCases {
            XCTAssertEqual(try JSONDecoder().decode(PlaylistMigrationEntryStatus.self, from: JSONEncoder().encode(state)), state)
        }
    }

    func testTerminalSessionsCannotRestart() {
        XCTAssertTrue(PlaylistMigrationStatus.completed.isTerminal)
        XCTAssertTrue(PlaylistMigrationStatus.cancelled.isTerminal)
        XCTAssertFalse(PlaylistMigrationStatus.partiallyCompleted.isTerminal)
        XCTAssertFalse(PlaylistMigrationStatus.completed.canTransition(to: .matching))
        XCTAssertFalse(PlaylistMigrationStatus.cancelled.canTransition(to: .preparing))
    }

    func testSessionTransitionAllowsExpectedPath() throws {
        try PlaylistMigrationValidation.requireSessionTransition(.preparing, to: .importingMetadata)
        try PlaylistMigrationValidation.requireSessionTransition(.importingMetadata, to: .metadataReady)
        try PlaylistMigrationValidation.requireSessionTransition(.metadataReady, to: .matching)
        try PlaylistMigrationValidation.requireSessionTransition(.matching, to: .downloading)
        try PlaylistMigrationValidation.requireSessionTransition(.downloading, to: .verifying)
        try PlaylistMigrationValidation.requireSessionTransition(.verifying, to: .completed)
        XCTAssertThrowsError(try PlaylistMigrationValidation.requireSessionTransition(.preparing, to: .completed))
    }

    func testEntryTransitionAllowsReviewAndRetryButRejectsInvalidJump() throws {
        try PlaylistMigrationValidation.requireEntryTransition(.pending, to: .matching)
        try PlaylistMigrationValidation.requireEntryTransition(.matching, to: .needsReview)
        try PlaylistMigrationValidation.requireEntryTransition(.needsReview, to: .matched)
        try PlaylistMigrationValidation.requireEntryTransition(.matched, to: .queued)
        try PlaylistMigrationValidation.requireEntryTransition(.queued, to: .downloading)
        try PlaylistMigrationValidation.requireEntryTransition(.downloading, to: .verifying)
        try PlaylistMigrationValidation.requireEntryTransition(.verifying, to: .ready)
        try PlaylistMigrationValidation.requireEntryTransition(.ready, to: .unavailable)
        XCTAssertThrowsError(try PlaylistMigrationValidation.requireEntryTransition(.pending, to: .downloading))
    }

    func testFiveHundredEntriesWithDuplicateSourceIdsPreserveOccurrences() throws {
        let playlist = snapshot((0..<500).map(entry))
        XCTAssertNoThrow(try PlaylistMigrationValidation.validate(playlist))
        XCTAssertEqual(playlist.entries.count, 500)
        XCTAssertEqual(Set(playlist.entries.map(\.id)).count, 500)
        XCTAssertEqual(Set(playlist.entries.compactMap(\.sourceTrackID)).count, 1)
        XCTAssertEqual(playlist.entries.map(\.position), Array(0..<500))
    }

    func testNonContiguousOrDuplicatePositionsRejected() {
        XCTAssertThrowsError(try PlaylistMigrationValidation.validate(snapshot([entry(0), entry(0)])))
        XCTAssertThrowsError(try PlaylistMigrationValidation.validate(snapshot([entry(0), entry(2)])))
        XCTAssertThrowsError(try PlaylistMigrationValidation.validate(snapshot([entry(-1)])))
    }

    func testDuplicateOccurrenceIdentityRejectedEvenForDifferentPositions() {
        let id = UUID()
        XCTAssertThrowsError(try PlaylistMigrationValidation.validate(snapshot([entry(0, id: id), entry(1, id: id)])))
    }

    func testUnusableMetadataRejected() {
        XCTAssertThrowsError(try PlaylistMigrationValidation.validate(PlaylistMigrationSourcePlaylist(source: .exportify, name: " ", entries: [])))
        XCTAssertThrowsError(try PlaylistMigrationValidation.validate(snapshot([PlaylistMigrationSourceTrack(position: 0, title: " ")])))
        XCTAssertThrowsError(try PlaylistMigrationValidation.validate(snapshot([PlaylistMigrationSourceTrack(position: 0, title: "Song", durationMs: -1)])))
        XCTAssertThrowsError(try PlaylistMigrationValidation.validate(snapshot([PlaylistMigrationSourceTrack(position: 0, title: String(repeating: "x", count: 301))])))
    }

    func testEmptyPlaylistIsValidMetadata() throws {
        XCTAssertNoThrow(try PlaylistMigrationValidation.validate(snapshot([])))
        let p = PlaylistMigrationProgress(expected: 0, states: [], metadataCommitted: true)
        XCTAssertTrue(p.metadataComplete)
        XCTAssertTrue(p.audioComplete)
    }

    func testFingerprintIgnoresCaptureTimeAndOccurrenceUUIDs() throws {
        let first = snapshot([entry(0)], timestamp: Date(timeIntervalSince1970: 1))
        let second = snapshot([entry(0)], timestamp: Date(timeIntervalSince1970: 10_000))
        XCTAssertEqual(try PlaylistMigrationValidation.importFingerprint(for: first),
                       try PlaylistMigrationValidation.importFingerprint(for: second))
    }

    func testFingerprintDetectsTrackOrderOrContentDifferences() throws {
        let a = snapshot([entry(0, sourceID: "a"), entry(1, sourceID: "b")])
        let b = snapshot([entry(0, sourceID: "b"), entry(1, sourceID: "a")])
        XCTAssertNotEqual(try PlaylistMigrationValidation.importFingerprint(for: a),
                          try PlaylistMigrationValidation.importFingerprint(for: b))
    }

    func testProgressDistinguishesMetadataFromPlayableAudio() {
        let states: [PlaylistMigrationEntryStatus] = [.ready, .pending, .needsReview, .unavailable, .failed, .skipped]
        let p = PlaylistMigrationProgress(expected: 6, states: states, metadataCommitted: true)
        XCTAssertTrue(p.metadataComplete)
        XCTAssertFalse(p.audioComplete)
        XCTAssertEqual(p.ready, 1)
        XCTAssertEqual(p.unresolved, 5)
        XCTAssertEqual(p.needsReview, 1)
        XCTAssertEqual(p.pendingOrActive, 1)
        XCTAssertFalse(PlaylistMigrationProgress(expected: 7, states: states, metadataCommitted: true).metadataComplete)
    }

    func testSourcePlaylistCodableRoundTripPreservesDuplicatesAndMetadata() throws {
        let original = snapshot([entry(0), entry(1), entry(2)])
        let decoded = try JSONDecoder().decode(PlaylistMigrationSourcePlaylist.self, from: JSONEncoder().encode(original))
        XCTAssertEqual(decoded, original)
        XCTAssertEqual(decoded.entries.map(\.position), [0, 1, 2])
    }
}
