import CoreGraphics
import Foundation
import GRDB
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import OFFLINE

// MARK: - Support

private struct InjectedFault: Error {}

private final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current = Date(timeIntervalSince1970: 1_800_000_000)
    var now: Date { lock.lock(); defer { lock.unlock() }; return current }
    func advance(_ seconds: TimeInterval) { lock.lock(); current += seconds; lock.unlock() }
}

private final class FaultSwitch: @unchecked Sendable {
    private let lock = NSLock()
    private var armed: Set<LocalProfileFault> = []
    func arm(_ fault: LocalProfileFault) { lock.lock(); armed.insert(fault); lock.unlock() }
    func disarm() { lock.lock(); armed.removeAll(); lock.unlock() }
    func check(_ fault: LocalProfileFault) throws {
        lock.lock(); let hit = armed.contains(fault); lock.unlock()
        if hit { throw InjectedFault() }
    }
}

/// Stands in for unreadable storage: every read throws, creation is recorded.
private final class UnreadableProfileStore: LocalProfileStoring, @unchecked Sendable {
    var failing = true
    var createCalls = 0
    let base: LocalProfileRepository
    init(base: LocalProfileRepository) { self.base = base }
    func load() throws -> LocalUserProfile? { if failing { throw DatabaseError(resultCode: .SQLITE_CORRUPT) }; return try base.load() }
    func create(username: String, avatar: PreparedAvatar?) throws -> LocalUserProfile { createCalls += 1; return try base.create(username: username, avatar: avatar) }
    func update(profileID: UUID, username: String, avatar: AvatarChange) throws -> LocalUserProfile { try base.update(profileID: profileID, username: username, avatar: avatar) }
    func removeUnreferencedAvatars() throws { if failing { throw DatabaseError(resultCode: .SQLITE_CORRUPT) }; try base.removeUnreferencedAvatars() }
    func avatarURL(_ relativePath: String, thumbnail: Bool) -> URL? { base.avatarURL(relativePath, thumbnail: thumbnail) }
}

