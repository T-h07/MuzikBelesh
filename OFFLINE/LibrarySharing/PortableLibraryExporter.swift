import Foundation
import GRDB

enum LibraryExportScope: Equatable, Hashable, Sendable {
    case playlist(String)
    case playlists([String])
    case library
}

struct PortableExportPlaylistSummary: Identifiable, Equatable, Sendable {
    let id: String
    let name: String
    let description: String?
    let occurrences: Int
    let songs: Int
}

/// A validated, encoded document ready to be written.
struct PortableLibraryExportPlan: Sendable {
    let document: PortableLibraryDocument
    let data: Data
    let summary: PortableLibrarySummary
    let playlists: [PortableExportPlaylistSummary]
    let suggestedFilename: String
}

/// Reads one consistent GRDB snapshot and converts it into portable DTOs.
///
/// Visible order is reproduced exactly as the playlist screen presents and plays it:
/// * ordinary playlists — `playlist_tracks` by position, then pending YouTube-link entries
///   in submission order;
/// * imported (migration-managed) playlists — source occurrences by source position with
///   removed occurrences excluded (never resurrected), then manually added occurrences by
///   position, then pending YouTube-link entries in submission order.
/// Each visible row is one portable occurrence, so repeated songs stay repeated.
///
/// Privacy: only the allowlisted fields below are read into the document. Profile, listening,
/// playback, queue, theme, preference, liked-song, download-job, path and database-identity
/// data are never selected.
struct PortableLibraryExporter: Sendable {
    let db: DatabaseQueue
    var appVersion: String? = nil
    var now: @Sendable () -> Date = { Date() }

    func plan(_ scope: LibraryExportScope) async throws -> PortableLibraryExportPlan {
        let snapshot = try await db.read { db in try Snapshot.read(db, scope: scope) }
        try Task.checkCancellation()
        return try build(snapshot, scope: scope)
    }

    // MARK: Snapshot

    private struct VisibleOccurrence { let song: SongSource }
    private enum SongSource {
        case track(String)
        case placeholder(PlaylistMigrationSourceTrack, recordings: [String])
        case link(videoID: String, title: String?)
    }
    private struct PlaylistSnapshot { let playlist: StoredPlaylist; let occurrences: [VisibleOccurrence] }

    private struct Snapshot {
        var playlists: [PlaylistSnapshot] = []
        var libraryTrackIDs: [String] = []
        var tracks: [String: StoredTrack] = [:]
        var artists: [String: String] = [:]
        var albums: [String: StoredAlbum] = [:]
        var trackRecordings: [String: [String]] = [:]

