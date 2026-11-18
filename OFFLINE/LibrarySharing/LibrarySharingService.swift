import Foundation
import GRDB

/// Phase 11.4 owner of portable library export/import state. One instance lives in
/// `AppContainer`; views never own long-running work, so closing a sheet never stops an
/// import. Matching, acquisition, downloads and playback stay with their existing owners:
/// this service only commits metadata, runs the local-first reconciler and then hands each
/// imported playlist to the `PlaylistMigrationCoordinator`.
@MainActor final class LibrarySharingService: ObservableObject {
    @Published private(set) var activities: [PortableImportActivity] = []
    /// Imports whose playlists were paused by the user (durable through migration intent).
    @Published private(set) var paused: Set<String> = []
    /// A `.mbelesh` document delivered through Open in / AirDrop, already copied into the
    /// app's private import staging. Presented once the profile gate has passed.
    @Published var inbox: PortableInboxDocument?
    @Published var lastError: String?

    var isAvailable: Bool { storage != nil }
    private let storage: StorageCoordinator?
    private let coordinator: PlaylistMigrationCoordinator?
    private let metadata: (any YouTubeMetadataProvider)?
    private let appVersion: String?
    private var running: [String: Task<Void, Never>] = [:]
    private var observation: AnyDatabaseCancellable?
    private var refreshTask: Task<Void, Never>?
    private var started = false

    init(storage: StorageCoordinator?, coordinator: PlaylistMigrationCoordinator?, metadata: (any YouTubeMetadataProvider)?, appVersion: String?) {
        self.storage = storage; self.coordinator = coordinator; self.metadata = metadata; self.appVersion = appVersion
        if let storage { Self.cleanupInbox(storage.paths.imports) }
    }

    private var importRepository: PortableLibraryImportRepository? { storage.map { PortableLibraryImportRepository(db: $0.database.dbQueue) } }

    // MARK: Lifecycle

    /// Restores unfinished imports after launch. A user-paused import stays paused.
    func start() async {
        guard !started, let repository = importRepository, let storage else { return }
        started = true
        observe()
        await refresh()
        guard let unfinished = try? await repository.unfinishedImports() else { return }
        for record in unfinished {
            let ids = (activities.first { $0.id == record.id }?.migrationIDs) ?? []
            if await isPaused(ids, migrations: storage.playlistMigrations) { continue }
            reconcile(record.id)
        }
    }

    private func observe() {
        guard observation == nil, let storage else { return }
        let region = DatabaseRegionObservation(tracking: Table("portable_library_imports").all(), Table("portable_library_entries").all(),
                                               Table("migration_entries").all(), Table("migration_acquisitions").all(), Table("download_jobs").all())
        observation = region.start(in: storage.database.dbQueue, onError: { _ in }, onChange: { [weak self] _ in
            Task { @MainActor [weak self] in self?.scheduleRefresh() }
        })
    }

