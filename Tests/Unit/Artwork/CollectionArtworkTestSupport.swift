import Foundation
import GRDB
import XCTest
@testable import OFFLINE

/// In-memory global artwork switch; `failing` simulates a preference write failure.
final class MemoryArtworkDefaults: CollectionArtworkDefaultStoring {
    var value: Bool?
    var failing = false
    private(set) var saves = 0
    init(_ value: Bool? = nil) { self.value = value }
    func load() -> Bool? { value }
    func save(_ enabled: Bool) throws {
        struct WriteFailure: Error {}
        if failing { throw WriteFailure() }
        value = enabled; saves += 1
    }
}

/// An injectable clock shared with the service's sleeper closure.
final class ArtworkTestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date
    init(_ date: Date) { current = date }
    var now: Date { lock.withLock { current } }
    func advance(_ seconds: TimeInterval) { lock.withLock { current = current.addingTimeInterval(seconds) } }
    func set(_ date: Date) { lock.withLock { current = date } }
}

/// A sleeper that never returns until cancelled (the rotation task then exits).
let suspendedArtworkSleeper: @Sendable (Duration) async throws -> Void = { _ in
    while true { try await Task.sleep(for: .seconds(3600)) }
}

enum ArtworkTestFiles {
    /// A real JPEG cover plus its managed 256 px thumbnail, like `stageArtwork` writes them.
    static func write(_ name: String, paths: AppStoragePaths, side: Int = 64, thumbnail: Bool = true, original: Bool = true) throws {
        let data = try LibraryFixture.image(png: false, side: side)
        if original { try data.write(to: paths.artworkURL(relativePath: name)) }
        if thumbnail { try ManagedLibraryFiles.imageData(data, pixels: 256).write(to: paths.artworkURL(relativePath: ManagedLibraryFiles.thumbnailName(name))) }
    }
}

extension LibraryFixture {
    /// Synchronous so async tests never pick GRDB's async `write` overload.
    func setTrackArtwork(_ path: String?, _ index: Int) throws {
        try storage.database.dbQueue.write { db in
            try db.execute(sql: "UPDATE tracks SET artworkRelativePath = ? WHERE id = ?", arguments: [path, ids[index]])
        }
    }
    func artworkCount(_ sql: String, _ arguments: StatementArguments = []) throws -> Int {
        try storage.database.dbQueue.read { try Int.fetchOne($0, sql: sql, arguments: arguments) ?? 0 }
    }
    func preferenceRows() throws -> Int { try artworkCount("SELECT COUNT(*) FROM collection_artwork_preferences") }
    func artworkIndex() throws -> [CollectionArtworkIdentity: CollectionArtworkEntry] {
        let snapshot = try repository.snapshot()
        return CollectionArtworkIndexBuilder.build(snapshot: snapshot, artistGroups: snapshot.artistGroups, albumGroups: snapshot.albumGroups)
    }
    @MainActor func artworkService(library: MusicLibraryService, store: MemoryArtworkDefaults = MemoryArtworkDefaults(),
                                   clock: ArtworkTestClock = ArtworkTestClock(Date(timeIntervalSince1970: 1_700_000_000)),
                                   images: ArtworkImagePipeline = ArtworkImagePipeline()) -> CollectionArtworkService {
        CollectionArtworkService(library: library, database: storage.database.dbQueue, paths: paths, store: store, images: images,
                                 clock: { clock.now }, foreground: true, sleep: suspendedArtworkSleeper)
    }
}
