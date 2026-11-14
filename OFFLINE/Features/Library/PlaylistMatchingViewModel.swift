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
        defer { busy = false; work = nil }
        try await repository.setMatchingIntent(id, intent: reason == .cancelled ? "userCancelled" : "systemPaused")
        message = reason.message
    }
    private func launch(_ id: UUID) {
        guard busy, activeID == id else { return }
        work = Task {
            var success = false
            do {
                if stopReason != nil { throw CancellationError() }
                try await service.run(migrationID: id) { [weak self] value in await self?.update(value) }
                try Task.checkCancellation()
                // A provider-paused attempt requires explicit retry, not a relaunch
                // loop against rate limits. Its unfinished occurrence checkpoints remain.
                try await repository.setMatchingIntent(id, intent: "completed")
                let warning = progress.message
                progress = try await repository.matchingSummary(migrationID: id)
                if progress.message == nil { progress.message = warning }
                message = progress.discoveryPaused
                    ? "Discovery paused. Saved results are preserved. Retry when YouTube search is available."
                    : "Matching finished. Processed entries are not necessarily matches; proposals require review."
                success = true
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
            else if success && foreground { await restoreIfNeeded() }
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
                Label(progress.discoveryPaused || progress.discoveryFailed > 0 ? "Retry Unfinished Discovery" : "Find Matching Recordings", systemImage: "magnifyingglass").frame(minHeight: 44)
            }.disabled(model.busy || session.status.isTerminal)
                .accessibilityIdentifier("migration-find-matches")
            Text("Source entries: \(progress.total) • Already local: \(progress.alreadyLocal)")
            Text("Verified local matches: \(progress.localMatches)")
            Text("Processed entries: \(progress.processed) • Saved candidates: \(progress.candidates)")
            Text("Recommended external: \(progress.recommended) • Review: \(progress.review)")
            Text("Genuine no match: \(progress.noMatch) • Entry errors: \(progress.failed)")
            Text("Discovery failed: \(progress.discoveryFailed) • Awaiting discovery: \(progress.deferred)")
            Text("Selected YouTube videos: \(progress.selected) (not downloaded) • Offline ready: \(progress.alreadyLocal + progress.localMatches)")
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
            if progress.discoveryPaused {
                Text("Anonymous YouTube search may require consent or verification and cannot guarantee bulk discovery. Saved results are kept; Retry later continues only unfinished entries. Meanwhile, open any entry, search it in your browser, and paste the video link to select it manually.")
            }
            if let readError { Text(readError).foregroundStyle(AppColors.error) }
            MatchingDeveloperDiagnosticsView()
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
    var lookup: YouTubeManualLookup? = nil
    @State private var candidates: [PlaylistMigrationCandidate] = []
    @State private var reload = 0
    @State private var error: String?
    @State private var issueMessage: String?
    var body: some View {
        Section("Recording Candidates") {
            if let error { Text(error) }
            if let issueMessage { Text(issueMessage).foregroundStyle(AppColors.error) }
            if let url = YouTubeSearchProviderAdapter.browserSearchURL(entry.source) {
                Link("Search This Song in Browser", destination: url).frame(minHeight: 44)
                Text("Find the right video in your browser, copy its link, and paste it below. Selecting a video does not download it. To use audio already in your library, choose Resolve Existing Placeholder.").font(.caption)
            }
            if let lookup {
                ManualYouTubeSelectionView(entry: entry, repository: repository, lookup: lookup,
                    accepted: candidates.first { $0.provider == "youtube" && $0.decision == .accepted }) { reload += 1 }
            }
            if candidates.isEmpty {
                Text(entry.status == .failed ? "Discovery did not produce a saved candidate. Retry Find Matching Recordings from the playlist." : "No saved candidates. Run Find Matching Recordings from the playlist.")
            }
            ForEach(candidates) { candidate in
                VStack(alignment: .leading, spacing: 6) {
                    if candidate.provider == "youtube" {
                        YouTubeArtwork(url: MatchingCandidateArtwork.thumbnail(candidate))
                            .frame(height: 170).clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                    Text(candidate.title).font(.headline)
                    Text(candidate.artist ?? "Performer unproven")
                    if let channel = candidate.evidence["channel"] { Text("YouTube channel: \(channel) (uploader)") }
                    else if candidate.provider == "youtube" { Text("YouTube channel: Unknown uploader") }
                    if let duration = candidate.durationMs { Text("Duration: \(duration / 60000):\(String(format: "%02d", duration / 1000 % 60))") }
                    else { Text("Duration: Unknown") }
                    if let url = MatchingCandidateArtwork.watchURL(candidate) { Link("Open on YouTube", destination: url).frame(minHeight: 44) }
                    Text("\(candidate.provider) • \(candidate.decision.rawValue.capitalized)")
                    if let confidence = candidate.confidence {
                        Text("Confidence: \(Int((confidence * 100).rounded())) / 100 • \(candidate.evidence["confidenceClassification"] ?? "Unknown")")
                    } else { Text(candidate.evidence["confidenceClassification"] ?? "Confidence not scored") }
                    if candidate.evidence["currentAttempt"] == "false" { Text("Earlier proposal — retained for review history") }
                    ForEach(["selectionExplanation", "primaryArtistAgreement", "featuredArtistAgreement", "durationDifferenceMs", "sourceVersion", "candidateVersion", "versionCompatibility", "hardGateFailures", "acceptance", "matchingAlgorithmVersion"], id: \.self) { key in
                        if let value = candidate.evidence[key], !value.isEmpty { Text("\(label(key)): \(value)") }
                    }
                    if candidate.decision == .pending { Text(candidate.provider == "youtube" ? "Pending review. To use this video, open it and paste its link above." : "Pending review.") }
                    if candidate.decision == .accepted && candidate.provider == "youtube" { Text("Selected by you • Not downloaded • Not available offline").foregroundStyle(AppColors.accentPrimary) }
                }.font(.caption).padding(.vertical, 6)
                    .accessibilityIdentifier("migration-candidate-" + candidate.id.uuidString)
            }
        }.task(id: "\(entry.updatedAt.timeIntervalSince1970)-\(reload)") {
            do {
                candidates = try await repository.candidates(entryID: entry.id).sorted {
                    ($0.confidence ?? 0) == ($1.confidence ?? 0) ? $0.id.uuidString < $1.id.uuidString : ($0.confidence ?? 0) > ($1.confidence ?? 0)
                }; error = nil
                issueMessage = try await repository.issues(migrationID: entry.migrationID)
                    .first { $0.entryID == entry.id && $0.resolution == .open }?.message
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

private struct MatchingDeveloperDiagnosticsView: View {
    @ObservedObject private var diagnostics = YouTubeDiagnosticModel.shared
    var body: some View {
        DisclosureGroup("Developer diagnostics") {
            Text(diagnostics.summary).font(.caption.monospaced()).textSelection(.enabled)
            Text("Last failure across YouTube requests; retained after restart.").font(.caption2)
        }
    }
}

/// Paste → validate → inspect → explicit confirmation. Confirmation records a
/// matched YouTube candidate only; it never creates a track or marks audio playable.
struct ManualYouTubeSelectionView: View {
    let entry: PlaylistMigrationEntry
    let repository: GRDBPlaylistMigrationRepository
    let lookup: YouTubeManualLookup
    let accepted: PlaylistMigrationCandidate?
    let changed: () -> Void
    @State private var link = ""
    @State private var preview: YouTubeManualLookupResult?
    @State private var busy = false
    @State private var message: String?
    @State private var confirming = false
    private var selectable: Bool {
        entry.localTrackID == nil && [.pending, .needsReview, .failed, .unavailable].contains(entry.status)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: AppSpacing.sm) {
            if let accepted {
                Text("Selected YouTube video: \(accepted.title)").font(.headline)
                Text("Not downloaded. This entry stays unavailable offline until audio is acquired and verified.").font(.caption)
                Button("Change or Reject Selection", role: .destructive) { reject(accepted) }
                    .disabled(busy).frame(minHeight: 44).accessibilityIdentifier("migration-manual-reject")
            } else if selectable {
                Text("Choose a YouTube video manually").font(.headline)
                TextField("Paste YouTube video link", text: $link)
                    .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                    .onChange(of: link) { _, _ in preview = nil; message = nil }
                    .accessibilityIdentifier("migration-manual-link")
                Button("Look Up Video") { look() }
                    .disabled(busy || link.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty).frame(minHeight: 44)
                    .accessibilityIdentifier("migration-manual-lookup")
                if busy { ProgressView() }
                if let preview { previewView(preview) }
            } else if entry.status == .matching {
                Text("Matching is processing this entry. Manual selection is available when it finishes.").font(.caption)
            }
            if let message { Text(message).font(.caption).foregroundStyle(AppColors.error) }
        }.tint(AppColors.accentPrimary)
            .confirmationDialog("Use this video for this Spotify entry?", isPresented: $confirming, titleVisibility: .visible) {
                Button("Confirm Selection") { confirm() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("The video is linked to this entry only. Nothing is downloaded and the entry is not marked as available offline.")
            }
    }
    @ViewBuilder private func previewView(_ value: YouTubeManualLookupResult) -> some View {
        let video = value.video
        YouTubeArtwork(url: video.thumbnailURL ?? YouTubeManualLookup.fallbackThumbnail(video.id))
            .frame(height: 170).clipShape(RoundedRectangle(cornerRadius: 8))
        Text(video.title.isEmpty ? "Title unavailable" : video.title).font(.headline)
        Text("Channel: \(video.channel ?? "Unknown uploader")")
        Text("Duration: \(video.duration == nil ? "Unknown" : video.durationLabel)")
        Text("Video ID: \(video.id)").font(.caption.monospaced())
        if let url = video.canonicalURL { Link("Open on YouTube", destination: url).frame(minHeight: 44) }
        if !value.metadataVerified {
            Text("Video details could not be read without verification. Confirm only after checking the video in your browser.").font(.caption).foregroundStyle(AppColors.error)
        }
        if [.live, .upcoming, .unavailable].contains(video.availability) {
            Text("This video is live, upcoming or unavailable and is unlikely to be usable.").font(.caption).foregroundStyle(AppColors.error)
        }
        Button("Use This Video") { confirming = true }.disabled(busy).frame(minHeight: 44)
            .accessibilityIdentifier("migration-manual-confirm")
    }
    private func look() {
        busy = true; message = nil; preview = nil
        let input = link
        Task {
            defer { busy = false }
            do {
                let result = try await lookup.lookup(input)
                guard input == link else { return }
                preview = result
            } catch is CancellationError {
            } catch {
                message = (error as? YouTubeError).flatMap(\.errorDescription) ?? YouTubeError.metadataUnavailable.localizedDescription
            }
        }
    }
    private func confirm() {
        guard let preview else { return }
        busy = true; message = nil
        Task {
            defer { busy = false }
            do {
                try await repository.confirmYouTubeCandidate(for: entry, video: preview.video, metadataVerified: preview.metadataVerified)
                self.preview = nil; link = ""; changed()
            } catch SongMatchingError.staleAttempt {
                message = "This entry changed or is being matched. Reopen it and try again."
            } catch PlaylistMigrationStorageError.invalidCandidate {
                message = "This entry already has a selection. Reject it first to choose another video."
            } catch { message = "The selection could not be saved. Try again." }
        }
    }
    private func reject(_ candidate: PlaylistMigrationCandidate) {
        busy = true; message = nil
        Task {
            defer { busy = false }
            do { try await repository.rejectYouTubeSelection(entryID: entry.id, candidateID: candidate.id); changed() }
            catch { message = "The selection could not be changed. Reopen this entry and try again." }
        }
    }
}