        static func read(_ db: Database, scope: LibraryExportScope) throws -> Snapshot {
            var result = Snapshot()
            let all = try StoredPlaylist.order(Column("dateAdded"), Column("id")).fetchAll(db)
            let chosen: [StoredPlaylist]
            switch scope {
            case .library: chosen = all
            case .playlist(let id):
                guard let playlist = all.first(where: { $0.id == id }) else { throw LibraryError.notFound }
                chosen = [playlist]
            case .playlists(let ids):
                let wanted = Set(ids)
                chosen = all.filter { wanted.contains($0.id) }
                guard chosen.count == wanted.count else { throw LibraryError.notFound }
            }
            let tracks = try StoredTrack.order(Column("dateAdded"), Column("id")).fetchAll(db)
            result.tracks = Dictionary(uniqueKeysWithValues: tracks.map { ($0.id, $0) })
            if scope == .library { result.libraryTrackIDs = tracks.map(\.id) }
            result.artists = Dictionary(uniqueKeysWithValues: try StoredArtist.fetchAll(db).map { ($0.id, $0.name) })
            result.albums = Dictionary(uniqueKeysWithValues: try StoredAlbum.fetchAll(db).map { ($0.id, $0) })
            for row in try Row.fetchAll(db, sql: """
                SELECT trackID, sourceIdentifier FROM track_sources
                WHERE sourceType = 'youtube' AND sourceIdentifier IS NOT NULL ORDER BY dateRecorded, id
                """) {
                let trackID: String = row["trackID"], video: String = row["sourceIdentifier"]
                guard YouTubeURLValidator.isValidID(video), !(result.trackRecordings[trackID]?.contains(video) ?? false) else { continue }
                result.trackRecordings[trackID, default: []].append(video)
            }
            let jobTitles = Dictionary(try Row.fetchAll(db, sql: """
                SELECT sourceIdentifier, title FROM download_jobs WHERE sourceType = 'youtube' AND sourceIdentifier IS NOT NULL AND title IS NOT NULL
                ORDER BY dateAdded
                """).map { ($0["sourceIdentifier"] as String, $0["title"] as String) }, uniquingKeysWith: { first, _ in first })
            for playlist in chosen {
                try Task.checkCancellation()
                var occurrences: [VisibleOccurrence] = []
                if let session = try MigrationSessionRecord.fetchOne(db, sql: "SELECT * FROM playlist_migrations WHERE destinationPlaylistID = ?", arguments: [playlist.id]) {
                    let entries = try GRDBPlaylistMigrationRepository.entries(db, migrationID: session.id)
                    let accepted = try acceptedYouTube(db, migrationID: session.id)
                    let stored = try storedReferences(db, migrationID: session.id)
                    for entry in entries {
                        let key = entry.id.uuidString
                        if entry.status == .ready, let trackID = entry.localTrackID, result.tracks[trackID] != nil {
                            occurrences.append(VisibleOccurrence(song: .track(trackID)))
                        } else {
                            var recordings: [String] = []
                            for id in [accepted[key]].compactMap({ $0 }) + (stored[key] ?? []) where !recordings.contains(id) { recordings.append(id) }
                            occurrences.append(VisibleOccurrence(song: .placeholder(entry.source, recordings: recordings)))
                        }
                    }
                    for occurrence in try LocalPlaylistOccurrence.filter(Column("playlistID") == playlist.id).order(Column("position"), Column("id")).fetchAll(db)
                    where result.tracks[occurrence.trackID] != nil {
                        occurrences.append(VisibleOccurrence(song: .track(occurrence.trackID)))
                    }
                } else {
                    for trackID in try String.fetchAll(db, sql: "SELECT trackID FROM playlist_tracks WHERE playlistID = ? ORDER BY position, trackID", arguments: [playlist.id])
                    where result.tracks[trackID] != nil {
                        occurrences.append(VisibleOccurrence(song: .track(trackID)))
                    }
                }
                for link in try LibraryRepository.pendingLinks(db, playlistID: playlist.id) where YouTubeURLValidator.isValidID(link.videoID) {
                    occurrences.append(VisibleOccurrence(song: .link(videoID: link.videoID, title: jobTitles[link.videoID])))
                }
                result.playlists.append(PlaylistSnapshot(playlist: playlist, occurrences: occurrences))
            }
            return result
        }

        /// Only confirmed decisions: an accepted YouTube candidate. Pending proposals and
        /// unverified search results are never exported as the user's recording.
        private static func acceptedYouTube(_ db: Database, migrationID: String) throws -> [String: String] {
            var result: [String: String] = [:]
            for row in try Row.fetchAll(db, sql: """
                SELECT c.entryID, c.providerTrackID FROM migration_candidates c JOIN migration_entries e ON e.id = c.entryID
                WHERE e.migrationID = ? AND c.decision = 'accepted' AND c.provider = 'youtube' AND c.providerTrackID IS NOT NULL
                """, arguments: [migrationID]) {
                let video: String = row["providerTrackID"]
                if YouTubeURLValidator.isValidID(video) { result[row["entryID"] as String] = video }
            }
            return result
        }

        /// References received in an earlier `.mbelesh` import travel on when re-shared.
        private static func storedReferences(_ db: Database, migrationID: String) throws -> [String: [String]] {
            Dictionary(try PortableLibraryEntryRecord.filter(Column("migrationID") == migrationID).fetchAll(db).map { ($0.entryID, $0.videoIDs) },
                       uniquingKeysWith: { first, _ in first })
        }
    }

    // MARK: Conversion

