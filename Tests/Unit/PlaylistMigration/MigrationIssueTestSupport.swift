import Foundation
import GRDB
import XCTest
@testable import OFFLINE

/// Deterministic Phase 10.7 doubles. No live notification center, network or provider.

/// Records every aggregate notification request; delivery can be denied or fail.
@MainActor final class RecordingIssueNotifier: MigrationIssueNotifying {
    struct Request: Equatable { let identifier: String; let title: String; let body: String; let playlistID: String; let opensIssues: Bool }
    var onOpenIssues: ((String) -> Void)?
    var permitted = true
    /// Upcoming deliveries that fail transiently.
    var transientFailures = 0
    private(set) var attempts: [Request] = []
    /// Only requests iOS would have accepted.
    private(set) var delivered: [Request] = []
    func deliverMigrationReport(identifier: String, title: String, body: String, playlistID: String,
                                opensIssues: Bool) async -> AcquisitionNotificationDelivery {
        let request = Request(identifier: identifier, title: title, body: body, playlistID: playlistID, opensIssues: opensIssues)
        attempts.append(request)
        if transientFailures > 0 { transientFailures -= 1; return .failed }
        guard permitted else { return .notPermitted }
        delivered.append(request); return .delivered
    }
    /// The user opens a delivered notification (the delegate's routing for "issues").
    func tap(_ request: Request) { if request.opensIssues { onOpenIssues?(request.playlistID) } }
}

/// One isolated library (with real, verifiable WAV tracks `song-0`…), the production
/// migration repository and a `MigrationIssueCoordinator` driven by a test clock.
/// State owned by other subsystems is placed with the same columns they write.
@MainActor final class IssueFixture {
    let fixture: LibraryFixture
    let clock = CoordinatorTestClock()
    let notifier = RecordingIssueNotifier()
    var capacity: Int64?
    private(set) var coordinator: MigrationIssueCoordinator!
    var storage: StorageCoordinator { fixture.storage }
    var repo: GRDBPlaylistMigrationRepository { fixture.storage.playlistMigrations }
    var db: DatabaseQueue { fixture.storage.database.dbQueue }
    var issues: MigrationIssueRepository { coordinator.repository }
    static let configuration = MigrationIssueCoordinator.Configuration(debounce: .milliseconds(10), batchWait: 0.3, deliveryBackoff: 0.3)

    init(tracks: Int = 4) throws {
        fixture = try LibraryFixture(count: tracks)
        build()
    }

    func build(migrationCoordinator: PlaylistMigrationCoordinator? = nil, acquisition: PlaylistAcquisitionCoordinator? = nil) {
        let clock = clock
        coordinator = MigrationIssueCoordinator(repository: MigrationIssueRepository(db: db, paths: fixture.paths), migrations: repo,
            coordinator: migrationCoordinator, acquisition: acquisition, notifier: notifier, configuration: Self.configuration,
            now: { clock.now }, capacity: { [weak self] in self?.capacity })
    }

    /// Simulated process restart: the old instance stops; a new one reads SQLite only.
    func relaunch() async {
        await coordinator.invalidate()
        build()
    }

    @discardableResult
    func playlist(_ name: String, count: Int, duplicate: ((Int) -> Int?)? = nil) async throws -> (session: PlaylistMigrationSession, entries: [PlaylistMigrationEntry]) {
        let source = PlaylistMigrationSourcePlaylist(source: .exportify, name: name, entries: (0..<count).map { index in
            let original = duplicate?(index) ?? index
            return PlaylistMigrationSourceTrack(position: index, title: "\(name) song \(original)", primaryArtist: "\(name) Artist",
                                                album: "Album", durationMs: 2000, sourceTrackID: "\(name)-\(original)")
        })
        let session = try await repo.createPlaylist(from: source, operationID: name + "-" + UUID().uuidString)
        return (session, try await repo.entries(migrationID: session.id))
    }

