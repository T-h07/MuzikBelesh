import Foundation

/// Owns the local profile's observable state. Created once by `AppContainer`; editing a
/// profile never rebuilds the container, the player or the download manager.
@MainActor
final class LocalProfileService: ObservableObject {
    enum State: Equatable {
        case loading
        /// Storage was read successfully and holds no profile.
        case noProfile
        case ready(LocalUserProfile)
        /// Storage could not be read. Never treated as "no profile": onboarding is not shown,
        /// so nothing can overwrite data that merely failed to load.
        case failed(String)
    }

    enum LaunchDestination: Equatable { case loading, onboarding, failure(String), main }

    @Published private(set) var state: State = .loading
    @Published private(set) var isSaving = false
    /// Session only: after a load failure the user chose to continue to their library.
    @Published private(set) var continuedWithoutProfile = false

    private let store: (any LocalProfileStoring)?

    /// `store` is nil when app storage could not be opened at all.
    init(store: (any LocalProfileStoring)?) {
        self.store = store
    }

    var profile: LocalUserProfile? { if case .ready(let profile) = state { return profile }; return nil }

    var launchDestination: LaunchDestination {
        switch state {
        case .loading: return .loading
        case .noProfile: return .onboarding
        case .ready: return .main
        case .failed(let message): return continuedWithoutProfile ? .main : .failure(message)
        }
    }

    /// Reads the stored profile. Safe to call again as a retry.
    func load() {
        guard !isSaving else { return }
        guard let store else {
            state = .failed(LocalProfileError.storageUnavailable.errorDescription ?? "")
            return
        }
        do {
            let stored = try store.load()
            state = stored.map(State.ready) ?? .noProfile
            continuedWithoutProfile = false
            // Only after a successful read: files from an interrupted save are never referenced.
            try? store.removeUnreferencedAvatars()
        } catch {
            state = .failed(Self.message(for: error))
        }
    }

    func continueWithoutProfile() {
        if case .failed = state { continuedWithoutProfile = true }
    }

    /// Persists a new profile, then reports it ready. Returns nil when ignored because a save
    /// is already running (a duplicate tap). Nothing is reported as created before SQLite commits.
    @discardableResult
    func createProfile(username: String, avatar: PreparedAvatar?) async throws -> LocalUserProfile? {
        guard !isSaving else { return nil }
        guard state == .noProfile else {
            if let profile { return profile }
            throw LocalProfileError.storageUnavailable
        }
        guard let store else { throw LocalProfileError.storageUnavailable }
        let name = try UsernamePolicy.normalized(username)
        isSaving = true
        defer { isSaving = false }
        do {
            let created = try await Task.detached(priority: .userInitiated) { try store.create(username: name, avatar: avatar) }.value
            state = .ready(created)
            return created
        } catch LocalProfileError.profileAlreadyExists {
            // Another submission already committed: adopt the stored profile, never replace it.
            isSaving = false
            load()
            if let profile { return profile }
            throw LocalProfileError.profileAlreadyExists
        } catch {
            throw Self.profileError(error)
        }
    }

    /// Commits a validated edit. On failure the stored and displayed profile stay unchanged.
    @discardableResult
    func saveChanges(username: String, avatar: AvatarChange) async throws -> LocalUserProfile? {
        guard !isSaving else { return nil }
        guard let current = profile else { throw LocalProfileError.profileMissing }
        guard let store else { throw LocalProfileError.storageUnavailable }
        let name = try UsernamePolicy.normalized(username)
        isSaving = true
        defer { isSaving = false }
        do {
            let updated = try await Task.detached(priority: .userInitiated) { try store.update(profileID: current.id, username: name, avatar: avatar) }.value
            state = .ready(updated)
            return updated
        } catch {
            throw Self.profileError(error)
        }
    }

    func avatarURL(thumbnail: Bool) -> URL? {
        guard let path = profile?.avatarRelativePath else { return nil }
        return store?.avatarURL(path, thumbnail: thumbnail)
    }

    /// Decodes and downsamples picker data away from the main actor.
    nonisolated static func prepareAvatar(_ data: Data) async throws -> PreparedAvatar {
        try await Task.detached(priority: .userInitiated) { try ProfileAvatarProcessor.prepare(data) }.value
    }

    private static func profileError(_ error: Error) -> LocalProfileError {
        (error as? LocalProfileError) ?? .saveFailed
    }

    private static func message(for error: Error) -> String {
        // A storage-layer error (GRDB, file system) is reported as unavailable storage.
        ((error as? LocalProfileError) ?? .storageUnavailable).errorDescription ?? ""
    }
}