    private func build(_ snapshot: Snapshot, scope: LibraryExportScope) throws -> PortableLibraryExportPlan {
        var songs: [PortableSong] = []
        var songIDs: [String: String] = [:]
        func songID(for source: SongSource) -> String {
            let key: String
            let song: PortableSong
            switch source {
            case .track(let id):
                key = "t:" + id
                if let existing = songIDs[key] { return existing }
                song = trackSong(id, snapshot: snapshot)
            case .placeholder(let entry, let recordings):
                let identity = PortableFingerprint.key(title: entry.title, artist: entry.primaryArtist, additionalArtists: entry.additionalArtists,
                                                      album: entry.album, durationMs: entry.durationMs)
                key = "p:" + [identity.title, identity.artists.joined(separator: "\u{1f}"), identity.album,
                              identity.durationMs.map(String.init) ?? "", recordings.joined(separator: ",")].joined(separator: "\u{1e}")
                if let existing = songIDs[key] { return existing }
                let extra = Array(entry.additionalArtists.compactMap { Self.clean($0, PortableLibraryLimits.artistLength) }.prefix(PortableLibraryLimits.additionalArtists))
                song = PortableSong(id: "", title: Self.clean(entry.title, PortableLibraryLimits.titleLength) ?? "Unknown song",
                                    artist: Self.clean(entry.primaryArtist, PortableLibraryLimits.artistLength),
                                    additionalArtists: extra.isEmpty ? nil : extra,
                                    album: Self.clean(entry.album, PortableLibraryLimits.albumLength).map { PortableAlbum(title: $0) },
                                    durationMs: entry.durationMs.flatMap { $0 >= 0 && $0 <= PortableLibraryLimits.maximumDurationMs ? $0 : nil },
                                    recordings: Self.references(recordings))
            case .link(let video, let title):
                key = "y:" + video
                if let existing = songIDs[key] { return existing }
                song = PortableSong(id: "", title: Self.clean(title, PortableLibraryLimits.titleLength), recordings: Self.references([video]))
            }
            var value = song
            value.id = "s\(songs.count + 1)"
            songs.append(value)
            songIDs[key] = value.id
            return value.id
        }
        if scope == .library {
            for id in snapshot.libraryTrackIDs { _ = songID(for: .track(id)) }
        }
        var playlists: [PortablePlaylist] = []
        var summaries: [PortableExportPlaylistSummary] = []
        var occurrenceNumber = 0
        for item in snapshot.playlists {
            var occurrences: [PortablePlaylistOccurrence] = []
            for (position, occurrence) in item.occurrences.enumerated() {
                occurrenceNumber += 1
                occurrences.append(PortablePlaylistOccurrence(id: "o\(occurrenceNumber)", position: position, songRef: songID(for: occurrence.song)))
            }
            let description = item.playlist.description.flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 }
            let playlist = PortablePlaylist(id: "p\(playlists.count + 1)", name: item.playlist.name, description: description, occurrences: occurrences)
            playlists.append(playlist)
            summaries.append(PortableExportPlaylistSummary(id: item.playlist.id, name: item.playlist.name, description: description,
                                                           occurrences: occurrences.count, songs: Set(occurrences.map(\.songRef)).count))
        }
        guard !songs.isEmpty || !playlists.isEmpty else { throw PortableLibraryError.nothingToExport }
        let kind: PortableExportScopeKind
        switch scope { case .playlist: kind = .playlist; case .playlists: kind = .playlists; case .library: kind = .library }
        let stamp = ISO8601DateFormatter()
        stamp.formatOptions = [.withInternetDateTime]
        let document = PortableLibraryDocument(format: PortableLibraryDocument.format, schemaVersion: PortableLibraryDocument.currentSchemaVersion,
            requiredFeatures: nil, exportId: UUID().uuidString, createdAt: stamp.string(from: now()),
            generator: PortableGenerator(app: "Muzik Belesh", version: appVersion), scope: kind,
            collection: PortableCollection(songs: songs, playlists: playlists))
        // The exact importer contract is enforced on our own output before anything is written.
        let validated = try PortableLibraryValidator.validated(document)
        try Task.checkCancellation()
        let data = try PortableLibraryCodec.encode(validated)
        guard data.count <= PortableLibraryLimits.inputBytes else { throw PortableLibraryError.limitExceeded("the file would exceed 32 MB; export fewer playlists") }
        let filename: String
        switch scope {
        case .playlist: filename = Self.filename(playlists.first?.name ?? "Playlist")
        case .playlists: filename = playlists.count == 1 ? Self.filename(playlists[0].name) : "Muzik-Belesh-Playlists.mbelesh"
        case .library: filename = "My-Music-Library.mbelesh"
        }
        return PortableLibraryExportPlan(document: validated, data: data, summary: PortableLibrarySummary(validated, encodedBytes: data.count),
                                         playlists: summaries, suggestedFilename: filename)
    }

    private func trackSong(_ id: String, snapshot: Snapshot) -> PortableSong {
        guard let track = snapshot.tracks[id] else { return PortableSong(id: "", title: "Unknown song") }
        var album: PortableAlbum?
        if let albumID = track.albumID, let stored = snapshot.albums[albumID], let title = Self.clean(stored.title, PortableLibraryLimits.albumLength) {
            let albumArtist = stored.artistID.flatMap { snapshot.artists[$0] } ?? track.albumArtist
            album = PortableAlbum(title: title, artist: Self.clean(albumArtist, PortableLibraryLimits.artistLength),
                                  releaseYear: stored.releaseYear.flatMap { (1000...3000).contains($0) ? $0 : nil },
                                  position: track.albumPosition.flatMap { (0...9_999).contains($0) ? $0 : nil })
        }
        let duration = track.durationMs.flatMap { $0 >= 0 && $0 <= PortableLibraryLimits.maximumDurationMs ? $0 : nil }
        return PortableSong(id: "", title: Self.clean(track.title, PortableLibraryLimits.titleLength) ?? "Unknown song",
                            artist: Self.clean(track.artistID.flatMap { snapshot.artists[$0] }, PortableLibraryLimits.artistLength),
                            additionalArtists: nil, album: album, durationMs: duration,
                            recordings: Self.references(snapshot.trackRecordings[id] ?? []))
    }

    /// Replaces control characters, trims, applies NFC and clamps to the documented limit.
    static func clean(_ value: String?, _ limit: Int) -> String? {
        guard let value else { return nil }
        var scalars = String.UnicodeScalarView()
        for scalar in value.unicodeScalars { scalars.append(CharacterSet.controlCharacters.contains(scalar) ? " " : scalar) }
        let text = String(scalars).trimmingCharacters(in: .whitespacesAndNewlines).precomposedStringWithCanonicalMapping
        let clamped = String(text.prefix(limit)).trimmingCharacters(in: .whitespacesAndNewlines)
        return clamped.isEmpty ? nil : clamped
    }

    private static func references(_ ids: [String]) -> [PortableRecordingReference]? {
        var seen = Set<String>()
        let values = ids.filter { YouTubeURLValidator.isValidID($0) && seen.insert($0).inserted }.prefix(PortableLibraryLimits.recordingsPerSong)
            .map { PortableRecordingReference(provider: PortableRecordingReference.youtube, videoId: $0) }
        return values.isEmpty ? nil : Array(values)
    }

    /// Letters, digits, `-` and `_` only; spaces become `-`. Never a path.
    static func filename(_ name: String) -> String {
        let mapped = name.unicodeScalars.map { scalar -> Character in
            if CharacterSet.alphanumerics.contains(scalar) || scalar == "-" || scalar == "_" { return Character(scalar) }
            return "-"
        }
        var value = String(mapped)
        while value.contains("--") { value = value.replacingOccurrences(of: "--", with: "-") }
        value = value.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        value = String(value.prefix(60))
        return (value.isEmpty ? "Muzik-Belesh-Playlist" : value) + ".mbelesh"
    }
}