    /// Places an occurrence state exactly as the owning subsystem stores it.
    func set(_ entry: PlaylistMigrationEntry, _ status: PlaylistMigrationEntryStatus, track: String? = nil) async throws {
        try await db.write { db in
            try db.execute(sql: "UPDATE migration_entries SET status = ?, localTrackID = ?, updatedAt = ? WHERE id = ?",
                           arguments: [status.rawValue, track, Date(), entry.id.uuidString])
        }
    }
    func checkpoint(_ entry: PlaylistMigrationEntry, _ outcome: String, retryable: Bool = false) async throws {
        try await db.write { db in
            try MatchingCheckpoint(entryID: entry.id.uuidString, algorithm: CandidateScoringEngine.algorithmVersion, retryable: retryable,
                                   outcome: outcome, updatedAt: Date()).save(db)
        }
    }
    func retryRecord(_ entry: PlaylistMigrationEntry, failures: Int, eligible: Bool, next: Date?, category: String = "providerTemporary") async throws {
        try await db.write { db in
            try EntryRetryRecord(entryID: entry.id.uuidString, migrationID: entry.migrationID.uuidString, failures: failures, category: category,
                                 eligible: eligible, lastAttemptAt: Date(), nextRetryAt: next, updatedAt: Date()).save(db)
        }
    }
    func intent(_ session: PlaylistMigrationSession, _ intent: String) async throws { try await repo.setMatchingIntent(session.id, intent: intent) }

    @discardableResult
    func candidates(_ entry: PlaylistMigrationEntry, _ count: Int, outcome: String = "review") async throws -> [PlaylistMigrationCandidate] {
        let values = (0..<count).map { index in
            PlaylistMigrationCandidate(id: UUID(), entryID: entry.id, provider: "youtube", providerTrackID: String(format: "iss%04d%04d", entry.position, index),
                title: "Candidate \(index) for \(entry.source.title)", artist: entry.source.primaryArtist, durationMs: 2000, confidence: 0.8 - Double(index) * 0.1,
                evidence: ["currentAttempt": "true", "rank": String(index + 1), "outcome": outcome, "channel": "Channel"], decision: .pending)
        }
        try await db.write { db in for value in values { try GRDBPlaylistMigrationRepository.insertFixtureCandidate(value, db: db) } }
        return values
    }

    /// A Phase 10.5 acquisition link (and optionally its shared job) in a given state.
    func link(_ entry: PlaylistMigrationEntry, _ state: AcquisitionLinkState, failure: String? = nil, retries: Int = 0,
              nextRetryAt: Date? = nil, jobError: String? = nil, jobState: StoredDownloadState = .failed, expected: Int64? = nil) async throws {
        try await db.write { db in
            var jobID: String?
            if jobError != nil || state == .waiting {
                let id = UUID().uuidString
                try StoredDownloadJob(transferSession: nil, transferNumber: nil, transferGeneration: nil, refreshedGeneration: nil, id: id,
                    sourceType: "youtube", sourceIdentifier: String(format: "lnk%08d", entry.position), trackID: nil, state: jobState, progress: 0,
                    errorMessage: jobError, title: entry.source.title, channel: nil, thumbnail: nil, position: nil, received: nil, expected: expected,
                    attempts: nil, startedAt: nil, finishedAt: nil, quality: AudioQuality.standard.rawValue, dateAdded: Date(), dateModified: Date()).insert(db)
                jobID = id
            }
            try AcquisitionLinkRecord(entryID: entry.id.uuidString, migrationID: entry.migrationID.uuidString, candidateID: UUID().uuidString,
                provider: "youtube", providerIdentity: String(format: "lnk%08d", entry.position), downloadJobID: jobID, createdJob: true, state: state,
                trackID: nil, failure: failure, retries: retries, nextRetryAt: nextRetryAt, createdAt: Date(), updatedAt: Date(), completedAt: nil).save(db)
        }
    }

    func reconcile() async { await coordinator.reconcileNow() }

    func report(_ session: PlaylistMigrationSession) async throws -> MigrationIssueReport {
        let value = try await issues.report(migrationID: session.id, now: clock.now, capacity: capacity)
        return try XCTUnwrap(value)
    }
    func rows(_ session: PlaylistMigrationSession) async throws -> [MigrationIssueRow] { try await issues.issueRows(migrationID: session.id) }
    func open(_ session: PlaylistMigrationSession) async throws -> [MigrationIssueRow] { try await rows(session).filter { $0.resolution == .open } }
    func count(_ table: String) async throws -> Int { try await db.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM \(table)") ?? 0 } }
}

extension XCTestCase {
    @MainActor func issueFixture(tracks: Int = 4) throws -> IssueFixture {
        let value = try IssueFixture(tracks: tracks)
        addTeardownBlock { await value.coordinator.invalidate() }
        return value
    }
}
