import Combine
import Foundation
import GRDB

/// Phase 11.5: the single owner of collection artwork decisions, owned by `AppContainer`.
///
/// - Resolves effective artwork (custom cover → mosaic → single cover → placeholder) for every
///   surface from one shared policy, so Home, Library, Search and detail pages always agree.
/// - Keeps a prepared candidate index per collection, rebuilt off the main actor from the
///   library snapshot it already observes. Rows never query GRDB or scan the library.
/// - Drives every rotation from one epoch (`floor(now / interval)`). There is one scheduled
///   task for the whole app, never one per row, and it only runs in the foreground.
/// - Persists the global switch in `UserDefaults` and per-collection modes in GRDB.
///
/// It never writes to tracks, playlists, albums, files, the queue, downloads or analytics.
@MainActor
final class CollectionArtworkService: ObservableObject {
    static let defaultInterval: TimeInterval = 30 * 60
    /// Bursts of library writes (matching, downloads) are coalesced into one rebuild.
    static let rebuildDelay: Duration = .milliseconds(250)

    @Published private(set) var automaticByDefault: Bool
    @Published private(set) var preferences: [CollectionArtworkIdentity: CollectionArtworkMode] = [:]
    @Published private(set) var entries: [CollectionArtworkIdentity: CollectionArtworkEntry] = [:]
    /// The shared rotation epoch. Changes at most once per interval, only in the foreground.
    @Published private(set) var epoch: Int
    /// "Refresh Mosaic" offsets for this session (purely visual; never persisted or written).
    @Published private(set) var refreshOffsets: [CollectionArtworkIdentity: Int] = [:]
    @Published private(set) var isForeground: Bool
    /// The last preference write or read failure, shown in settings. The previous choice stays.
    @Published private(set) var lastError: String?

    let interval: TimeInterval
    let paths: AppStoragePaths?
    let images: ArtworkImagePipeline
    private(set) var unusablePaths: Set<String> = []
    private(set) var rebuildCount = 0
    private let library: MusicLibraryService?
    private let repository: CollectionArtworkRepository?
    private let store: CollectionArtworkDefaultStoring?
    private let clock: () -> Date
    private let sleeper: @Sendable (Duration) async throws -> Void
    private var observation: (any DatabaseCancellable)?
    private var subscriptions = Set<AnyCancellable>()
    private var rebuildTask: Task<Void, Never>?
    private var rotationTask: Task<Void, Never>?
    private var needsRebuild = false

