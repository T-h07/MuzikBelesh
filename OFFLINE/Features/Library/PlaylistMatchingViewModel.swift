import SwiftUI

@MainActor final class PlaylistMatchingViewModel: ObservableObject {
    @Published private(set) var activeID: UUID?
    @Published private(set) var busy = false
    @Published private(set) var progress = SongMatchingProgress()
    @Published private(set) var message: String?
    private var work: Task<Void, Never>?
    private let service: PlaylistMigrationMatchingService
    init(service: PlaylistMigrationMatchingService) { self.service = service }
    func start(_ id: UUID) {
        guard !busy else { return }
        activeID = id; busy = true; message = nil; progress = SongMatchingProgress()
        work = Task {
            defer { busy = false; work = nil }
            do {
                try await service.run(migrationID: id) { [weak self] value in
                    await self?.update(value)
                }
                message = "Matching finished. External proposals remain pending review."
            } catch is CancellationError {
                message = "Matching paused. Committed matches are preserved; retry unresolved entries when ready."
            } catch {
                message = "Matching stopped because the source, candidates or local storage changed. Committed results are preserved. Reopen the playlist and retry."
            }
        }
    }
    private func update(_ value: SongMatchingProgress) { progress = value }
    func cancel() { work?.cancel() }
    func setForeground(_ active: Bool) { if !active { cancel() } }
    func waitForCompletion() async { await work?.value }
}

struct PlaylistMatchingControls: View {
    @ObservedObject var model: PlaylistMatchingViewModel
    let session: PlaylistMigrationSession
    let repository: GRDBPlaylistMigrationRepository
    @State private var saved = SongMatchingProgress()
    @State private var readError: String?
    var body: some View {
        let active = model.activeID == session.id && model.busy
        let progress = active ? model.progress : saved
        VStack(alignment: .leading, spacing: AppSpacing.sm) {
            Button { model.start(session.id) } label: {
                Label("Find Matching Recordings", systemImage: "magnifyingglass").frame(minHeight: 44)
            }.disabled(model.busy || session.status.isTerminal)
                .accessibilityIdentifier("migration-find-matches")
            Text("Source entries: \(progress.total) • Already local: \(progress.alreadyLocal)")
            Text("Verified local matches: \(progress.localMatches)")
            Text("Recommended external: \(progress.recommended) • Review: \(progress.review)")
            Text("No suitable match: \(progress.noMatch)")
            if active {
                ProgressView(value: Double(progress.processed), total: Double(max(1, progress.total)))
                    .accessibilityLabel("Matching progress").accessibilityValue("\(progress.processed) of \(progress.total)")
                Text("Processed \(progress.processed) of \(progress.total)")
                Button("Cancel Matching") { model.cancel() }.frame(minHeight: 44)
            }
            if model.activeID == session.id {
                if let message = model.message { Text(message) }
                if let message = model.progress.message { Text(message).foregroundStyle(AppColors.error) }
            }
            if let readError { Text(readError).foregroundStyle(AppColors.error) }
            Text("Discovery only. External candidates are not available offline. Matching pauses when the app enters the background.")
                .foregroundStyle(AppColors.textSecondary)
        }.font(.caption).tint(AppColors.accentPrimary)
            .task(id: "\(session.updatedAt.timeIntervalSince1970)-\(model.busy)") {
                guard !active else { return }
                do { saved = try await repository.matchingSummary(migrationID: session.id); readError = nil }
                catch { readError = "Matching summary could not be read. Reopen the playlist to retry." }
            }
    }
}

struct MigrationCandidateInspection: View {
    let entry: PlaylistMigrationEntry
    let repository: GRDBPlaylistMigrationRepository
    @State private var candidates: [PlaylistMigrationCandidate] = []
    @State private var error: String?
    var body: some View {
        Section("Recording Candidates") {
            if let error { Text(error) }
            if candidates.isEmpty { Text("No saved candidates. Run Find Matching Recordings from the playlist.") }
            ForEach(candidates) { candidate in
                VStack(alignment: .leading, spacing: 6) {
                    Text(candidate.title).font(.headline)
                    Text(candidate.artist ?? "Performer unproven")
                    Text("\(candidate.provider) • \(candidate.decision.rawValue.capitalized)")
                    Text("Confidence: \(Int(((candidate.confidence ?? 0) * 100).rounded())) / 100 • \(candidate.evidence["confidenceClassification"] ?? "Unknown")")
                    if candidate.evidence["currentAttempt"] == "false" { Text("Earlier proposal — retained for review history") }
                    ForEach(["selectionExplanation", "primaryArtistAgreement", "featuredArtistAgreement", "durationDifferenceMs", "sourceVersion", "candidateVersion", "versionCompatibility", "hardGateFailures", "acceptance", "matchingAlgorithmVersion"], id: \.self) { key in
                        if let value = candidate.evidence[key], !value.isEmpty { Text("\(label(key)): \(value)") }
                    }
                    if candidate.decision == .pending { Text("Pending review. Confirmation and acquisition are reserved for later phases.") }
                }.font(.caption).padding(.vertical, 6)
                    .accessibilityIdentifier("migration-candidate-" + candidate.id.uuidString)
            }
        }.task(id: entry.updatedAt) {
            do {
                candidates = try await repository.candidates(entryID: entry.id).sorted {
                    ($0.confidence ?? 0) == ($1.confidence ?? 0) ? $0.id.uuidString < $1.id.uuidString : ($0.confidence ?? 0) > ($1.confidence ?? 0)
                }; error = nil
            } catch { self.error = "Candidates could not be read. Reopen this entry to retry." }
        }
    }
    private func label(_ key: String) -> String {
        switch key {
        case "selectionExplanation": return "Decision"
        case "primaryArtistAgreement": return "Primary artist"
        case "featuredArtistAgreement": return "Featured artists"
        case "durationDifferenceMs": return "Duration difference (ms)"
        case "sourceVersion": return "Source version"
        case "candidateVersion": return "Candidate version"
        case "versionCompatibility": return "Version check"
        case "hardGateFailures": return "Automatic selection blocked"
        case "acceptance": return "Acceptance"
        default: return "Algorithm"
        }
    }
}
