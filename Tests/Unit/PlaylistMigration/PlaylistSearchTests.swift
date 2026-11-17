import Foundation
import GRDB
import XCTest
@testable import OFFLINE

/// Playlist search is a filtered *view*: tapping a result plays that exact occurrence and
/// then continues through the full playlist with the active shuffle/repeat settings.
@MainActor final class PlaylistSearchTests: XCTestCase {
    private let letters = ["A", "B", "C", "D", "E", "F", "G"]

    /// An imported playlist "Song A" … "Song G" whose occurrences all play distinct audio,
    /// except the given duplicates (title and recording of an earlier occurrence).
    private func imported(_ f: LibraryFixture, name: String = "Search", titles: [String]? = nil, recordings: [Int]? = nil,
                          artists: [String]? = nil, unresolved: Set<Int> = []) async throws -> (session: PlaylistMigrationSession, entries: [PlaylistMigrationEntry], playlistID: String) {
        let names = titles ?? letters.map { "Song " + $0 }
        let source = PlaylistMigrationSourcePlaylist(source: .exportify, name: name, entries: names.enumerated().map { index, title in
            PlaylistMigrationSourceTrack(position: index, title: title, primaryArtist: artists?[index] ?? "Artist \(index)", durationMs: 2000)
        })
        let repo = f.storage.playlistMigrations
        let session = try await repo.createPlaylist(from: source, operationID: name + UUID().uuidString)
        let entries = try await repo.entries(migrationID: session.id)
        for (index, entry) in entries.enumerated() where !unresolved.contains(index) {
            try await repo.associateVerifiedTrack(entryID: entry.id, trackID: f.ids[recordings?[index] ?? index])
        }
        return (session, entries, try XCTUnwrap(session.destinationPlaylistID))
    }
    private func search(_ f: LibraryFixture, _ playlistID: String, _ query: String) throws -> [MigrationPlaylistRow] {
        PlaylistSearch.filter(try f.storage.playlistMigrations.rows(playlistID: playlistID), query: query) {
            [$0.entry.source.title, $0.entry.source.primaryArtist]
        }
    }

    // S01, S12 (imported and ordinary playlists)
    func testSearchOnlyCoversTheOpenPlaylist() async throws {
        let f = try LibraryFixture(count: 7)
        let a = try await imported(f, name: "A")
        _ = try await imported(f, name: "B", titles: ["Song D (other playlist)", "Song Z"], recordings: [0, 1])
        let results = try search(f, a.playlistID, "song d")
        XCTAssertEqual(results.map(\.id), [a.entries[3].id], "Only this playlist's matching occurrence")
        // Ordinary playlist: the same filter over its own songs.
        let ordinary = try f.repository.createPlaylist(name: "Manual")
        try f.repository.addTracks([f.ids[1], f.ids[4]], playlistID: ordinary.id)
        let tracks = try f.repository.snapshot().playlistTracks(ordinary.id)
        XCTAssertEqual(PlaylistSearch.filter(tracks, query: "song 4") { [$0.title] }.map(\.id), [f.ids[4]])
    }

    // S02
    func testMatchesTitlesAndArtistsIgnoringCaseAndAccents() {
        let fields: [String?] = ["Ëndrra e Bardhë", "LumiB ft Mc Kresha"]
        for query in ["endrra", "ËNDRRA", "bardhe", "lumib", "mc kresha", "KRESHA endrra"] {
            XCTAssertTrue(PlaylistSearch.matches(fields, terms: PlaylistSearch.terms(query)), query)
        }
        XCTAssertFalse(PlaylistSearch.matches(fields, terms: PlaylistSearch.terms("unrelated")))
        XCTAssertFalse(PlaylistSearch.matches(fields, terms: PlaylistSearch.terms("endrra unrelated")), "Every word must match")
    }

