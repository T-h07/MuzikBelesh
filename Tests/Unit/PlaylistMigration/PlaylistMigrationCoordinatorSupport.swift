import Foundation
import GRDB
import XCTest
@testable import OFFLINE

/// Deterministic Phase 10.6 doubles: a controllable wall clock, a scripted discovery
/// provider with concurrency accounting, a background-execution grant that can be
/// expired on demand, and a harness that rebuilds the production object graph over
/// the same SQLite store (a simulated process restart). No real network is used.

/// Wall clock for persisted deadlines (cooldowns, retries, connectivity backoff).
final class CoordinatorTestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value = Date()
    var now: Date { lock.withLock { value } }
    func advance(_ seconds: TimeInterval) { lock.withLock { value = value.addingTimeInterval(seconds) } }
}

@MainActor final class CoordinatorExecution: MatchingBackgroundExecuting {
    private(set) var begins = 0
    private(set) var ends = 0
    private var expiration: (@MainActor () -> Void)?
    func begin(start: @escaping @MainActor () -> Void, expiration: @escaping @MainActor () -> Void) {
        begins += 1; self.expiration = expiration; start()
    }
    func update(_ progress: SongMatchingProgress) { }
    func finish(success: Bool) { ends += 1; expiration = nil }
    /// iOS ends the execution opportunity.
    func expire() { let action = expiration; expiration = nil; action?() }
}

/// Scripted per-title behaviors, consumed one per call (then `fallback`).
actor CoordinatorDiscovery: ExternalCandidateDiscovery {
    enum Behavior: Sendable { case candidates, empty, fail, rateLimited(Duration?), offline, block }
    nonisolated let name: String
    nonisolated var discoveryName: String { name }
    /// Every search, in order (source titles).
    private(set) var history: [String] = []
    private(set) var active = 0
    private(set) var maxActive = 0
    private var rules: [String: [Behavior]] = [:]
    private var fallback: Behavior = .candidates
    private var waiters: [UUID: (title: String, continuation: CheckedContinuation<Void, Error>)] = [:]

    init(name: String) { self.name = name }

    func set(_ title: String, _ behaviors: [Behavior]) { rules[title] = behaviors }
    func setDefault(_ behavior: Behavior) { fallback = behavior }
    func calls(for title: String) -> Int { history.filter { $0 == title }.count }
    var total: Int { history.count }
    func isHolding(_ title: String) -> Bool { waiters.values.contains { $0.title == title } }
    /// Releases every search currently held by `.block`.
    func release() { let held = waiters.values; waiters.removeAll(); held.forEach { $0.continuation.resume() } }

    static func videoID(_ title: String, _ suffix: Character) -> String {
        var hash: UInt64 = 1_469_598_103_934_665_603
        for byte in title.utf8 { hash = (hash ^ UInt64(byte)) &* 1_099_511_628_211 }
        let digits = String(hash % 10_000_000_000)
        return String(repeating: "0", count: 10 - digits.count) + digits + String(suffix)
    }

    func discover(_ source: PlaylistMigrationSourceTrack) async throws -> MatchingDiscoveryResult {
        history.append(source.title)
        active += 1; maxActive = max(maxActive, active)
        defer { active -= 1 }
        var behavior = fallback
        if var queue = rules[source.title], !queue.isEmpty { behavior = queue.removeFirst(); rules[source.title] = queue }
        await Task.yield()
        try Task.checkCancellation()
        switch behavior {
        case .block:
            try await hold(source.title)
            return recordings(source)
        case .candidates: return recordings(source)
        case .empty: return .init()
        case .fail:
            return .init(failures: [YouTubeError.searchUnavailable.localizedDescription], failure: .searchUnavailable, searchFailed: true)
        case .rateLimited(let after):
            return .init(failures: [YouTubeError.rateLimited.localizedDescription], failure: .rateLimited, pauseDiscovery: true,
                         searchFailed: true, retryAfter: after)
        case .offline: throw YouTubeError.networkUnavailable
        }
    }

    private func recordings(_ source: PlaylistMigrationSourceTrack) -> MatchingDiscoveryResult {
        .init(recordings: ["a", "b"].map {
            SongRecording(provider: "youtube", identity: Self.videoID(source.title, $0), title: source.title,
                          artist: source.primaryArtist, durationMs: source.durationMs, channel: source.primaryArtist)
        })
    }

    private func hold(_ title: String) async throws {
        let token = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                waiters[token] = (title, continuation)
            }
        } onCancel: {
            Task { await self.cancel(token) }
        }
    }
    private func cancel(_ token: UUID) { waiters.removeValue(forKey: token)?.continuation.resume(throwing: CancellationError()) }
}

/// Production wiring (service → matching worker → coordinator → acquisition →
/// DownloadManager) over one isolated store. `relaunch()` stops every instance as
/// process termination would and rebuilds them from SQLite alone.
@MainActor final class CoordinatorHarness {
    let base: AcquisitionHarness
    let clock = CoordinatorTestClock()
    let providers: [CoordinatorDiscovery]
    let configuration: PlaylistMigrationCoordinator.Configuration
    let restriction = ProviderRestrictionPolicy(cooldowns: [.seconds(30), .seconds(120), .seconds(300)], sleep: { _ in try Task.checkCancellation() },
                                                healthCooldown: .seconds(60), inlineWaitLimit: .seconds(30), suspendedCooldown: .seconds(900))
    private(set) var execution = CoordinatorExecution()
    private(set) var service: PlaylistMigrationMatchingService!
    private(set) var model: PlaylistMatchingViewModel!
    private(set) var coordinator: PlaylistMigrationCoordinator!
    private var seed = 0
    var discovery: CoordinatorDiscovery { providers[0] }
    var repo: GRDBPlaylistMigrationRepository { base.repo }
    var storage: StorageCoordinator { base.storage }
    var store: MigrationCoordinatorRepository { coordinator.repository }