/// A published `.mbelesh` file in a private export directory. The directory is removed when
/// the share/export UI releases it, and abandoned ones are removed at the next launch
/// (`PreparedAudioExport.cleanupAbandoned` owns the `Export-<UUID>` naming).
final class PreparedLibraryShare: Identifiable, @unchecked Sendable {
    let id = UUID()
    let url: URL
    let summary: PortableLibrarySummary
    private let directory: URL
    init(directory: URL, url: URL, summary: PortableLibrarySummary) { self.directory = directory; self.url = url; self.summary = summary }
    deinit { try? FileManager.default.removeItem(at: directory) }

    /// Atomic publication: the bytes go to a temporary file in the same private directory and
    /// are renamed into place, so a partially written `.mbelesh` is never visible.
    static func write(_ plan: PortableLibraryExportPlan, exports: URL) throws -> PreparedLibraryShare {
        try Task.checkCancellation()
        let directory = exports.appendingPathComponent("Export-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let url = directory.appendingPathComponent(plan.suggestedFilename)
        do {
            try plan.data.write(to: url, options: [.atomic])
            try Task.checkCancellation()
        } catch {
            try? FileManager.default.removeItem(at: directory)
            if error is CancellationError { throw error }
            throw PortableLibraryError.writeFailed
        }
        return PreparedLibraryShare(directory: directory, url: url, summary: plan.summary)
    }
}
