import Foundation
import GRDB

/// How an edit treats the avatar.
enum AvatarChange: Equatable, Sendable {
    case keep
    case remove
    case replace(PreparedAvatar)
}

/// Test-only failure injection points (mirrors `LibraryFileFault`).
enum LocalProfileFault: Equatable, Sendable { case avatarWrite, beforeCommit, oldAvatarCleanup }

protocol LocalProfileStoring: AnyObject, Sendable {
    /// The stored profile, nil when none exists. Throws when storage can't be read: a read
    /// failure is never reported as "no profile".
    func load() throws -> LocalUserProfile?
    func create(username: String, avatar: PreparedAvatar?) throws -> LocalUserProfile
    func update(profileID: UUID, username: String, avatar: AvatarChange) throws -> LocalUserProfile
    /// Removes managed avatar files the stored profile does not reference (interrupted saves).
    func removeUnreferencedAvatars() throws
    func avatarURL(_ relativePath: String, thumbnail: Bool) -> URL?
}

/// GRDB persistence for the single local profile plus its managed avatar files.
///
/// Avatar lifecycle: new files are written under fresh UUID names first, the row is committed
/// second, and the previous files are deleted only after that commit. A failure before the
/// commit removes only the new files; the previous avatar stays valid. Only files in
/// `AppStoragePaths.profile` named `avatar-<UUID>.jpg` (and their `.thumb.jpg`) are ever deleted.
final class LocalProfileRepository: LocalProfileStoring, @unchecked Sendable {
    private let db: DatabaseQueue
    private let directory: URL
    private let paths: AppStoragePaths
    private let fault: (@Sendable (LocalProfileFault) throws -> Void)?
    private let clock: @Sendable () -> Date

    init(db: DatabaseQueue, paths: AppStoragePaths, clock: @escaping @Sendable () -> Date = { Date() },
         fault: (@Sendable (LocalProfileFault) throws -> Void)? = nil) {
        self.db = db
        self.paths = paths
        self.directory = paths.profile
        self.clock = clock
        self.fault = fault
    }

    // MARK: Reading

    func load() throws -> LocalUserProfile? {
        try db.read { try LocalUserProfile.fetchOne($0, sql: "SELECT id, username, avatarRelativePath, createdAt, updatedAt FROM local_user_profile WHERE slot = 1") }
    }

    func avatarURL(_ relativePath: String, thumbnail: Bool) -> URL? {
        guard Self.isManagedAvatarName(relativePath) else { return nil }
        return try? paths.profileURL(relativePath: thumbnail ? Self.thumbnailName(relativePath) : relativePath)
    }

    // MARK: Writing

    func create(username: String, avatar: PreparedAvatar?) throws -> LocalUserProfile {
        let name = try UsernamePolicy.normalized(username)
        let written = try avatar.map(writeAvatar)
        do {
            try db.write { db in
                // Checked inside the write transaction; the `slot` primary key is the backstop.
                guard try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM local_user_profile") == 0 else { throw LocalProfileError.profileAlreadyExists }
                let now = clock()
                try db.execute(sql: """
                    INSERT INTO local_user_profile (slot, id, username, avatarRelativePath, createdAt, updatedAt)
                    VALUES (1, ?, ?, ?, ?, ?)
                    """, arguments: [UUID().uuidString, name, written, now, now])
                try fault?(.beforeCommit)
            }
        } catch {
            removeAvatarFiles(written)
            if let error = error as? LocalProfileError { throw error }
            if let error = error as? DatabaseError, error.resultCode == .SQLITE_CONSTRAINT { throw LocalProfileError.profileAlreadyExists }
            throw LocalProfileError.saveFailed
        }
        guard let stored = try load() else { throw LocalProfileError.profileMissing }
        return stored
    }