enum ProfileTestImages {
    static func image(width: Int, height: Int, type: UTType = .png) throws -> Data {
        let context = try XCTUnwrap(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                              space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 0.84, green: 0.93, blue: 0.64, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let image = try XCTUnwrap(context.makeImage()), data = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(data, type.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil); XCTAssertTrue(CGImageDestinationFinalize(destination))
        return data as Data
    }
    static func size(_ data: Data) throws -> CGSize {
        let source = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
        let properties = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
        return CGSize(width: (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue ?? 0,
                      height: (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue ?? 0)
    }
    static func avatar() throws -> PreparedAvatar { try ProfileAvatarProcessor.prepare(image(width: 64, height: 64)) }
}

/// Every user table except the profile itself, as sorted row descriptions.
func librarySnapshot(_ db: DatabaseQueue) throws -> [String: [String]] {
    try db.read { db in
        let tables = try String.fetchAll(db, sql: "SELECT name FROM sqlite_master WHERE type = 'table' AND name NOT LIKE 'sqlite_%' AND name NOT IN ('grdb_migrations', 'local_user_profile', 'listening_sessions', 'listening_session_days', 'listening_analytics_state', 'portable_library_imports', 'portable_library_import_items', 'portable_library_entries', 'collection_artwork_preferences') ORDER BY name")
        var result: [String: [String]] = [:]
        for table in tables { result[table] = try Row.fetchAll(db, sql: "SELECT * FROM \"\(table)\"").map(\.description).sorted() }
        return result
    }
}

// Synchronous helpers: inside an async test, an inline `dbQueue.read { }` resolves to
// GRDB's async overload.
func profileRowCount(_ db: DatabaseQueue) throws -> Int {
    try db.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM local_user_profile") ?? 0 }
}
func appliedMigrations(_ db: DatabaseQueue) throws -> [String] {
    try db.read { try String.fetchAll($0, sql: "SELECT identifier FROM grdb_migrations") }
}

// MARK: - Username policy

final class UsernamePolicyTests: XCTestCase {
    private func valid(_ raw: String) -> String? { if case .success(let value) = UsernamePolicy.validate(raw) { return value }; return nil }
    private func violation(_ raw: String) -> UsernamePolicy.Violation? { if case .failure(let value) = UsernamePolicy.validate(raw) { return value }; return nil }

    func testTrimsLeadingAndTrailingWhitespace() {
        XCTAssertEqual(valid("  Taulant  "), "Taulant")
        XCTAssertEqual(valid("\n\tArta Kelmendi \u{00A0}"), "Arta Kelmendi")
        XCTAssertEqual(valid("Inner  spaces kept"), "Inner  spaces kept")
    }

    func testAcceptsOrdinaryUnicodeNames() {
        for name in ["José", "Ëndrit", "Çlirim", "日本語の名前", "Мария", "محمد", "👨‍👩‍👧 Family", "O'Brien-Smith", "DJ_k1d"] {
            XCTAssertEqual(valid(name), name, name)
        }
    }

    func testNormalizesToComposedForm() {
        XCTAssertEqual(valid("Jose\u{0301}"), "José")
        XCTAssertEqual(valid("Jose\u{0301}")?.unicodeScalars.count, 4)
    }

    func testRejectsEmptyAndWhitespaceOnly() {
        XCTAssertEqual(violation(""), .empty)
        XCTAssertEqual(violation("   "), .empty)
        XCTAssertEqual(violation("\n\t "), .empty)
        XCTAssertThrowsError(try UsernamePolicy.normalized(" ")) { XCTAssertEqual($0 as? LocalProfileError, .invalidUsername(.empty)) }
    }

    func testMaximumLengthCountsUserPerceivedCharacters() {
        XCTAssertEqual(valid(String(repeating: "a", count: 30))?.count, 30)
        XCTAssertEqual(violation(String(repeating: "a", count: 31)), .tooLong)
        // Each family emoji is one character but five scalars: 24 of them hit the 120-scalar bound exactly.
        XCTAssertNotNil(valid(String(repeating: "👨‍👩‍👧", count: 24)))
        XCTAssertEqual(violation(String(repeating: "👨‍👩‍👧", count: 31)), .tooLong)
        // Trimming happens before counting.
        XCTAssertNotNil(valid("  " + String(repeating: "b", count: 30) + "  "))
    }

    func testBoundsStackedCombiningMarks() {
        let stacked = "a" + String(repeating: "\u{0301}", count: 200)
        XCTAssertEqual(violation(stacked), .tooLong)
    }

    func testRejectsControlCharacters() {
        XCTAssertEqual(violation("Bad\u{0007}Bell"), .invalidCharacters)
        XCTAssertEqual(violation("Two\nLines"), .invalidCharacters)
        XCTAssertEqual(violation("Null\u{0000}Byte"), .invalidCharacters)
        XCTAssertEqual(violation("Line\u{2028}Separator"), .invalidCharacters)
        XCTAssertEqual(violation("Escape\u{001B}[31m"), .invalidCharacters)
    }

    func testPathLikeNamesAreJustDisplayNames() {
        // Allowed as text; never used to build a file path (avatars use UUID names).
        XCTAssertEqual(valid("../../etc"), "../../etc")
        XCTAssertEqual(valid("a/b"), "a/b")
    }
}

// MARK: - Model

final class LocalUserProfileModelTests: XCTestCase {
    func testDefaultAvatarFallbackWhenNoPath() {
        let profile = LocalUserProfile(id: UUID(), username: "ëlira", avatarRelativePath: nil, createdAt: Date(), updatedAt: Date())
        XCTAssertFalse(profile.hasCustomAvatar)
        XCTAssertEqual(profile.initial, "Ë")
    }

    func testManagedAvatarNamesAreStrict() {
        let id = UUID().uuidString
        XCTAssertTrue(LocalProfileRepository.isManagedAvatarName("avatar-\(id).jpg"))
        XCTAssertTrue(LocalProfileRepository.isManagedAvatarFile("avatar-\(id).thumb.jpg"))
        for unsafe in ["../avatar-\(id).jpg", "avatar-\(id).png", "avatar-me.jpg", "artwork-\(id).jpg", "/avatar-\(id).jpg", "avatar-\(id).thumb.jpg", ""] {
            XCTAssertFalse(LocalProfileRepository.isManagedAvatarName(unsafe), unsafe)
        }
        XCTAssertFalse(LocalProfileRepository.isManagedAvatarFile("artwork-\(id).thumb.jpg"))
        XCTAssertFalse(LocalProfileRepository.isManagedAvatarFile("notes.txt"))
    }
}

// MARK: - Avatar processing

final class ProfileAvatarProcessorTests: XCTestCase {
    func testValidImageProducesBoundedSquareJPEGs() throws {
        let prepared = try ProfileAvatarProcessor.prepare(ProfileTestImages.image(width: 2000, height: 1200))
        XCTAssertEqual(try ProfileTestImages.size(prepared.full), CGSize(width: 512, height: 512))
        XCTAssertEqual(try ProfileTestImages.size(prepared.thumbnail), CGSize(width: 128, height: 128))
        for data in [prepared.full, prepared.thumbnail] {
            let source = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
            XCTAssertEqual(CGImageSourceGetType(source) as String?, UTType.jpeg.identifier)
        }
    }

    func testPortraitAndJPEGInputAreCropped() throws {
        let prepared = try ProfileAvatarProcessor.prepare(ProfileTestImages.image(width: 600, height: 1400, type: .jpeg))
        XCTAssertEqual(try ProfileTestImages.size(prepared.full), CGSize(width: 512, height: 512))
    }

    func testSmallImageIsNotUpscaled() throws {
        let prepared = try ProfileAvatarProcessor.prepare(ProfileTestImages.image(width: 40, height: 40))
        let size = try ProfileTestImages.size(prepared.full)
        XCTAssertEqual(size.width, size.height)
        XCTAssertLessThanOrEqual(size.width, 512)
    }

    func testRejectsNonImageData() {
        XCTAssertThrowsError(try ProfileAvatarProcessor.prepare(Data("not an image".utf8))) { XCTAssertEqual($0 as? LocalProfileError, .invalidImage) }
        XCTAssertThrowsError(try ProfileAvatarProcessor.prepare(Data())) { XCTAssertEqual($0 as? LocalProfileError, .invalidImage) }
    }

    func testRejectsUndecodableTruncatedImage() throws {
        let truncated = try ProfileTestImages.image(width: 300, height: 300, type: .jpeg).prefix(20)
        XCTAssertThrowsError(try ProfileAvatarProcessor.prepare(Data(truncated))) { XCTAssertEqual($0 as? LocalProfileError, .invalidImage) }
    }

    func testRejectsOversizedInputBeforeDecoding() {
        let oversized = Data(count: ProfileAvatarProcessor.maximumInputBytes + 1)
        XCTAssertThrowsError(try ProfileAvatarProcessor.prepare(oversized)) { XCTAssertEqual($0 as? LocalProfileError, .imageTooLarge) }
    }

    func testRejectsUnreasonablePixelDimensions() throws {
        let wide = try ProfileTestImages.image(width: 64, height: 16)
        XCTAssertThrowsError(try ProfileAvatarProcessor.prepare(wide, maximumSourceSide: 32)) {
            XCTAssertEqual($0 as? LocalProfileError, .unsupportedImageDimensions)
        }
        XCTAssertThrowsError(try ProfileAvatarProcessor.prepare(wide, maximumSourceSide: 64, maximumSourcePixels: 512)) {
            XCTAssertEqual($0 as? LocalProfileError, .unsupportedImageDimensions)
        }
    }
}

// MARK: - Persistence and avatar lifecycle

final class LocalProfilePersistenceTests: XCTestCase {
    private var fixture: LibraryFixture!
    private let clock = TestClock()
    private let faults = FaultSwitch()

    override func setUpWithError() throws {
        fixture = try LibraryFixture(count: 3)
        retainUntilTeardown(fixture)
        let playlist = try fixture.repository.createPlaylist(name: "Road Trip")
        try fixture.repository.addTracks(fixture.ids, playlistID: playlist.id)
        try fixture.repository.setLiked(true, trackID: fixture.ids[1])
    }

    private func repository() -> LocalProfileRepository {
        let clock = clock, faults = faults
        return LocalProfileRepository(db: fixture.storage.database.dbQueue, paths: fixture.paths, clock: { clock.now }, fault: { try faults.check($0) })
    }
    private func profileFiles() throws -> Set<String> { Set(try FileManager.default.contentsOfDirectory(atPath: fixture.paths.profile.path)) }

    func testFreshDatabaseHasNoProfileThenCreatesOne() throws {
        let repo = repository()
        XCTAssertNil(try repo.load())
        let created = try repo.create(username: "  Arta ", avatar: nil)
        XCTAssertEqual(created.username, "Arta")
        XCTAssertNil(created.avatarRelativePath)
        XCTAssertEqual(created.createdAt, created.updatedAt)
        XCTAssertEqual(try repo.load(), created)
        XCTAssertEqual(try profileFiles(), [])
    }

    func testProfileIsRestoredAfterRelaunch() throws {
        let created = try repository().create(username: "Relaunch", avatar: try ProfileTestImages.avatar())
        // A second coordinator on the same files is what the next launch opens.
        let relaunched = try StorageCoordinator(paths: fixture.paths)
        let restored = try LocalProfileRepository(db: relaunched.database.dbQueue, paths: fixture.paths).load()
        XCTAssertEqual(restored, created)
        let path = try XCTUnwrap(restored?.avatarRelativePath)
        XCTAssertTrue(FileManager.default.fileExists(atPath: try fixture.paths.profileURL(relativePath: path).path))
    }

    func testOnlyOneProfileCanExist() throws {
        let repo = repository()
        let first = try repo.create(username: "First", avatar: nil)
        XCTAssertThrowsError(try repo.create(username: "Second", avatar: try ProfileTestImages.avatar())) {
            XCTAssertEqual($0 as? LocalProfileError, .profileAlreadyExists)
        }
        let queue = fixture.storage.database.dbQueue
        // The schema itself refuses a second row, whatever the slot.
        for slot in [1, 2] {
            XCTAssertThrowsError(try queue.write { db in
                try db.execute(sql: "INSERT INTO local_user_profile (slot, id, username, createdAt, updatedAt) VALUES (?, ?, 'X', ?, ?)",
                               arguments: [slot, UUID().uuidString, Date(), Date()])
            })
        }
        XCTAssertEqual(try queue.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM local_user_profile") }, 1)
        XCTAssertEqual(try repo.load(), first)
        XCTAssertEqual(try profileFiles(), [], "The rejected duplicate's avatar must not be left behind")
    }

    func testUsernameChangeKeepsIdentityAndCreationDate() throws {
        let repo = repository()
        let created = try repo.create(username: "Before", avatar: nil)
        clock.advance(60)
        let updated = try repo.update(profileID: created.id, username: "After ", avatar: .keep)
        XCTAssertEqual(updated.id, created.id)
        XCTAssertEqual(updated.username, "After")
        XCTAssertEqual(updated.createdAt, created.createdAt)
        XCTAssertGreaterThan(updated.updatedAt, created.updatedAt)
        XCTAssertEqual(try repo.load(), updated)
    }

    func testUnchangedSaveDoesNotTouchModificationDate() throws {
        let repo = repository()
        let created = try repo.create(username: "Same", avatar: nil)
        clock.advance(60)
        XCTAssertEqual(try repo.update(profileID: created.id, username: " Same", avatar: .keep), created)
        XCTAssertEqual(try repo.update(profileID: created.id, username: "Same", avatar: .remove), created)
    }

    func testInvalidUsernameIsRejectedWithoutWriting() throws {
        let repo = repository()
        XCTAssertThrowsError(try repo.create(username: "Bad\u{0007}", avatar: try ProfileTestImages.avatar()))
        XCTAssertNil(try repo.load())
        XCTAssertEqual(try profileFiles(), [])
        let created = try repo.create(username: "Good", avatar: nil)
        XCTAssertThrowsError(try repo.update(profileID: created.id, username: String(repeating: "x", count: 31), avatar: .keep))
        XCTAssertEqual(try repo.load(), created)
    }

    func testUpdateForAnotherProfileIDIsRejected() throws {
        let repo = repository()
        let created = try repo.create(username: "Owner", avatar: nil)
        XCTAssertThrowsError(try repo.update(profileID: UUID(), username: "Intruder", avatar: .keep)) {
            XCTAssertEqual($0 as? LocalProfileError, .profileMissing)
        }
        XCTAssertEqual(try repo.load(), created)
    }

    func testAvatarReferenceReplacementAndRemoval() throws {
        let repo = repository()
        let created = try repo.create(username: "Photo", avatar: try ProfileTestImages.avatar())
        let first = try XCTUnwrap(created.avatarRelativePath)
        XCTAssertEqual(try profileFiles(), [first, LocalProfileRepository.thumbnailName(first)])
        XCTAssertNotNil(repo.avatarURL(first, thumbnail: true))

        clock.advance(1)
        let replaced = try repo.update(profileID: created.id, username: "Photo", avatar: .replace(try ProfileTestImages.avatar()))
        let second = try XCTUnwrap(replaced.avatarRelativePath)
        XCTAssertNotEqual(first, second)
        XCTAssertEqual(replaced.id, created.id)
        XCTAssertEqual(try profileFiles(), [second, LocalProfileRepository.thumbnailName(second)], "The replaced avatar is deleted after the commit")

        clock.advance(1)
        let removed = try repo.update(profileID: created.id, username: "Photo", avatar: .remove)
        XCTAssertNil(removed.avatarRelativePath)
        XCTAssertEqual(try profileFiles(), [])
        XCTAssertEqual(try repo.load(), removed)
    }

    func testFailedCommitRollsBackAndKeepsPreviousAvatar() throws {
        let repo = repository()
        let created = try repo.create(username: "Stable", avatar: try ProfileTestImages.avatar())
        let before = try profileFiles()
        faults.arm(.beforeCommit)
        XCTAssertThrowsError(try repo.update(profileID: created.id, username: "Changed", avatar: .replace(try ProfileTestImages.avatar()))) {
            XCTAssertEqual($0 as? LocalProfileError, .saveFailed)
        }
        XCTAssertThrowsError(try repo.update(profileID: created.id, username: "Changed", avatar: .remove))
        faults.disarm()
        XCTAssertEqual(try repo.load(), created, "The transaction rolled back")
        XCTAssertEqual(try profileFiles(), before, "Only the new, uncommitted files were removed")
    }

    func testFailedCommitOnCreateLeavesNothingBehind() throws {
        let repo = repository()
        faults.arm(.beforeCommit)
        XCTAssertThrowsError(try repo.create(username: "Never", avatar: try ProfileTestImages.avatar()))
        faults.disarm()
        XCTAssertNil(try repo.load())
        XCTAssertEqual(try profileFiles(), [])
    }

    func testFailedFileWriteKeepsPreviousState() throws {
        let repo = repository()
        faults.arm(.avatarWrite)
        XCTAssertThrowsError(try repo.create(username: "NoFile", avatar: try ProfileTestImages.avatar())) {
            XCTAssertEqual($0 as? LocalProfileError, .saveFailed)
        }
        XCTAssertNil(try repo.load())
        faults.disarm()
        let created = try repo.create(username: "WithFile", avatar: try ProfileTestImages.avatar())
        let before = try profileFiles()
        faults.arm(.avatarWrite)
        XCTAssertThrowsError(try repo.update(profileID: created.id, username: "WithFile", avatar: .replace(try ProfileTestImages.avatar())))
        faults.disarm()
        XCTAssertEqual(try repo.load(), created)
        XCTAssertEqual(try profileFiles(), before)
    }

    func testOldAvatarCleanupFailureIsCollectedLater() throws {
        let repo = repository()
        let created = try repo.create(username: "Orphan", avatar: try ProfileTestImages.avatar())
        let old = try XCTUnwrap(created.avatarRelativePath)
        faults.arm(.oldAvatarCleanup)
        let replaced = try repo.update(profileID: created.id, username: "Orphan", avatar: .replace(try ProfileTestImages.avatar()))
        faults.disarm()
        let current = try XCTUnwrap(replaced.avatarRelativePath)
        XCTAssertTrue(try profileFiles().contains(old), "The commit succeeded even though cleanup failed")
        try repo.removeUnreferencedAvatars()
        XCTAssertEqual(try profileFiles(), [current, LocalProfileRepository.thumbnailName(current)])
    }

    func testCleanupNeverTouchesArtworkOrUnrelatedFiles() throws {
        let repo = repository()
        let id = UUID().uuidString
        // Music artwork, a look-alike avatar name in the artwork folder, and unrelated profile files.
        let artwork = try fixture.paths.artworkURL(relativePath: "artwork-\(id).jpg")
        let lookalike = try fixture.paths.artworkURL(relativePath: "avatar-\(id).jpg")
        let notes = try fixture.paths.profileURL(relativePath: "notes.txt")
        let unmanaged = try fixture.paths.profileURL(relativePath: "avatar-me.jpg")
        let orphan = try fixture.paths.profileURL(relativePath: "avatar-\(UUID().uuidString).jpg")
        for url in [artwork, lookalike, notes, unmanaged, orphan] { try Data("x".utf8).write(to: url) }
        let created = try repo.create(username: "Keep", avatar: try ProfileTestImages.avatar())
        try repo.removeUnreferencedAvatars()
        for url in [artwork, lookalike, notes, unmanaged] { XCTAssertTrue(FileManager.default.fileExists(atPath: url.path), url.lastPathComponent) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: orphan.path))
        let path = try XCTUnwrap(created.avatarRelativePath)
        XCTAssertTrue(FileManager.default.fileExists(atPath: try fixture.paths.profileURL(relativePath: path).path))
        _ = try repo.update(profileID: created.id, username: "Keep", avatar: .remove)
        for url in [artwork, lookalike, notes, unmanaged] { XCTAssertTrue(FileManager.default.fileExists(atPath: url.path), url.lastPathComponent) }
    }

    func testUnsafeStoredPathsAreRejected() throws {
        let repo = repository()
        XCTAssertNil(repo.avatarURL("../Documents/Music/song-0.wav", thumbnail: false))
        XCTAssertNil(repo.avatarURL("artwork-\(UUID().uuidString).jpg", thumbnail: false))
        XCTAssertThrowsError(try fixture.storage.database.dbQueue.write { db in
            try db.execute(sql: "INSERT INTO local_user_profile (slot, id, username, avatarRelativePath, createdAt, updatedAt) VALUES (1, ?, 'X', '../escape.jpg', ?, ?)",
                           arguments: [UUID().uuidString, Date(), Date()])
        }, "The schema refuses paths with separators")
    }

    func testLibraryRowsUnchangedByProfileOperations() throws {
        let queue = fixture.storage.database.dbQueue
        let before = try librarySnapshot(queue)
        XCTAssertFalse(before["tracks"]?.isEmpty ?? true)
        XCTAssertFalse(before["playlist_tracks"]?.isEmpty ?? true)
        let repo = repository()
        let created = try repo.create(username: "Library Safe", avatar: try ProfileTestImages.avatar())
        _ = try repo.update(profileID: created.id, username: "Renamed", avatar: .replace(try ProfileTestImages.avatar()))
        _ = try repo.update(profileID: created.id, username: "Renamed", avatar: .remove)
        try repo.removeUnreferencedAvatars()
        XCTAssertEqual(try librarySnapshot(queue), before)
        for index in fixture.ids.indices { XCTAssertTrue(FileManager.default.fileExists(atPath: try fixture.file(index).path)) }
        XCTAssertEqual(try fixture.foreignKeys(), 0)
    }

    func testProfileTableHasNoForeignKeysToLibrary() throws {
        let keys = try fixture.storage.database.dbQueue.read { try Row.fetchAll($0, sql: "PRAGMA foreign_key_list(local_user_profile)") }
        XCTAssertTrue(keys.isEmpty)
        let referencing = try fixture.storage.database.dbQueue.read { db in
            try String.fetchAll(db, sql: "SELECT name FROM sqlite_master WHERE type = 'table'").filter { table in
                try Row.fetchAll(db, sql: "PRAGMA foreign_key_list(\"\(table)\")").contains { ($0["table"] as String?) == "local_user_profile" }
            }
        }
        XCTAssertEqual(referencing, [])
    }
}

// MARK: - Upgrade from v1.1.0

final class LocalProfileUpgradeTests: XCTestCase {
    /// Rewinds a full fixture to exactly the v1.1.0 schema: v024 is the only Phase 11.1 change.
    private func v110Installation() throws -> LibraryFixture {
        let fixture = try LibraryFixture(count: 3)
        retainUntilTeardown(fixture)
        let playlist = try fixture.repository.createPlaylist(name: "Upgrade Mix")
        try fixture.repository.addTracks(fixture.ids, playlistID: playlist.id)
        try fixture.repository.setLiked(true, trackID: fixture.ids[2])
        try fixture.storage.database.dbQueue.write { db in
            try db.execute(sql: "DROP TABLE local_user_profile")
            try db.execute(sql: "DROP TABLE listening_session_days; DROP TABLE listening_sessions; DROP TABLE listening_analytics_state")
            // Phase 11.4 tables are new and empty; its widened source CHECK admits every v1.1.0 row.
            try db.execute(sql: "DROP TABLE portable_library_entries; DROP TABLE portable_library_import_items; DROP TABLE portable_library_imports")
            // Phase 11.5 preferences are new and empty; dropping the table drops its triggers.
            try db.execute(sql: "DROP TABLE collection_artwork_preferences")
            try db.execute(sql: "DELETE FROM grdb_migrations WHERE identifier IN (?, ?, ?, ?)", arguments: [LocalProfileSchema.version, ListeningAnalyticsSchema.version, PortableLibrarySchema.version, CollectionArtworkSchema.version])
        }
        let last = try fixture.storage.database.dbQueue.read { try String.fetchAll($0, sql: "SELECT identifier FROM grdb_migrations ORDER BY identifier").last }
        XCTAssertEqual(last, PlaylistLinkDownloadSchema.version, "v1.1.0 ends at v022")
        return fixture
    }

    func testMigrationIdentifierIsAppendOnlyAndSkipsCanceledV023() throws {
        XCTAssertEqual(LocalProfileSchema.version, "v024_local_user_profile")
        XCTAssertNotEqual(LocalProfileSchema.version, CanceledPhase108UpgradeTests.canceledMigration)
    }

    @MainActor func testV110LibraryUpgradesUntouchedAndPromptsForProfile() async throws {
        let fixture = try v110Installation()
        let before = try librarySnapshot(fixture.storage.database.dbQueue)
        // Next launch of the Phase 11.1 build.
        let upgraded = try StorageCoordinator(paths: fixture.paths)
        let applied = try appliedMigrations(upgraded.database.dbQueue)
        XCTAssertTrue(applied.contains(LocalProfileSchema.version))
        XCTAssertEqual(try librarySnapshot(upgraded.database.dbQueue), before, "Migration changed no library rows")

        let service = LocalProfileService(store: LocalProfileRepository(db: upgraded.database.dbQueue, paths: fixture.paths))
        service.load()
        XCTAssertEqual(service.launchDestination, .onboarding)
        let photo = try ProfileTestImages.avatar()
        _ = try await service.createProfile(username: "Upgrader", avatar: photo)
        XCTAssertEqual(service.launchDestination, .main)
        XCTAssertEqual(try librarySnapshot(upgraded.database.dbQueue), before, "Profile creation changed no library rows")
        XCTAssertEqual(upgraded.library.count, 3)
        for index in fixture.ids.indices { XCTAssertTrue(FileManager.default.fileExists(atPath: try fixture.file(index).path)) }
    }

    func testUpgradeWithCanceledPhase108MigrationApplied() throws {
        let fixture = try v110Installation()
        try fixture.storage.database.dbQueue.write { db in
            try db.execute(sql: CanceledPhase108UpgradeTests.canceledSchema)
            try db.execute(sql: "INSERT INTO grdb_migrations (identifier) VALUES (?)", arguments: [CanceledPhase108UpgradeTests.canceledMigration])
        }
        let before = try librarySnapshot(fixture.storage.database.dbQueue)
        let upgraded = try StorageCoordinator(paths: fixture.paths)
        XCTAssertNil(try LocalProfileRepository(db: upgraded.database.dbQueue, paths: fixture.paths).load())
        XCTAssertEqual(try librarySnapshot(upgraded.database.dbQueue), before)
    }

    func testReopeningIsIdempotent() throws {
        let fixture = try v110Installation()
        let first = try StorageCoordinator(paths: fixture.paths)
        let created = try LocalProfileRepository(db: first.database.dbQueue, paths: fixture.paths).create(username: "Twice", avatar: nil)
        let second = try StorageCoordinator(paths: fixture.paths)
        XCTAssertEqual(try LocalProfileRepository(db: second.database.dbQueue, paths: fixture.paths).load(), created)
    }
}

// MARK: - Service state

@MainActor
final class LocalProfileServiceTests: XCTestCase {
    private var fixture: LibraryFixture!

    override func setUp() async throws {
        fixture = try LibraryFixture(count: 2)
        retainUntilTeardown(fixture)
    }

    private func repository() -> LocalProfileRepository { LocalProfileRepository(db: fixture.storage.database.dbQueue, paths: fixture.paths) }

    func testNewUserIsSentToOnboardingAndExistingUserIsNot() async throws {
        let service = LocalProfileService(store: repository())
        XCTAssertEqual(service.state, .loading)
        service.load()
        XCTAssertEqual(service.launchDestination, .onboarding)
        let createdResult = try await service.createProfile(username: "New", avatar: nil)
        let created = try XCTUnwrap(createdResult)
        XCTAssertEqual(service.launchDestination, .main)

        let relaunched = LocalProfileService(store: repository())
        relaunched.load()
        XCTAssertEqual(relaunched.state, .ready(created))
        XCTAssertEqual(relaunched.launchDestination, .main)
    }

    func testDuplicateSubmissionCreatesOneProfile() async throws {
        let service = LocalProfileService(store: repository())
        service.load()
        let photoOne = try ProfileTestImages.avatar(), photoTwo = try ProfileTestImages.avatar()
        async let first = service.createProfile(username: "Tap One", avatar: photoOne)
        async let second = service.createProfile(username: "Tap Two", avatar: photoTwo)
        let results = try await [first, second]
        // The overlapping tap is ignored (nil) or, if it arrived after the commit, adopts it.
        XCTAssertEqual(Set(results.compactMap { $0?.id }).count, 1)
        XCTAssertEqual(try profileRowCount(fixture.storage.database.dbQueue), 1)
        // A later stray submission adopts, never replaces, the stored profile.
        let stored = try XCTUnwrap(service.profile)
        let late = try await service.createProfile(username: "Late", avatar: nil)
        XCTAssertEqual(late, stored)
        XCTAssertEqual(try repository().load(), stored)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: fixture.paths.profile.path).count, 2)
    }

    func testAnotherInstanceCreatingFirstIsAdopted() async throws {
        let service = LocalProfileService(store: repository())
        service.load()
        let existing = try repository().create(username: "Elsewhere", avatar: nil)
        let adopted = try await service.createProfile(username: "Mine", avatar: nil)
        XCTAssertEqual(adopted, existing)
        XCTAssertEqual(service.state, .ready(existing))
    }

    func testReadFailureIsRecoverableAndNeverOnboarding() async throws {
        let existing = try repository().create(username: "Existing", avatar: nil)
        let store = UnreadableProfileStore(base: repository())
        let service = LocalProfileService(store: store)
        service.load()
        guard case .failed(let message) = service.state else { return XCTFail("Expected a failure, got \(service.state)") }
        XCTAssertFalse(message.isEmpty)
        XCTAssertEqual(service.launchDestination, .failure(message))
        // Onboarding is unreachable, so nothing can overwrite the unread profile.
        await XCTAssertThrowsErrorAsync(try await service.createProfile(username: "Overwrite", avatar: nil))
        XCTAssertEqual(store.createCalls, 0)
        XCTAssertEqual(try repository().load(), existing)

        service.continueWithoutProfile()
        XCTAssertEqual(service.launchDestination, .main)

        store.failing = false
        service.load()
        XCTAssertEqual(service.state, .ready(existing))
        XCTAssertFalse(service.continuedWithoutProfile)
    }

    func testUnavailableStorageIsAFailureNotAnEmptyProfile() async {
        let service = LocalProfileService(store: nil)
        service.load()
        guard case .failure = service.launchDestination else { return XCTFail("Expected a failure destination") }
        await XCTAssertThrowsErrorAsync(try await service.createProfile(username: "Nobody", avatar: nil))
    }

    func testInterruptedOnboardingLeavesNoPermanentFiles() throws {
        // A crash after writing avatar files but before the row committed.
        let stray = "avatar-\(UUID().uuidString).jpg"
        for name in [stray, LocalProfileRepository.thumbnailName(stray)] { try Data("partial".utf8).write(to: try fixture.paths.profileURL(relativePath: name)) }
        let service = LocalProfileService(store: repository())
        service.load()
        XCTAssertEqual(service.launchDestination, .onboarding)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: fixture.paths.profile.path), [])
    }

    func testSaveChangesKeepsIdentityAndFailureKeepsState() async throws {
        let service = LocalProfileService(store: repository())
        service.load()
        let createdResult = try await service.createProfile(username: "Editor", avatar: nil)
        let created = try XCTUnwrap(createdResult)
        let editedResult = try await service.saveChanges(username: "Edited", avatar: .replace(try ProfileTestImages.avatar()))
        let edited = try XCTUnwrap(editedResult)
        XCTAssertEqual(edited.id, created.id)
        XCTAssertEqual(edited.createdAt, created.createdAt)
        XCTAssertNotNil(service.avatarURL(thumbnail: true))
        XCTAssertNotNil(service.avatarURL(thumbnail: false))

        await XCTAssertThrowsErrorAsync(try await service.saveChanges(username: "   ", avatar: .keep))
        XCTAssertEqual(service.state, .ready(edited), "A rejected edit leaves the displayed profile unchanged")
        XCTAssertEqual(try repository().load(), edited)

        let removedResult = try await service.saveChanges(username: "Edited", avatar: .remove)
        let removed = try XCTUnwrap(removedResult)
        XCTAssertNil(removed.avatarRelativePath)
        XCTAssertNil(service.avatarURL(thumbnail: true), "Default avatar")
    }

    func testPrepareAvatarRunsProcessor() async throws {
        let prepared = try await LocalProfileService.prepareAvatar(try ProfileTestImages.image(width: 900, height: 900))
        XCTAssertEqual(try ProfileTestImages.size(prepared.full), CGSize(width: 512, height: 512))
        do { _ = try await LocalProfileService.prepareAvatar(Data("nope".utf8)); XCTFail("Expected invalidImage") }
        catch { XCTAssertEqual(error as? LocalProfileError, .invalidImage) }
    }
}

func XCTAssertThrowsErrorAsync<T>(_ expression: @autoclosure () async throws -> T, file: StaticString = #filePath, line: UInt = #line) async {
    do { _ = try await expression(); XCTFail("Expected an error", file: file, line: line) } catch { }
}
