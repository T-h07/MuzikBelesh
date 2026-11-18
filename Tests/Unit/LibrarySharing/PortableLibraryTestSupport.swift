import Foundation
import GRDB
import XCTest
@testable import OFFLINE

enum PortableFixtures {
    static let videoA = "dQw4w9WgXcQ"
    static let videoB = "9bZkp7q19f0"

    static func song(_ id: String, _ title: String?, artist: String? = "Artist", duration: Int64? = 200_000, videos: [String] = []) -> PortableSong {
        PortableSong(id: id, title: title, artist: artist, additionalArtists: nil, album: nil, durationMs: duration,
                     recordings: videos.isEmpty ? nil : videos.map { PortableRecordingReference(provider: "youtube", videoId: $0) })
    }

    static func playlist(_ id: String, _ name: String, _ refs: [String], prefix: String? = nil) -> PortablePlaylist {
        PortablePlaylist(id: id, name: name, description: nil,
                         occurrences: refs.enumerated().map { PortablePlaylistOccurrence(id: (prefix ?? id) + "-o\($0.offset)", position: $0.offset, songRef: $0.element) })
    }

    static func document(songs: [PortableSong], playlists: [PortablePlaylist], scope: PortableExportScopeKind = .library) -> PortableLibraryDocument {
        PortableLibraryDocument(format: PortableLibraryDocument.format, schemaVersion: 1, requiredFeatures: nil,
                                exportId: UUID().uuidString, createdAt: "2026-11-17T00:00:00Z",
                                generator: PortableGenerator(app: "Muzik Belesh", version: "test"), scope: scope,
                                collection: PortableCollection(songs: songs, playlists: playlists))
    }

    static func data(_ document: PortableLibraryDocument) throws -> Data { try PortableLibraryCodec.encode(document) }

    static func json(_ text: String) -> Data { Data(text.utf8) }

    /// A minimal valid JSON document as text, for byte-level negative tests.
    static func minimalJSON(extra: String = "", schemaVersion: Int = 1, format: String = "muzik-belesh-library") -> String {
        """
        {"format":"\(format)","schemaVersion":\(schemaVersion),"exportId":"\(UUID().uuidString)","scope":"library"\(extra),
         "collection":{"songs":[{"id":"s1","title":"One","artist":"A"}],"playlists":[{"id":"p1","name":"Mix","occurrences":[{"id":"o1","position":0,"songRef":"s1"}]}]}}
        """
    }

    static func preview(_ fixture: LibraryFixture, _ document: PortableLibraryDocument, name: String = "Shared") async throws -> PortableImportPreview {
        try await PortableLibraryImportPlanner(db: fixture.storage.database.dbQueue).preview(data: try data(document), documentName: name)
    }

    static func addSource(_ fixture: LibraryFixture, trackID: String, video: String) throws {
        try fixture.storage.database.dbQueue.write { db in
            try StoredTrackSource(id: UUID().uuidString, trackID: trackID, sourceType: "youtube", sourceIdentifier: video,
                                  canonicalURL: "https://www.youtube.com/watch?v=" + video, dateRecorded: Date()).insert(db)
        }
    }

    static func setArtist(_ fixture: LibraryFixture, trackID: String, name: String) throws {
        try fixture.storage.database.dbQueue.write { db in
            let id = "artist-" + UUID().uuidString
            try StoredArtist(id: id, name: name, normalizedName: LibraryIdentity.search(name), artworkRelativePath: nil, dateAdded: Date(), dateModified: Date()).insert(db)
            try db.execute(sql: "UPDATE tracks SET artistID = ? WHERE id = ?", arguments: [id, trackID])
        }
    }

    static func entries(_ fixture: LibraryFixture, importID: String) throws -> [(entry: PlaylistMigrationEntry, record: PortableLibraryEntryRecord)] {
        try fixture.storage.database.dbQueue.read { db in
            let records = try PortableLibraryEntryRecord.filter(Column("importID") == importID).fetchAll(db)
            let byID = Dictionary(uniqueKeysWithValues: records.map { ($0.entryID, $0) })
            var result: [(PlaylistMigrationEntry, PortableLibraryEntryRecord)] = []
            for migration in Set(records.map(\.migrationID)).sorted() {
                for entry in try GRDBPlaylistMigrationRepository.entries(db, migrationID: migration) {
                    if let record = byID[entry.id.uuidString] { result.append((entry, record)) }
                }
            }
            return result
        }
    }

    static func candidates(_ fixture: LibraryFixture, entryID: UUID) async throws -> [PlaylistMigrationCandidate] {
        try await fixture.storage.playlistMigrations.candidates(entryID: entryID)
    }

    /// Every key path present in a JSON value (object keys only; array indices collapsed).
    static func keys(_ value: Any, path: String = "") -> Set<String> {
        var result = Set<String>()
        if let object = value as? [String: Any] {
            for (key, child) in object {
                let next = path.isEmpty ? key : path + "." + key
                result.insert(next)
                result.formUnion(keys(child, path: next))
            }
        } else if let array = value as? [Any] {
            for child in array { result.formUnion(keys(child, path: path + "[]")) }
        }
        return result
    }
}

/// Deterministic, offline metadata provider; counts requests.
final class PortableStubMetadata: YouTubeMetadataProvider, @unchecked Sendable {
    private let lock = NSLock()
    private var videos: [String: YouTubeVideo]
    private(set) var requests: [String] = []
    init(_ videos: [YouTubeVideo]) { self.videos = Dictionary(uniqueKeysWithValues: videos.map { ($0.id, $0) }) }
    func metadata(videoID: String) async throws -> YouTubeVideo {
        lock.lock(); requests.append(videoID); let video = videos[videoID]; lock.unlock()
        guard let video else { throw YouTubeError.videoUnavailable }
        return video
    }
    var requestCount: Int { lock.lock(); defer { lock.unlock() }; return requests.count }
}
