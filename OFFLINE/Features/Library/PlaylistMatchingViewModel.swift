import SwiftUI

@MainActor final class PlaylistMatchingViewModel: ObservableObject {
    @Published private(set) var activeID: UUID?
    @Published private(set) var busy = false
    @Published private(set) var progress = SongMatchingProgress()
    @Published private(set) var message: String?
    private var work: Task<Void, Never>?
    private var stopReason: MatchingFailureCategory?
    private var foreground = true
    private var restoring = false
    private var resumeOnIdle = false
    private let service: PlaylistMigrationMatchingService
    private let repository: GRDBPlaylistMigrationRepository
    private let execution: any MatchingBackgroundExecuting
    init(service: PlaylistMigrationMatchingService, repository: GRDBPlaylistMigrationRepository,
         execution: (any MatchingBackgroundExecuting)? = nil) {
        self.service = service; self.repository = repository; self.execution = execution ?? MatchingBackgroundExecution.shared
    }
    func start(_ id: UUID) {
        guard !busy else { return }
        activeID = id; busy = true; message = nil; progress = SongMatchingProgress(); stopReason = nil
        // Save user intent before submitting OS work. No scene/view owns the worker.
        work = Task {
            do {
                try await repository.setMatchingIntent(id, intent: "running")
                if let stopReason { try await finishBeforeStart(id, reason: stopReason); return }
                work = nil
                execution.begin(start: { [weak self] in self?.launch(id) }, expiration: { [weak self] in self?.expire() })
            } catch {
                if let stopReason {
                    let repository = repository
                    let intent = stopReason == .cancelled ? "userCancelled" : "systemPaused"
                    do { try await Task.detached { try await repository.setMatchingIntent(id, intent: intent) }.value }
                    catch { MatchingDiagnostics.record(error, session: id, entry: nil, stage: "cancel-before-start") }
                }
                failure(error, id: id, reason: stopReason); busy = false; work = nil
            }
        }
    }
    private func finishBeforeStart(_ id: UUID, reason: MatchingFailureCategory) async throws {
        try await repository.setMatchingIntent(id, intent: reason == .cancelled ? "userCancelled" : "systemPaused")
        message = reason.message; busy = false; work = nil
    }
    private func launch(_ id: UUID) {
        guard busy, activeID == id else { return }
        work = Task {
            var success = false
            do {
                if stopReason != nil { throw CancellationError() }
                try await service.run(migrationID: id) { [weak self] value in await self?.update(value) }
                success = true
                try await repository.setMatchingIntent(id, intent: "completed")
                let warning = progress.message
                progress = try await repository.matchingSummary(migrationID: id)
                if progress.message == nil { progress.message = warning }
                message = "Matching finished. Proposals remain pending review; failed entries can be retried."
            } catch {
                let reason = stopReason ?? MatchingFailureCategory.classify(error)
                let intent = reason == .cancelled ? "userCancelled" : reason == .interrupted ? "systemPaused" : "fatal"
                // Detached cleanup does not inherit the worker's cancellation.
                let repository = repository
                do { try await Task.detached { try await repository.setMatchingIntent(id, intent: intent) }.value }
                catch { MatchingDiagnostics.record(error, session: id, entry: nil, stage: "save-intent") }
                failure(error, id: id, reason: reason)
            }
            execution.finish(success: success); busy = false; work = nil
            if resumeOnIdle { resumeOnIdle = false; await restoreIfNeeded() }
        }
    }
    private func failure(_ error: Error, id: UUID, reason: MatchingFailureCategory? = nil) {
        MatchingDiagnostics.record(error, session: id, entry: nil, stage: "presentation")
        message = (reason ?? MatchingFailureCategory.classify(error)).message
    }
    private func update(_ value: SongMatchingProgress) { progress = value; execution.update(value) }
    func cancel() {
        stopReason = .cancelled
        if work != nil { work?.cancel() }
        // A request awaiting the OS handler also needs a durable cancellation.
        if busy, let id = activeID {
            execution.finish(success: false)
            if work == nil { work = Task { do { try await finishBeforeStart(id, reason: .cancelled) } catch { failure(error, id: id) } } }
        }
    }
    private func expire() {
        stopReason = .interrupted
        if let work { work.cancel() }
        else if let id = activeID {
            work = Task { do { try await finishBeforeStart(id, reason: .interrupted) } catch { failure(error, id: id) } }
        }
    }
    func setForeground(_ active: Bool) {
        foreground = active
        if active && busy && stopReason == .interrupted { resumeOnIdle = true }
        if active { Task { await restoreIfNeeded() } }
    }
    func restoreIfNeeded() async {
        guard foreground, !busy, !restoring else { return }
        restoring = true
        defer { restoring = false }
        do {
            let jobs = try await repository.resumableMatchingJobs()
            guard foreground, !busy, let id = jobs.first else { return }
            start(id)
        } catch { message = MatchingFailureCategory.classify(error).message }
    }
    func waitForCompletion() async {
        while busy { if let work { await work.value } else { await Task.yield() } }
    }
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
            Text("No suitable match: \(progress.noMatch) • Failed: \(progress.failed)")
            if active {
                ProgressView(value: Double(progress.processed), total: Double(max(1, progress.total)))
                    .accessibilityLabel("Matching progress").accessibilityValue("\(progress.processed) of \(progress.total)")
                Text("Processed \(progress.processed) of \(progress.total)")
                Button("Cancel Matching") { model.cancel() }.frame(minHeight: 44)
            }
            if model.activeID == session.id {
                if let message = model.message { Text(message) }
            }
            if let message = progress.message { Text(message).foregroundStyle(AppColors.error) }
            if let readError { Text(readError).foregroundStyle(AppColors.error) }
            Text("Discovery only. External candidates are not available offline. Background matching continues while iOS permits. Interrupted work resumes when the app reopens.")
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
                    if candidate.provider == "youtube" {
                        YouTubeArtwork(url: MatchingCandidateArtwork.thumbnail(candidate))
                            .frame(height: 170).clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                    Text(candidate.title).font(.headline)
                    Text(candidate.artist ?? "Performer unproven")
                    if let channel = candidate.evidence["channel"] { Text("YouTube channel: \(channel) (uploader)") }
                    if let duration = candidate.durationMs { Text("Duration: \(duration / 60000):\(String(format: "%02d", duration / 1000 % 60))") }
                    if let url = MatchingCandidateArtwork.watchURL(candidate) { Link("Open on YouTube", destination: url).frame(minHeight: 44) }
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