    init(library: MusicLibraryService?, database: DatabaseQueue?, paths: AppStoragePaths?, store: CollectionArtworkDefaultStoring?,
         images: ArtworkImagePipeline = .shared, interval: TimeInterval = CollectionArtworkService.defaultInterval,
         clock: @escaping () -> Date = Date.init, foreground: Bool = true,
         sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }) {
        self.library = library
        self.paths = paths
        self.store = store
        self.images = images
        self.interval = interval > 0 ? interval : Self.defaultInterval
        self.clock = clock
        self.sleeper = sleep
        self.isForeground = foreground
        self.automaticByDefault = store?.load() ?? true
        self.epoch = CollectionArtworkSelector.epoch(at: clock(), interval: interval > 0 ? interval : Self.defaultInterval)
        self.repository = database.map { CollectionArtworkRepository(db: $0) }
        if let library {
            // The first index is prepared synchronously (pure, no I/O) so the first frame of a
            // collection already shows its mosaic instead of flashing the placeholder.
            entries = CollectionArtworkIndexBuilder.build(snapshot: library.snapshot, artistGroups: library.artistGroups, albumGroups: library.albumGroups)
            library.$revision.dropFirst().sink { [weak self] _ in self?.scheduleRebuild() }.store(in: &subscriptions)
        }
        if let database {
            observation = ValueObservation.tracking { db in try CollectionArtworkRepository.preferences(db) }
                .removeDuplicates()
                .start(in: database, scheduling: .immediate, onError: { [weak self] _ in
                    // Failed reads keep the safe defaults (or the last good values).
                    self?.lastError = "Artwork preferences couldn't be read. Default artwork is shown."
                }, onChange: { [weak self] value in self?.preferences = value })
        }
        if foreground { scheduleRotation() }
    }

    // MARK: Resolution (cheap: dictionary lookups and O(1) selection)

    func mode(for identity: CollectionArtworkIdentity) -> CollectionArtworkMode { preferences[identity] ?? .appDefault }

    /// Per-collection choices override the global default in both directions.
    func mosaicEnabled(for identity: CollectionArtworkIdentity) -> Bool {
        switch mode(for: identity) {
        case .automatic: return true
        case .staticArtwork: return false
        case .appDefault: return automaticByDefault
        }
    }

    func entry(for identity: CollectionArtworkIdentity) -> CollectionArtworkEntry { entries[identity] ?? .empty }
    func hasCustomCover(_ identity: CollectionArtworkIdentity) -> Bool { entries[identity]?.customPath != nil }
    private func effectiveEpoch(_ identity: CollectionArtworkIdentity) -> Int { epoch &+ (refreshOffsets[identity] ?? 0) }

    func presentation(for identity: CollectionArtworkIdentity) -> CollectionArtworkPresentation {
        CollectionArtworkSelector.presentation(entry: entries[identity], mosaicEnabled: mosaicEnabled(for: identity), identity: identity,
                                               epoch: effectiveEpoch(identity), unusable: unusablePaths)
    }

    /// The mosaic this collection would show, regardless of custom cover and mode (settings preview).
    func mosaicPreview(for identity: CollectionArtworkIdentity) -> CollectionMosaicSelection? {
        CollectionArtworkSelector.select(entry(for: identity).candidates, identity: identity, epoch: effectiveEpoch(identity))
    }

    /// Refreshing changes something only when more than four distinct covers exist.
    func canRefresh(_ identity: CollectionArtworkIdentity) -> Bool { entry(for: identity).candidates.count > CollectionMosaicSelection.slotCount }

    /// Selects a different set now. Never touches membership, order or song metadata.
    func refresh(_ identity: CollectionArtworkIdentity) {
        guard canRefresh(identity) else { return }
        refreshOffsets[identity, default: 0] += 1
    }

    // MARK: Preferences

    func setAutomaticByDefault(_ enabled: Bool) {
        guard enabled != automaticByDefault else { return }
        do {
            try store?.save(enabled)
            automaticByDefault = enabled
            lastError = nil
        } catch { lastError = "Your artwork choice couldn't be saved. Try again." }
    }

    func setMode(_ mode: CollectionArtworkMode, for identity: CollectionArtworkIdentity) {
        guard identity.kind.hasPersistentPreference else { return }
        guard let repository else { lastError = "Artwork preferences are unavailable."; return }
        do {
            try repository.setMode(mode, for: identity, now: clock())
            // Applied at once; the observation delivers the same committed value.
            if mode == .appDefault { preferences[identity] = nil } else { preferences[identity] = mode }
            lastError = nil
        } catch { lastError = "This collection's artwork choice couldn't be saved. The previous choice is kept." }
    }

    // MARK: Failures and invalidation

    /// A displayed path turned out to be missing or undecodable: skip it and recompute.
    func reportUnusable(_ path: String) {
        guard !unusablePaths.contains(path) else { return }
        unusablePaths.insert(path)
        scheduleRebuild(delay: false)
    }

    /// Rebuilds the candidate index from the current library snapshot, coalescing bursts.
    func scheduleRebuild(delay: Bool = true) {
        guard isForeground else { needsRebuild = true; return }
        guard let library else { return }
        needsRebuild = false
        rebuildTask?.cancel()
        let previous = entries
        let unusable = unusablePaths
        let pipeline = self.images
        rebuildTask = Task { [weak self] in
            if delay {
                do { try await Task.sleep(for: Self.rebuildDelay) } catch { return }
            }
            let snapshot = library.snapshot, artists = library.artistGroups, albums = library.albumGroups
            let built = await Task.detached(priority: .utility) { () -> [CollectionArtworkIdentity: CollectionArtworkEntry]? in
                let next = CollectionArtworkIndexBuilder.build(snapshot: snapshot, artistGroups: artists, albumGroups: albums, unusable: unusable)
                guard next != previous else { return nil }
                // Removed or replaced artwork can never reappear from a stale decode.
                let removed = CollectionArtworkIndexBuilder.referencedPaths(previous).subtracting(CollectionArtworkIndexBuilder.referencedPaths(next))
                if !removed.isEmpty { pipeline.invalidate(removed) }
                return next
            }.value
            guard let self, !Task.isCancelled else { return }
            self.rebuildCount += 1
            if let built { self.entries = built }
        }
    }

    /// Waits for a pending rebuild (tests and settings refresh).
    func waitForRebuild() async { await rebuildTask?.value }

    // MARK: Rotation and lifecycle

    var isRotationScheduled: Bool { rotationTask != nil }

    /// Foreground: reconcile the epoch (changes only if the interval elapsed), apply deferred
    /// rebuilds and resume the single rotation task. Background: stop all artwork work; nothing
    /// is scheduled to wake the app.
    func setForeground(_ active: Bool) {
        guard active != isForeground else {
            if active { reconcileEpoch() }
            return
        }
        isForeground = active
        if active {
            unusablePaths.removeAll() // Recovery may have restored files while away.
            reconcileEpoch()
            needsRebuild = true
            scheduleRebuild(delay: false)
            scheduleRotation()
        } else {
            rotationTask?.cancel(); rotationTask = nil
            rebuildTask?.cancel(); rebuildTask = nil
        }
    }

    /// Recomputes the epoch from the clock. Publishes only a real change.
    func reconcileEpoch() {
        guard isForeground else { return }
        let current = CollectionArtworkSelector.epoch(at: clock(), interval: interval)
        if current != epoch { epoch = current }
    }

    func secondsUntilNextEpoch() -> TimeInterval {
        let now = clock().timeIntervalSince1970
        let next = (Double(CollectionArtworkSelector.epoch(at: clock(), interval: interval)) + 1) * interval
        return max(1, next - now)
    }

    private func scheduleRotation() {
        rotationTask?.cancel()
        let sleeper = self.sleeper
        rotationTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let delay = self?.secondsUntilNextEpoch() else { return }
                do { try await sleeper(.milliseconds(Int64((delay * 1000).rounded(.up)))) } catch { return }
                guard !Task.isCancelled, let self else { return }
                self.reconcileEpoch()
            }
        }
    }
}