    init(base: AcquisitionHarness, providerNames: [String], sliceSize: Int, retry: MigrationRetryPolicy) {
        self.base = base
        providers = providerNames.map { CoordinatorDiscovery(name: $0) }
        var configuration = PlaylistMigrationCoordinator.Configuration()
        configuration.sliceSize = sliceSize; configuration.retry = retry
        self.configuration = configuration
    }

    func build() async {
        execution = CoordinatorExecution()
        let store = MigrationCoordinatorRepository(db: storage.database.dbQueue)
        let clock = clock
        service = PlaylistMigrationMatchingService(repository: repo, providers: providers, restriction: restriction,
                                                   cooldowns: store, now: { clock.now })
        model = PlaylistMatchingViewModel(service: service, repository: repo, execution: execution)
        coordinator = PlaylistMigrationCoordinator(repository: store, migrations: repo, matching: model, service: service,
            acquisition: base.coordinator, downloads: base.downloads, configuration: configuration, now: { clock.now },
            sleep: { _ in try await Task.sleep(for: .seconds(3600)) })
        await coordinator.start()
    }

    /// Simulated restart. `crash` edits the store between termination and launch.
    func relaunch(connected: Bool = true, crash: (@Sendable (Database) throws -> Void)? = nil) async throws {
        await coordinator.invalidate()
        await base.terminate()
        if let crash { try await storage.database.dbQueue.write { try crash($0) } }
        await base.relaunch(connected: connected, wifi: connected)
        await build()
    }

    @discardableResult
    func importPlaylist(_ name: String, count: Int, duplicate: ((Int) -> Int?)? = nil) async throws -> PlaylistMigrationSession {
        let source = PlaylistMigrationSourcePlaylist(source: .exportify, name: name, entries: (0..<count).map { index in
            let original = duplicate?(index) ?? index
            return PlaylistMigrationSourceTrack(position: index, title: Self.title(name, original), primaryArtist: name + " Artist",
                                                album: "Album", durationMs: 200_000, sourceTrackID: name + "-\(original)")
        })
        return try await repo.createPlaylist(from: source, operationID: name + "-" + UUID().uuidString)
    }
    static func title(_ name: String, _ index: Int) -> String { "\(name) track \(index)" }

    func entries(_ session: PlaylistMigrationSession) async throws -> [PlaylistMigrationEntry] { try await repo.entries(migrationID: session.id) }
    func summary(_ session: PlaylistMigrationSession) async throws -> SongMatchingProgress { try await repo.matchingSummary(migrationID: session.id) }
    func intent(_ session: PlaylistMigrationSession) async throws -> String? { try await repo.matchingIntent(session.id) }

    /// Confirms the best pending suggestion exactly as the review queue does. Each
    /// confirmed recording gets distinct audio so library de-duplication never merges them.
    @discardableResult
    func confirmTop(_ entry: PlaylistMigrationEntry) async throws -> PlaylistMigrationCandidate {
        let candidates = try await repo.candidates(entryID: entry.id).filter { $0.decision == .pending }.sorted {
            ($0.confidence ?? 0) == ($1.confidence ?? 0) ? ($0.providerTrackID ?? "") < ($1.providerTrackID ?? "") : ($0.confidence ?? 0) > ($1.confidence ?? 0)
        }
        let pick = try XCTUnwrap(candidates.first, "No pending suggestion for position \(entry.position)")
        if let video = pick.providerTrackID { seed += 1; await base.transfer.seed(video, seed) }
        return try await repo.selectCandidate(for: try await repo.entry(id: entry.id), candidateID: pick.id)
    }

    func until(_ message: String = "Condition", timeout: Double = 60, file: StaticString = #filePath, line: UInt = #line,
               _ condition: () async throws -> Bool) async throws {
        try await base.until(message, timeout: timeout, file: file, line: line, condition)
    }

    /// Waits for the single matching worker to become idle, then refreshes status.
    func idle(timeout: Double = 60, file: StaticString = #filePath, line: UInt = #line) async throws {
        try await until("Matching worker idle", timeout: timeout, file: file, line: line) { !self.model.busy }
        await coordinator.refresh()
    }

    func complete(_ session: PlaylistMigrationSession, timeout: Double = 90, file: StaticString = #filePath, line: UInt = #line) async throws {
        let total = try await entries(session).count
        try await until("Matching complete", timeout: timeout, file: file, line: line) {
            try await self.summary(session).processed == total && !self.model.busy
        }
        await coordinator.refresh()
    }

    func readyCount(_ session: PlaylistMigrationSession) async throws -> Int {
        try await entries(session).filter { $0.status == .ready && $0.localTrackID != nil }.count
    }
    func count(_ table: String) async throws -> Int {
        try await storage.database.dbQueue.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM \(table)") ?? 0 }
    }
}

extension XCTestCase {
    /// A coordinator harness whose instances stop before the fixture is removed.
    @MainActor func coordinatorHarness(limit: Int = 3, holding: Bool = false, systemTransfers: Bool = false, backgroundExecution: Bool = false,
                                       providers: [String] = ["fixture"], sliceSize: Int = 40,
                                       retry: MigrationRetryPolicy = .deterministic) async throws -> CoordinatorHarness {
        let base = try harness(limit: limit, holding: holding, systemTransfers: systemTransfers, backgroundExecution: backgroundExecution)
        let value = CoordinatorHarness(base: base, providerNames: providers, sliceSize: sliceSize, retry: retry)
        addTeardownBlock { await value.coordinator?.invalidate() }
        await value.build()
        return value
    }
}