    // S03, S04
    func testClearingRestoresEverythingAndOrderIsNeverChanged() async throws {
        let f = try LibraryFixture(count: 7)
        let p = try await imported(f)
        let before = try f.storage.playlistMigrations.rows(playlistID: p.playlistID).map(\.id)
        let filtered = try search(f, p.playlistID, "song")
        XCTAssertEqual(filtered.map(\.id), before, "Matching rows keep the playlist's own order")
        for query in ["", "   ", "\n"] { XCTAssertEqual(try search(f, p.playlistID, query).map(\.id), before) }
        _ = try search(f, p.playlistID, "song e")
        let after = try f.storage.playlistMigrations.rows(playlistID: p.playlistID).map(\.id)
        XCTAssertEqual(after, before, "Searching never changes membership or order")
        XCTAssertEqual(try f.storage.playlistMigrations.hybridPlaybackOccurrences(playlistID: p.playlistID).count, 7)
    }

    // S05, S06, S10, S11 (shuffle off)
    func testTappingAFilteredResultPlaysItThenTheRestOfTheFullPlaylist() async throws {
        let f = try LibraryFixture(count: 7)
        let p = try await imported(f)
        let (player, transport, library) = f.services()
        XCTAssertFalse(player.queue.shuffleEnabled)
        let result = try XCTUnwrap(try search(f, p.playlistID, "Song D").first)
        await library.playMigration(playlistID: p.playlistID, occurrenceID: result.id.uuidString)
        XCTAssertEqual(player.queue.currentOccurrenceID, p.entries[3].id.uuidString, "The tapped occurrence plays")
        XCTAssertEqual(player.state.currentTrackID, f.ids[3])
        XCTAssertFalse(player.queue.shuffleEnabled, "Selecting a song never changes the shuffle setting")
        // Changing or clearing the search afterwards is a view change only.
        let replacements = transport.replacements
        for query in ["song e", "", "zzz"] { _ = try search(f, p.playlistID, query) }
        XCTAssertEqual(transport.replacements, replacements); XCTAssertEqual(player.queue.currentOccurrenceID, p.entries[3].id.uuidString)
        // Songs E, F and G play next even though the search showed only Song D.
        for index in 4...6 {
            await player.next()
            XCTAssertEqual(player.queue.currentOccurrenceID, p.entries[index].id.uuidString)
        }
        await player.previous()
        XCTAssertEqual(player.queue.currentOccurrenceID, p.entries[5].id.uuidString, "Previous follows the full playlist")
        await player.next(); await player.next()
        XCTAssertEqual(player.queue.repeatMode, .all)
        XCTAssertEqual(player.queue.currentOccurrenceID, p.entries[0].id.uuidString, "Repeat wraps to the start of the full playlist")
        player.pause()
    }

    // S07 (shuffle on)
    func testShuffleDrawsFromTheWholePlaylistAndStaysOn() async throws {
        let f = try LibraryFixture(count: 7)
        let p = try await imported(f)
        let (player, _, library) = f.services()
        player.queue.toggleShuffle()
        XCTAssertTrue(player.queue.shuffleEnabled)
        let result = try XCTUnwrap(try search(f, p.playlistID, "song d").first)
        await library.playMigration(playlistID: p.playlistID, occurrenceID: result.id.uuidString)
        XCTAssertEqual(player.queue.currentOccurrenceID, p.entries[3].id.uuidString, "The selected song plays first")
        XCTAssertTrue(player.queue.shuffleEnabled, "Shuffle stays on: selecting a song never turns it off")
        var visited: [String] = []
        for _ in 0..<6 {
            await player.next()
            visited.append(try XCTUnwrap(player.queue.currentOccurrenceID))
        }
        let others = Set(p.entries.enumerated().filter { $0.offset != 3 }.map { $0.element.id.uuidString })
        XCTAssertEqual(Set(visited), others, "The shuffle cycle covers the full playlist, not the search results")
        XCTAssertEqual(visited.count, Set(visited).count, "No occurrence repeats within the cycle")
        player.pause()
    }