    private func scheduleRefresh() {
        guard refreshTask == nil else { return }
        refreshTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            guard let self else { return }
            self.refreshTask = nil
            await self.refresh()
        }
    }

    func refresh() async {
        guard let repository = importRepository, let storage else { return }
        guard let values = try? await repository.activities() else { return }
        var pausedNow = Set<String>()
        for activity in values where activity.phase != .cancelled {
            if await isPaused(activity.migrationIDs, migrations: storage.playlistMigrations) { pausedNow.insert(activity.id) }
        }
        if values != activities { activities = values }
        if pausedNow != paused { paused = pausedNow }
    }

    private func isPaused(_ ids: [UUID], migrations: GRDBPlaylistMigrationRepository) async -> Bool {
        guard !ids.isEmpty else { return false }
        for id in ids {
            let intent = try? await migrations.matchingIntent(id)
            if intent == "userPaused" { return true }
        }
        return false
    }

    // MARK: Export

    func exportPlan(_ scope: LibraryExportScope) async throws -> PortableLibraryExportPlan {
        guard let storage else { throw PortableLibraryError.storageUnavailable }
        return try await PortableLibraryExporter(db: storage.database.dbQueue, appVersion: appVersion).plan(scope)
    }

    /// Writes the document atomically into private export staging for the share sheet.
    func prepareShare(_ plan: PortableLibraryExportPlan) async throws -> PreparedLibraryShare {
        guard let storage else { throw PortableLibraryError.storageUnavailable }
        let exports = storage.paths.exports
        return try await Task.detached(priority: .userInitiated) { try PreparedLibraryShare.write(plan, exports: exports) }.value
    }

    // MARK: Import

    func preview(url: URL) async throws -> PortableImportPreview {
        guard let storage else { throw PortableLibraryError.storageUnavailable }
        let data = try await Task.detached(priority: .userInitiated) { try PortableLibraryFileReader.read(url) }.value
        return try await PortableLibraryImportPlanner(db: storage.database.dbQueue).preview(data: data, documentName: PortableLibraryFileReader.displayName(url))
    }

    /// Commits the selected playlists atomically, then starts local-first reconciliation.
    func confirm(_ preview: PortableImportPreview, selections: [String: PortableImportSelection], includeUnassigned: Bool,
                 automaticAcquisition: Bool) async throws -> PortableImportCommit {
        guard let repository = importRepository else { throw PortableLibraryError.storageUnavailable }
        let request = PortableImportRequest(preview: preview, selections: selections, includeUnassigned: includeUnassigned,
                                            automaticAcquisition: automaticAcquisition)
        let result = try await repository.commit(preview, request: request)
        observe()
        await refresh()
        if !result.reused || running[result.importID] == nil { reconcile(result.importID) }
        return result
    }

    private func reconcile(_ importID: String) {
        guard running[importID] == nil, let storage else { return }
        let reconciler = PortableImportReconciler(db: storage.database.dbQueue, migrations: storage.playlistMigrations, metadata: metadata)
        running[importID] = Task { [weak self] in
            do {
                try await reconciler.run(importID: importID)
                guard !Task.isCancelled, let self else { return }
                self.running[importID] = nil
                await self.handOff(importID)
            } catch {
                guard let self else { return }
                self.running[importID] = nil
                if !(error is CancellationError) { self.lastError = "Some songs could not be checked yet. They will be retried." }
                await self.refresh()
            }
        }
    }

    /// Automatic acquisition: each playlist's remaining songs go to the coordinator's
    /// ordinary matching (local, then discovery; recommended discoveries still need review).
    /// Without it, nothing is searched or downloaded until the user starts it.
    private func handOff(_ importID: String) async {
        await refresh()
        guard let activity = activities.first(where: { $0.id == importID }), activity.automaticAcquisition,
              !paused.contains(importID), let coordinator else { return }
        for id in activity.migrationIDs { try? await coordinator.startMigration(id) }
        await refresh()
    }

    func pause(_ activity: PortableImportActivity) async {
        running[activity.id]?.cancel(); running[activity.id] = nil
        for id in activity.migrationIDs { try? await coordinator?.pauseMigration(id) }
        await refresh()
    }

    func resume(_ activity: PortableImportActivity) async {
        for id in activity.migrationIDs { try? await coordinator?.resumeMigration(id) }
        await refresh()
        if [.committed, .reconciling].contains(activity.phase) { reconcile(activity.id) }
        else if activity.automaticAcquisition, let coordinator {
            for id in activity.migrationIDs { try? await coordinator.startMigration(id) }
        }
        await refresh()
    }

    /// Stops remaining matching and automatic downloads. Imported playlists, verified songs
    /// and shared downloads other playlists need are kept.
    func cancel(_ activity: PortableImportActivity) async {
        running[activity.id]?.cancel(); running[activity.id] = nil
        try? await importRepository?.setPhase(activity.id, .cancelled)
        for id in activity.migrationIDs { try? await coordinator?.cancelMigration(id) }
        await refresh()
    }

    /// Starts searching and downloading for an import that was confirmed without it.
    func findMissingSongs(_ activity: PortableImportActivity) async {
        guard let coordinator else { return }
        for id in activity.migrationIDs { try? await coordinator.startMigration(id) }
        await refresh()
    }

    // MARK: Open in / AirDrop

    /// Copies an incoming document into private staging immediately (the system may remove
    /// its own inbox copy), whatever screen or profile state the app is in.
    func receive(_ url: URL) {
        guard url.isFileURL, url.pathExtension.lowercased() == "mbelesh", let storage else { return }
        let imports = storage.paths.imports
        Task {
            do {
                let staged = try await Task.detached(priority: .userInitiated) { () throws -> URL in
                    let data = try PortableLibraryFileReader.read(url)
                    let directory = imports.appendingPathComponent("portable-inbox-" + UUID().uuidString, isDirectory: true)
                    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                    let target = directory.appendingPathComponent(PortableLibraryFileReader.displayName(url) + ".mbelesh")
                    try data.write(to: target, options: [.atomic, .completeFileProtection])
                    return target
                }.value
                if let previous = inbox { Self.discard(previous.url) }
                inbox = PortableInboxDocument(url: staged)
            } catch {
                lastError = (error as? LocalizedError)?.errorDescription ?? "This library file could not be opened."
            }
        }
    }

    func finishInbox(_ document: PortableInboxDocument) {
        Self.discard(document.url)
        if inbox?.id == document.id { inbox = nil }
    }

    nonisolated static func discard(_ url: URL) {
        let directory = url.deletingLastPathComponent()
        guard directory.lastPathComponent.hasPrefix("portable-inbox-") else { return }
        try? FileManager.default.removeItem(at: directory)
    }

    /// Staged documents never outlive a launch.
    nonisolated static func cleanupInbox(_ imports: URL) {
        guard let items = try? FileManager.default.contentsOfDirectory(at: imports, includingPropertiesForKeys: nil) else { return }
        for item in items where item.lastPathComponent.hasPrefix("portable-inbox-") { try? FileManager.default.removeItem(at: item) }
    }
}

struct PortableInboxDocument: Identifiable, Equatable, Sendable {
    let id = UUID()
    let url: URL
}
