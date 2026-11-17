import CryptoKit
import Foundation
import UniformTypeIdentifiers

/// Phase 11.4 portable Muzik Belesh library document (`.mbelesh`), schema version 1.
///
/// The document carries music metadata, playlist structure and validated public recording
/// references only. It never carries audio, local paths, database identifiers, profile,
/// listening, theme, preference or device data: every field below is an explicit allowlist
/// entry and the exporter builds these DTOs field by field (never by serializing models).
///
/// Identity layers (all distinct):
/// * `exportId` — this document instance (random per export; never used for duplicates).
/// * `PortableSong.id` — document-scoped song identity (`s1`, `s2`, …).
/// * `PortablePlaylist.id` — document-scoped playlist identity (`p1`, …).
/// * `PortablePlaylistOccurrence.id` — document-scoped identity of one playlist position;
///   two occurrences may reference the same song (repeats are intentional).
/// * `PortableRecordingReference` — reusable public recording identity (YouTube video ID).
/// * The recipient's local track identity is never present; the importer resolves its own.
struct PortableLibraryDocument: Codable, Equatable, Sendable {
    static let format = "muzik-belesh-library"
    static let currentSchemaVersion = 1
    /// Required features understood by this build. A document listing anything else is
    /// structurally incompatible and is refused before any library change.
    static let supportedFeatures: Set<String> = []

    var format: String
    var schemaVersion: Int
    var requiredFeatures: [String]?
    var exportId: String
    var createdAt: String?
    var generator: PortableGenerator?
    var scope: PortableExportScopeKind
    var collection: PortableCollection
}

struct PortableGenerator: Codable, Equatable, Sendable {
    var app: String
    var version: String?
}

enum PortableExportScopeKind: String, Codable, Equatable, Sendable {
    case playlist, playlists, library
}

struct PortableCollection: Codable, Equatable, Sendable {
    var songs: [PortableSong]
    var playlists: [PortablePlaylist]
}

struct PortableSong: Codable, Equatable, Sendable {
    var id: String
    /// Absent only for a pending YouTube addition whose title was never retrieved; such a
    /// song always has a recording reference. Metadata is never invented.
    var title: String?
    var artist: String?
    var additionalArtists: [String]?
    var album: PortableAlbum?
    var durationMs: Int64?
    /// Ordered alternatives for the same song, preferred first. Never several downloads.
    var recordings: [PortableRecordingReference]?
}

struct PortableAlbum: Codable, Equatable, Sendable {
    var title: String
    var artist: String?
    var releaseYear: Int?
    /// Zero-based order of this song inside its album, as stored by the sender's library.
    var position: Int?
}

struct PortableRecordingReference: Codable, Equatable, Hashable, Sendable {
    static let youtube = "youtube"
    var provider: String
    var videoId: String
}

struct PortablePlaylist: Codable, Equatable, Sendable {
    var id: String
    var name: String
    var description: String?
    var occurrences: [PortablePlaylistOccurrence]
}

struct PortablePlaylistOccurrence: Codable, Equatable, Sendable {
    var id: String
    var position: Int
    var songRef: String
}

/// Documented limits for the portable format (independent of the Spotify importer's
/// 100-playlist / 20,000-occurrence review limits, which do not apply here).
enum PortableLibraryLimits {
    static let inputBytes = 32 * 1024 * 1024
    static let songs = 25_000
    static let playlists = 1_000
    /// Per playlist: the migration storage contract (`expectedEntryCount <= 10000`).
    static let occurrencesPerPlaylist = PlaylistMigrationValidation.maximumEntries
    static let occurrences = 100_000
    static let recordingsPerSong = 5
    static let additionalArtists = 20
    static let identifierLength = 64
    static let titleLength = 300
    static let artistLength = 300
    static let albumLength = 300
    static let playlistNameLength = 120
    static let descriptionLength = 2_000
    static let requiredFeatures = 16
    static let maximumDurationMs: Int64 = 24 * 60 * 60 * 1000
    static let jsonDepth = 12
}

extension UTType {
    /// Exported by Muzik Belesh (see `project.yml`). Distinct from `public.json` so the
    /// Spotify/Exportify importer and other apps never mistake it for their own files.
    static let muzikBeleshLibrary = UTType(exportedAs: "com.th07.muzikbelesh.library", conformingTo: .data)
}

/// Compact derived counters shared by the export preview, the import preview and tests.
struct PortableLibrarySummary: Equatable, Sendable {
    var songs = 0
    var playlists = 0
    var occurrences = 0
    var songsWithRecordings = 0
    var songsNeedingDiscovery = 0
    var unassignedSongs = 0
    var encodedBytes = 0

    init(_ document: PortableLibraryDocument, encodedBytes: Int = 0) {
        let collection = document.collection
        songs = collection.songs.count
        playlists = collection.playlists.count
        occurrences = collection.playlists.reduce(0) { $0 + $1.occurrences.count }
        songsWithRecordings = collection.songs.filter { !($0.recordings ?? []).isEmpty }.count
        songsNeedingDiscovery = songs - songsWithRecordings
        let referenced = Set(collection.playlists.flatMap { $0.occurrences.map(\.songRef) })
        unassignedSongs = collection.songs.filter { !referenced.contains($0.id) }.count
        self.encodedBytes = encodedBytes
    }
    init() { }
}

/// Canonical content identity of one playlist's ordered occurrences. Independent of the
/// random export ID, playlist name, document-scoped IDs and recording references, so a new
/// export of identical content is still recognized, while a playlist that merely shares a
/// name is not. Repeated occurrences and order are part of the identity.
enum PortableFingerprint {
    struct SongKey: Equatable, Hashable, Sendable {
        let title: String
        let artists: [String]
        let album: String
        let durationMs: Int64?
    }

    static func key(title: String?, artist: String?, additionalArtists: [String], album: String?, durationMs: Int64?) -> SongKey {
        let artists = ([artist].compactMap { $0 } + additionalArtists).map(LibraryIdentity.search).filter { !$0.isEmpty }
        return SongKey(title: LibraryIdentity.search(title ?? ""), artists: artists, album: LibraryIdentity.search(album ?? ""), durationMs: durationMs)
    }

    static func key(_ song: PortableSong) -> SongKey {
        key(title: song.title, artist: song.artist, additionalArtists: song.additionalArtists ?? [], album: song.album?.title, durationMs: song.durationMs)
    }

    static func playlist(_ keys: [SongKey]) -> String {
        var hash = SHA256()
        hash.update(data: Data("muzik-belesh-playlist-content-v1".utf8))
        for key in keys {
            let parts = [key.title, key.artists.joined(separator: "\u{1f}"), key.album, key.durationMs.map(String.init) ?? ""]
            for part in parts { hash.update(data: Data(part.utf8)); hash.update(data: Data([0])) }
            hash.update(data: Data([0x1e]))
        }
        return "mbpc-" + hash.finalize().map { String(format: "%02x", $0) }.joined()
    }

    static func playlist(_ playlist: PortablePlaylist, songs: [String: PortableSong]) -> String {
        Self.playlist(playlist.occurrences.compactMap { songs[$0.songRef].map(key) })
    }
}