    // S08
    func testDuplicateOccurrencesResolveToTheTappedPosition() async throws {
        let f = try LibraryFixture(count: 7)
        let titles = ["Song A", "Song X", "Song Y", "Song Z", "Song W", "Song A", "Song V"]
        // Search matches substrings of titles *and* artists; the default "Artist N" names all
        // contain "a", so this fixture uses artist names without that letter.
        let p = try await imported(f, titles: titles, recordings: [0, 1, 2, 3, 4, 0, 6], artists: (0..<7).map { "Performer \($0)" })
        let (player, _, library) = f.services()
        let results = try search(f, p.playlistID, "song a")
        XCTAssertEqual(results.map(\.entry.position), [0, 5], "Both occurrences are listed separately")
        await library.playMigration(playlistID: p.playlistID, occurrenceID: results[1].id.uuidString)
        XCTAssertEqual(player.queue.currentOccurrenceID, p.entries[5].id.uuidString, "Position 6 plays, not the first match")
        await player.next()
        XCTAssertEqual(player.queue.currentOccurrenceID, p.entries[6].id.uuidString, "Playback continues after the tapped position")
        player.pause()
    }

    // S09
    func testUnresolvedResultsAreShownButNeverEnterTheQueue() async throws {
        let f = try LibraryFixture(count: 7)
        let p = try await imported(f, unresolved: [2])
        let (player, transport, library) = f.services()
        let results = try search(f, p.playlistID, "song c")
        XCTAssertEqual(results.map(\.id), [p.entries[2].id], "Unresolved songs can be found")
        XCTAssertNil(results.first?.playableTrack)
        let occurrences = try f.storage.playlistMigrations.hybridPlaybackOccurrences(playlistID: p.playlistID)
        XCTAssertFalse(occurrences.contains { $0.id == p.entries[2].id.uuidString }, "Unplayable entries are not in the queue")
        await library.playMigration(playlistID: p.playlistID, occurrenceID: p.entries[1].id.uuidString)
        let replacements = transport.replacements
        // Selecting an unresolved occurrence never changes what is playing.
        await library.playMigration(playlistID: p.playlistID, occurrenceID: p.entries[2].id.uuidString)
        XCTAssertEqual(player.queue.currentOccurrenceID, p.entries[1].id.uuidString)
        XCTAssertEqual(transport.replacements, replacements)
        await player.next()
        XCTAssertEqual(player.queue.currentOccurrenceID, p.entries[3].id.uuidString, "The unplayable entry is skipped")
        player.pause()
    }

    // S12 (ordinary playlist playback context)
    func testManualPlaylistResultPlaysThroughTheFullPlaylist() async throws {
        let f = try LibraryFixture(count: 5)
        let playlist = try f.repository.createPlaylist(name: "Manual")
        try f.repository.addTracks(f.ids, playlistID: playlist.id)
        let (player, _, library) = f.services()
        let songs = try f.repository.snapshot().playlistTracks(playlist.id)
        let hit = try XCTUnwrap(PlaylistSearch.filter(songs, query: "song 2") { [$0.title] }.first)
        // Exactly what the playlist row does: the full playlist is the context.
        await library.play(hit.id, ids: songs.map(\.id), kind: "playlist", sourceID: playlist.id)
        XCTAssertEqual(player.state.currentTrackID, f.ids[2])
        await player.next(); XCTAssertEqual(player.state.currentTrackID, f.ids[3])
        await player.next(); XCTAssertEqual(player.state.currentTrackID, f.ids[4])
        player.pause()
    }

    // S13
    func testFilteringAThousandOccurrencesStaysFast() {
        let rows = (0..<1000).map { (id: UUID(), title: "Kënga \($0)", artist: $0 % 3 == 0 ? "Artisti Ë" : "Artist \($0)") }
        let started = Date()
        var total = 0
        for query in ["k", "kë", "ken", "kenga", "kenga 9", "kenga 99", "artisti", "artisti e", "", "zzz"] {
            total += PlaylistSearch.filter(rows, query: query) { [$0.title, $0.artist] }.count
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), 2, "Ten keystrokes over 1,000 songs")
        XCTAssertEqual(PlaylistSearch.filter(rows, query: "kenga 999") { [$0.title, $0.artist] }.map(\.title), ["Kënga 999"])
        XCTAssertGreaterThan(total, 0)
    }
}
