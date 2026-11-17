import CryptoKit
import Foundation
import GRDB
import XCTest
@testable import OFFLINE

/// Phase 10.9 release-candidate integrity helpers.
///
/// `ReleaseIntegritySnapshot` records every user-data table (row count plus a digest of all
/// rows in storage order) and every managed audio/artwork file (relative path → SHA-256).
/// Comparing a snapshot taken before an operation with one taken after proves the operation
/// changed nothing it should not have — stronger than "the app launched" or a visible count.
struct ReleaseIntegritySnapshot: Equatable, CustomStringConvertible {
    struct Table: Equatable { let rows: Int; let digest: String }
    let tables: [String: Table]
    let files: [String: String]

    var description: String {
        tables.keys.sorted().map { "\($0)=\(tables[$0]!.rows)" }.joined(separator: " ") + " files=\(files.count)"
    }
    func rows(_ table: String) -> Int { tables[table]?.rows ?? 0 }

    static func capture(_ queue: DatabaseQueue, paths: AppStoragePaths, excluding: Set<String> = []) throws -> Self {
        let tables = try queue.read { db -> [String: Table] in
            let names = try String.fetchAll(db, sql: """
                SELECT name FROM sqlite_master WHERE type = 'table'
                AND name NOT LIKE 'sqlite_%' AND name <> 'grdb_migrations' ORDER BY name
                """)
            var result: [String: Table] = [:]
            for name in names where !excluding.contains(name) {
                var hash = SHA256(), count = 0
                let rows = try Row.fetchCursor(db, sql: "SELECT * FROM \(name.quotedDatabaseIdentifier) ORDER BY rowid")
                while let row = try rows.next() {
                    count += 1
                    hash.update(data: Data(row.description.utf8)); hash.update(data: Data([0]))
                }
                result[name] = Table(rows: count, digest: hash.finalize().map { String(format: "%02x", $0) }.joined())
            }
            return result
        }
        var files: [String: String] = [:]
        for directory in [paths.music, paths.artwork] {
            guard let enumerator = FileManager.default.enumerator(atPath: directory.path) else { continue }
            for case let relative as String in enumerator {
                let url = directory.appendingPathComponent(relative)
                var isDirectory: ObjCBool = false
                guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), !isDirectory.boolValue else { continue }
                files[directory.lastPathComponent + "/" + relative] = SHA256.hash(data: try Data(contentsOf: url)).map { String(format: "%02x", $0) }.joined()
            }
        }
        return Self(tables: tables, files: files)
    }
}

enum ReleaseImportFixtures {
    static let header = "Track Name,Artist Name(s),Album Name,Track Duration (ms),Track URI\n"

    /// A 22-character Spotify base-62 track ID unique to `index`.
    static func trackID(_ index: Int) -> String { "T" + String(format: "%021d", index) }

    /// Every position is an identifiable, distinct song unless `repeats` maps it to an earlier
    /// position, in which case it is exactly that earlier song again (same title, artist and
    /// Spotify ID) — the duplicate-recording case that must stay a separate occurrence.
    static func csv(_ count: Int, prefix: String = "Track", repeats: [Int: Int] = [:]) -> Data {
        var text = header
        text.reserveCapacity(count * 96)
        for position in 0..<count {
            let song = repeats[position] ?? position
            text += "\(prefix) \(String(format: "%05d", song)),Artist \(song % 37),Album \(song % 11),\(120_000 + song),spotify:track:\(trackID(song))\n"
        }
        return Data(text.utf8)
    }

    static func json(_ count: Int, name: String = "Large JSON Playlist") throws -> Data {
        let items: [[String: Any]] = (0..<count).map { position in
            ["track": ["trackName": "JSON \(String(format: "%05d", position))", "artistName": "Artist \(position % 29)",
                       "albumName": "Album \(position % 7)", "trackUri": "spotify:track:\(trackID(position))"],
             "episode": NSNull(), "localTrack": NSNull(), "addedDate": "2025-01-01"]
        }
        return try JSONSerialization.data(withJSONObject: ["playlists": [["name": name, "lastModifiedDate": "2025-01-01", "items": items]]], options: [.sortedKeys])
    }
}

/// The mandatory occurrence invariant: source entry *i* is persisted as occurrence *i*,
/// every position 0..<n exists once, every occurrence has its own identity, and nothing
/// was silently omitted, reordered, merged or altered.
func assertOccurrenceInvariant(_ entries: [PlaylistMigrationEntry], source: PlaylistMigrationSourcePlaylist,
                               file: StaticString = #filePath, line: UInt = #line) {
    let count = source.entries.count
    XCTAssertEqual(entries.count, count, "Imported count", file: file, line: line)
    XCTAssertEqual(entries.map(\.position), Array(0..<count), "Position set", file: file, line: line)
    XCTAssertEqual(Set(entries.map(\.id)).count, count, "Occurrence identities", file: file, line: line)
    var mismatches = 0
    for (index, entry) in entries.enumerated() where index < count && entry.source != source.entries[index] {
        mismatches += 1
        if mismatches <= 5 { XCTFail("Source entry \(index) is not persisted as occurrence \(index)", file: file, line: line) }
    }
    XCTAssertEqual(mismatches, 0, "Source/occurrence mismatches", file: file, line: line)
}

/// Elapsed wall-clock milliseconds of `work`, for the release report (not a pass/fail gate).
func releaseMeasure<T>(_ work: () async throws -> T) async rethrows -> (T, Int) {
    let start = ContinuousClock.now
    let value = try await work()
    let elapsed = ContinuousClock.now - start
    return (value, Int(elapsed.components.seconds * 1000 + elapsed.components.attoseconds / 1_000_000_000_000_000))
}
