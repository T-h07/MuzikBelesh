import SwiftUI

/// AppContainer owns the single import session. Presentation never owns its task.
@MainActor final class PlaylistImportViewModel: ObservableObject {
    @Published var report: PlaylistImportReport?
    @Published var duplicate: [UUID: PlaylistImportDuplicate] = [:]
    @Published var selected: Set<UUID> = []
    @Published var names: [UUID: String] = [:]
    @Published private(set) var results: [UUID: PlaylistImportCommit] = [:]
    @Published private(set) var failures: [UUID: String] = [:]
    @Published private(set) var busy = false
    @Published private(set) var operationID: UUID?
    @Published private(set) var progress = ""
    @Published private(set) var completed = 0
    @Published private(set) var failed = 0
    @Published private(set) var pending = 0
    @Published var error: String?
    private var work: Task<Void, Never>?
    private var presented = false
    private let storage: StorageCoordinator
    // Injectable persistence allows deterministic cancellation/navigation tests.
    private let persistence: any PlaylistImportPersisting
    init(storage: StorageCoordinator, persistence: (any PlaylistImportPersisting)? = nil) {
        self.storage = storage; self.persistence = persistence ?? storage.playlistMigrations
    }
    func cancel() { work?.cancel() }
    func presentationOpened() { presented = true }
    func presentationClosed() { presented = false; if !busy { releaseReview() } }
    private func releaseReview() { report = nil; duplicate = [:]; selected = []; names = [:] }
    private func finishOperation() {
        busy = false; work = nil
        if !presented { releaseReview() }
    }
    func isEligible(_ candidate: PlaylistImportCandidate) -> Bool {
        guard candidate.source != nil, results[candidate.id] == nil, let status = duplicate[candidate.id] else { return false }
        switch status { case .new, .changed: return true; case .existing, .ambiguous: return false }
    }
    var eligible: [PlaylistImportCandidate] { report?.candidates.filter(isEligible) ?? [] }
    var selectedCandidates: [PlaylistImportCandidate] { eligible.filter { selected.contains($0.id) } }
    var canCommit: Bool {
        !busy && !selectedCandidates.isEmpty && selectedCandidates.allSatisfy { (try? LibraryIdentity.validatedName(names[$0.id] ?? $0.name)) != nil }
    }
    func selectAll(_ select: Bool) { guard !busy else { return }; selected = select ? Set(eligible.map(\.id)) : [] }

    func load(_ url: URL) {
        guard !busy else { return }
        releaseReview(); results = [:]; failures = [:]; error = nil
        completed = 0; failed = 0; pending = 0
        busy = true; operationID = UUID()
        progress = "Reading and validating \(url.lastPathComponent)…"
        work = Task {
            defer { finishOperation() }
            do {
                let report = try await PlaylistMetadataFileImporter(stagingRoot: storage.paths.imports).prepare(file: url)
                let duplicates = try await PlaylistImportCoordinator(persistence: persistence).review(report)
                try Task.checkCancellation()
                self.report = report; duplicate = duplicates
                names = Dictionary(uniqueKeysWithValues: report.candidates.map { ($0.id, $0.name) })
                selectAllAfterLoad()
                progress = "Review the playlists before importing."
            } catch is CancellationError { error = "Reading cancelled. Nothing was imported." }
            catch let problem as PlaylistImportProblem { error = problem.localizedDescription }
            catch { self.error = "Unable to prepare the import review. Check file access and local database availability, then retry." }
        }
    }
    private func selectAllAfterLoad() { selected = Set(eligible.map(\.id)) }

    func commit() {
        guard canCommit else { return }
        let candidates = selectedCandidates
        let destinations = names
        busy = true; error = nil; operationID = UUID()
        completed = 0; failed = 0; pending = candidates.count
        work = Task {
            defer { finishOperation() }
            let coordinator = PlaylistImportCoordinator(persistence: persistence)
            for candidate in candidates {
                if Task.isCancelled { cancellationMessage(); break }
                progress = "Importing \(candidate.name)…"
                do {
                    let result = try await coordinator.commit(candidate, destinationName: destinations[candidate.id] ?? candidate.name)
                    results[candidate.id] = result; failures[candidate.id] = nil
                    completed += 1; pending -= 1; selected.remove(candidate.id)
                } catch is CancellationError { cancellationMessage(); break }
                catch let problem as PlaylistImportProblem { recordFailure(problem.localizedDescription, candidate: candidate) }
                catch let problem as PlaylistMigrationStorageError { recordFailure(problem.localizedDescription + " This playlist was not imported.", candidate: candidate) }
                catch let problem as LibraryError { recordFailure(problem.localizedDescription + " This playlist was not imported.", candidate: candidate) }
                catch { recordFailure("The database transaction could not commit. This playlist was not imported. Check available storage and retry.", candidate: candidate) }
            }
            progress = "\(completed) completed • \(pending) uncommitted • \(failed) failed"
            // Successful all-selected imports retain only small result summaries.
            if eligible.isEmpty { releaseReview() }
        }
    }
    private func recordFailure(_ message: String, candidate: PlaylistImportCandidate) {
        failures[candidate.id] = candidate.name + ": " + message; failed += 1; pending -= 1
    }
    private func cancellationMessage() {
        error = "Import cancelled. Completed playlists are kept; remaining playlists were not imported. Choose the export again if its review has been closed."
    }

    #if DEBUG
    func loadUITestFixture() {
        let arguments = ProcessInfo.processInfo.arguments
        guard arguments.contains("--ui-testing"), arguments.contains("--playlist-import-fixture"), results.isEmpty else { return }
        do {
            let multiple = arguments.contains("--playlist-import-multiple")
            let url = storage.paths.documents.appendingPathComponent(multiple ? "Synthetic Review.json" : "Synthetic Import.csv")
            if multiple {
                let values: [[String: Any]] = [
                    ["name": "First source", "items": [["track": ["trackName": "First song"]]]],
                    ["name": "Second source", "items": []],
                    ["name": "Invalid source", "items": [["episode": ["name": "Unsupported"]]]]
                ]
                try JSONSerialization.data(withJSONObject: ["playlists": values]).write(to: url)
            } else {
                let count = arguments.contains("--playlist-import-thousand") ? 1000 : 500
                let csv = "Track Name,Artist Name(s)\n" + (0..<count).map { "Synthetic song \(count == 1000 ? $0 : $0 % 3),Synthetic artist\n" }.joined()
                try Data(csv.utf8).write(to: url)
            }
            load(url)
        } catch { self.error = "Unable to stage the synthetic UI fixture." }
    }
    #endif
}