    func update(profileID: UUID, username: String, avatar: AvatarChange) throws -> LocalUserProfile {
        let name = try UsernamePolicy.normalized(username)
        guard let current = try load(), current.id == profileID else { throw LocalProfileError.profileMissing }
        let newPath: String?
        switch avatar {
        case .keep: newPath = current.avatarRelativePath
        case .remove: newPath = nil
        case .replace(let prepared): newPath = try writeAvatar(prepared)
        }
        let createdFile: String? = { if case .replace = avatar { return newPath }; return nil }()
        // Nothing to change: no write, and `updatedAt` stays as it was.
        if name == current.username && newPath == current.avatarRelativePath { return current }
        do {
            try db.write { db in
                try db.execute(sql: "UPDATE local_user_profile SET username = ?, avatarRelativePath = ?, updatedAt = ? WHERE slot = 1 AND id = ?",
                               arguments: [name, newPath, clock(), profileID.uuidString])
                guard db.changesCount == 1 else { throw LocalProfileError.profileMissing }
                try fault?(.beforeCommit)
            }
        } catch {
            removeAvatarFiles(createdFile)
            if let error = error as? LocalProfileError { throw error }
            throw LocalProfileError.saveFailed
        }
        // Committed. The old files are no longer referenced; a failed delete leaves an orphan
        // that `removeUnreferencedAvatars` collects on the next launch.
        if let old = current.avatarRelativePath, old != newPath {
            do { try fault?(.oldAvatarCleanup); removeAvatarFiles(old) } catch { }
        }
        guard let stored = try load() else { throw LocalProfileError.profileMissing }
        return stored
    }

    func removeUnreferencedAvatars() throws {
        // Read first: if the database can't be read, delete nothing.
        let referenced = try load()?.avatarRelativePath
        let keep: Set<String> = referenced.map { [$0, Self.thumbnailName($0)] } ?? []
        let names = try paths.fileManager.contentsOfDirectory(atPath: directory.path)
        for name in names where Self.isManagedAvatarFile(name) && !keep.contains(name) {
            if let url = try? paths.profileURL(relativePath: name) { try? paths.fileManager.removeItem(at: url) }
        }
    }

    // MARK: Files

    private func writeAvatar(_ avatar: PreparedAvatar) throws -> String {
        let name = "avatar-\(UUID().uuidString).jpg"
        do {
            try fault?(.avatarWrite)
            try paths.fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            try avatar.full.write(to: paths.profileURL(relativePath: name), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            try avatar.thumbnail.write(to: paths.profileURL(relativePath: Self.thumbnailName(name)), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            return name
        } catch {
            removeAvatarFiles(name)
            throw LocalProfileError.saveFailed
        }
    }

    private func removeAvatarFiles(_ name: String?) {
        guard let name, Self.isManagedAvatarName(name) else { return }
        for file in [name, Self.thumbnailName(name)] {
            if let url = try? paths.profileURL(relativePath: file), paths.fileManager.fileExists(atPath: url.path) {
                try? paths.fileManager.removeItem(at: url)
            }
        }
    }

    // MARK: Naming

    static func thumbnailName(_ name: String) -> String { (name as NSString).deletingPathExtension + ".thumb.jpg" }

    /// `avatar-<UUID>.jpg`: the only shape ever stored in the profile row.
    static func isManagedAvatarName(_ name: String) -> Bool {
        guard name.hasPrefix("avatar-"), name.hasSuffix(".jpg"), !name.hasSuffix(".thumb.jpg"), !name.contains("/") else { return false }
        return UUID(uuidString: String(name.dropFirst("avatar-".count).dropLast(".jpg".count))) != nil
    }

    /// A managed avatar or its thumbnail. Anything else in the directory is never touched.
    static func isManagedAvatarFile(_ name: String) -> Bool {
        if isManagedAvatarName(name) { return true }
        guard name.hasSuffix(".thumb.jpg") else { return false }
        return isManagedAvatarName(String(name.dropLast(".thumb.jpg".count)) + ".jpg")
    }
}
