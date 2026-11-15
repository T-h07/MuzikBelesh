import SwiftUI

/// One authoritative worker per app. Durable intents in `migration_matching_jobs`:
/// running/systemPaused resume automatically; userPaused, userCancelled, completed
/// and fatal never do.
@MainActor final class PlaylistMatchingViewModel: ObservableObject {
    @Published private(set) var activeID: UUID?
    @Published private(set) var busy = false
    @Published private(set) var progress = SongMatchingProgress()
    @Published private(set) var message: String?
    /// Last persisted intent per migration, for paused/interrupted presentation.
    @Published private(set) var intents: [UUID: String] = [:]
    private var work: Task<Void, Never>?
    private var stopReason: MatchingFailureCategory?
    private var foreground = true
    private var restoring = false
    private var resumeOnIdle = false
    private var onlyEntries: Set<UUID>?
    private var retryFailed = false
    private var intentWrite: Task<Void, Never>?
    private var lastPublish = ContinuousClock.now
    private let service: PlaylistMigrationMatchingService
    private let repository: GRDBPlaylistMigrationRepository
    private let execution: any MatchingBackgroundExecuting
    init(service: PlaylistMigrationMatchingService, repository: GRDBPlaylistMigrationRepository,
         execution: (any MatchingBackgroundExecuting)? = nil) {
        self.service = service; self.repository = repository; self.execution = execution ?? MatchingBackgroundExecution.shared
    }
    /// Retry This Song: only the given unresolved occurrence is re-attempted.
    func retry(_ id: UUID, entry: UUID) {
        guard !busy else { return }
        Task {
            do { try await repository.markRetryable(entryID: entry); start(id, only: [entry], retryFailed: true) }
            catch { message = "This song can't be retried right now." }
        }
    }
    /// Resume an unfinished or paused job: unfinished and deferred songs only.
    func resume(_ id: UUID) { start(id) }
    /// Explicitly search again for songs whose earlier search failed.
    func retryFailedSongs(_ id: UUID) { start(id, retryFailed: true) }
    func refreshIntent(_ id: UUID) async {
        if let intent = try? await repository.matchingIntent(id) { intents[id] = intent } else { intents[id] = nil }
    }
    func start(_ id: UUID, only: Set<UUID>? = nil, retryFailed: Bool = false) {
        guard !busy else { return }
        onlyEntries = only; self.retryFailed = retryFailed
        activeID = id; busy = true; message = nil; stopReason = nil
        intents[id] = "running"
        // Save user intent before submitting OS work. No scene/view owns the worker.
        work = Task {
            do {
                await intentWrite?.value // A pause written just before must not land after this.
                if let saved = try? await repository.matchingSummary(migrationID: id) { progress = saved }
                try await repository.setMatchingIntent(id, intent: "running")
                if let stopReason { try await finishBeforeStart(id, reason: stopReason); return }
                work = nil
                execution.begin(start: { [weak self] in self?.launch(id) }, expiration: { [weak self] in self?.expire() })
            } catch {
                if let stopReason {
                    let repository = repository
                    let intent = Self.intent(for: stopReason)
                    do { try await Task.detached { try await repository.setMatchingIntent(id, intent: intent) }.value }
                    catch { MatchingDiagnostics.record(error, session: id, entry: nil, stage: "cancel-before-start") }
                }
                failure(error, id: id, reason: stopReason); busy = false; work = nil
            }
        }
    }
    private static func intent(for reason: MatchingFailureCategory) -> String {
        switch reason {
        case .cancelled: "userCancelled"
        case .userPaused: "userPaused"
        case .interrupted, .offline: "systemPaused"
        default: "fatal"
        }
    }
    private func finishBeforeStart(_ id: UUID, reason: MatchingFailureCategory) async throws {
        defer { busy = false; work = nil }
        try await repository.setMatchingIntent(id, intent: Self.intent(for: reason))
        intents[id] = Self.intent(for: reason)
        message = reason.message
    }
    private func launch(_ id: UUID) {
        guard busy, activeID == id else { return }
        work = Task {
            var success = false, offline = false
            do {
                if stopReason != nil { throw CancellationError() }
                try await service.run(migrationID: id, only: onlyEntries, retryFailed: retryFailed) { [weak self] value in await self?.update(value) }
                try Task.checkCancellation()
                let final = await service.lastReport
                offline = final.waitingForConnection
                // A pause requested while the last song finished still wins.
                let intent = stopReason == .userPaused ? "userPaused" : offline ? "systemPaused" : "completed"
                try await repository.setMatchingIntent(id, intent: intent)
                intents[id] = intent
                progress = try await repository.matchingSummary(migrationID: id)
                progress.waitingForConnection = offline
                message = offline ? MatchingFailureCategory.offline.message : stopReason == .userPaused ? MatchingFailureCategory.userPaused.message : nil
                success = true
            } catch {
                let reason = stopReason ?? MatchingFailureCategory.classify(error)
                let intent = Self.intent(for: reason)
                // Detached cleanup does not inherit the worker's cancellation.
                let repository = repository
                do { try await Task.detached { try await repository.setMatchingIntent(id, intent: intent) }.value }
                catch { MatchingDiagnostics.record(error, session: id, entry: nil, stage: "save-intent") }
                intents[id] = intent
                if let saved = try? await repository.matchingSummary(migrationID: id) { progress = saved }
                failure(error, id: id, reason: reason)
            }
            execution.finish(success: success); busy = false; work = nil
            if resumeOnIdle { resumeOnIdle = false; await restoreIfNeeded() }
            else if success && foreground && !offline { await restoreIfNeeded() }
        }
    }
    private func failure(_ error: Error, id: UUID, reason: MatchingFailureCategory? = nil) {
        MatchingDiagnostics.record(error, session: id, entry: nil, stage: "presentation")
        message = (reason ?? MatchingFailureCategory.classify(error)).message
    }
    /// Coalesced: at most ~4 UI/background-task updates per second.
    private func update(_ value: SongMatchingProgress) {
        let now = ContinuousClock.now
        guard now - lastPublish >= .milliseconds(250) || value.remaining == 0 else { return }
        lastPublish = now
        progress = value; execution.update(value)
    }
    /// Real engine pause: persisted immediately, the in-flight request is cancelled,
    /// committed work stays saved, and nothing restarts automatically.
    func pause() {
        guard busy, let id = activeID else { return }
        stopReason = .userPaused
        intents[id] = "userPaused"
        let repository = repository, previous = intentWrite
        intentWrite = Task {
            await previous?.value
            do { try await repository.setMatchingIntent(id, intent: "userPaused") }
            catch { MatchingDiagnostics.record(error, session: id, entry: nil, stage: "pause") }
        }
        if let work { work.cancel() }
        else {
            execution.finish(success: false)
            work = Task { do { try await finishBeforeStart(id, reason: .userPaused) } catch { failure(error, id: id) } }
        }
    }
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
        guard stopReason == nil else { return } // A user pause/cancel already owns the outcome.
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
    /// Resumes only system-interrupted/running jobs; a user-paused job never restarts here.
    func restoreIfNeeded() async {
        guard foreground, !busy, !restoring else { return }
        restoring = true
        defer { restoring = false }
        do {
            await intentWrite?.value
            let jobs = try await repository.resumableMatchingJobs()
            guard foreground, !busy, let id = jobs.first else { return }
            start(id)
        } catch { message = MatchingFailureCategory.classify(error).message }
    }
    func waitForCompletion() async {
        while busy { if let work { await work.value } else { await Task.yield() } }
    }
}

/// Concise, consumer-facing matching status. Counts always come from persisted state.
struct PlaylistMatchingControls: View {
    @ObservedObject var model: PlaylistMatchingViewModel
    let session: PlaylistMigrationSession
    let repository: GRDBPlaylistMigrationRepository
    var playlistID: String? = nil
    var lookup: YouTubeManualLookup? = nil
    @State private var saved = SongMatchingProgress()
    @State private var loaded = false
    @State private var readError = false
    var body: some View {
        let active = model.activeID == session.id && model.busy
        let progress = active ? model.progress : saved
        let intent = model.intents[session.id]
        let started = active || progress.processed > 0 || intent != nil
        let paused = !active && intent == "userPaused" && progress.remaining > 0
        let interrupted = !active && !paused && progress.remaining > 0 && ["running", "systemPaused"].contains(intent ?? "")
        let complete = !active && started && progress.remaining == 0
        let retryable = progress.discoveryFailed + progress.failed
        VStack(alignment: .leading, spacing: AppSpacing.sm) {
            Text("Matching Songs").font(.headline)
            Text(title(active: active, paused: paused, interrupted: interrupted, complete: complete, progress: progress))
                .font(.subheadline.weight(.semibold)).foregroundStyle(AppColors.accentPrimary)
                .accessibilityIdentifier("matching-status")
            if paused { Text(MatchingFailureCategory.userPaused.message).foregroundStyle(AppColors.textSecondary) }
            else if interrupted {
                Text(progress.waitingForConnection ? MatchingFailureCategory.offline.message : "Progress saved. Resume to continue.")
                    .foregroundStyle(AppColors.textSecondary)
            }
            if started && progress.total > 0 {
                ProgressView(value: Double(min(progress.processed, progress.total)), total: Double(progress.total))
                    .tint(AppColors.accentPrimary)
                    .accessibilityLabel("Matching progress")
                    .accessibilityValue("\(progress.processed) of \(progress.total) songs checked")
                Text("\(progress.processed) / \(progress.total) songs checked").foregroundStyle(AppColors.textSecondary)
            }
            if started {
                Text(summary(progress, complete: complete)).accessibilityIdentifier("matching-summary")
                let offline = progress.alreadyLocal + progress.localMatches
                if offline > 0 { Text("\(offline) available offline").foregroundStyle(AppColors.textSecondary) }
            }
            if let message = model.message, model.activeID == session.id, isError(message) {
                Text(message).foregroundStyle(AppColors.error)
            }
            if readError { Text("Progress couldn't be loaded. Reopen the playlist.").foregroundStyle(AppColors.error) }
            HStack(spacing: AppSpacing.sm) {
                if active {
                    Button { model.pause() } label: { Label("Pause Matching", systemImage: "pause.fill").frame(minHeight: 44) }
                        .buttonStyle(.borderedProminent).accessibilityIdentifier("migration-pause-matching")
                } else if paused || interrupted {
                    Button { model.resume(session.id) } label: { Label("Resume Matching", systemImage: "play.fill").frame(minHeight: 44) }
                        .buttonStyle(.borderedProminent).disabled(model.busy).accessibilityIdentifier("migration-resume-matching")
                } else if !started {
                    Button { model.start(session.id) } label: { Label("Find Matching Songs", systemImage: "magnifyingglass").frame(minHeight: 44) }
                        .buttonStyle(.borderedProminent).disabled(model.busy || session.status.isTerminal)
                        .accessibilityIdentifier("migration-find-matches")
                }
                if let playlistID, progress.readyToReview + progress.needAttention > 0 {
                    NavigationLink {
                        MigrationReviewQueueView(model: MigrationReviewQueueModel(repository: repository, migrationID: session.id), lookup: lookup)
                    } label: { Text("Review Songs").frame(minHeight: 44) }
                        .buttonStyle(.bordered).accessibilityIdentifier("migration-review-songs")
                        .id(playlistID)
                }
            }
            if complete && retryable > 0 {
                Button("Retry \(retryable) Song\(retryable == 1 ? "" : "s") That Failed") { model.retryFailedSongs(session.id) }
                    .buttonStyle(.borderless).disabled(model.busy).frame(minHeight: 44)
                    .accessibilityIdentifier("migration-retry-failed")
            }
        }.tint(AppColors.accentPrimary)
            .task(id: "\(session.updatedAt.timeIntervalSince1970)-\(model.busy)") {
                await model.refreshIntent(session.id)
                guard !active else { return }
                do { saved = try await repository.matchingSummary(migrationID: session.id); readError = false }
                catch { readError = true }
                loaded = true
            }
    }
    private func title(active: Bool, paused: Bool, interrupted: Bool, complete: Bool, progress: SongMatchingProgress) -> String {
        if active { return "Finding recordings…" }
        if paused { return "Matching paused" }
        if interrupted { return progress.waitingForConnection ? "Waiting for connection" : "Matching interrupted" }
        if complete { return "Matching complete" }
        return "Find recordings for this playlist"
    }
    private func summary(_ progress: SongMatchingProgress, complete: Bool) -> String {
        var parts = ["\(progress.readyToReview) ready to review", "\(progress.resolved) matched"]
        if complete { parts.append("\(progress.needAttention) need attention") }
        else { parts.append("\(progress.remaining) remaining") }
        return parts.joined(separator: " · ")
    }
    private func isError(_ message: String) -> Bool {
        [MatchingFailureCategory.storageFatal.message, MatchingFailureCategory.storageBusy.message,
         MatchingFailureCategory.changedRecords.message].contains(message)
    }
}

/// Plain-language reasons for an unresolved song (technical detail stays in OSLog).
enum MatchingUserText {
    static func reason(_ message: String?) -> String? {
        guard let text = message?.lowercased(), !text.isEmpty else { return nil }
        if text.contains("internet connection") { return "Waiting for an internet connection." }
        if text.contains("history limit") { return "Several suggestions are saved. Review them first." }
        if text.contains("local audio failed") { return "The local file couldn't be verified." }
        if text.contains("no suitable") || text.contains("insufficient") { return "No matching recording found." }
        if ["deferred", "verification", "limit", "unavailable", "timed out", "too long", "incomplete", "busy", "changed"].contains(where: text.contains) {
            return "Search temporarily unavailable. You can retry later."
        }
        return "Couldn't find this song automatically."
    }
}

/// One recording suggestion in plain language (artwork, title, uploader, length, match).
struct CandidateSummaryCard: View {
    let candidate: PlaylistMigrationCandidate
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if candidate.provider == "youtube" {
                YouTubeArtwork(url: MatchingCandidateArtwork.thumbnail(candidate))
                    .frame(height: 170).clipShape(RoundedRectangle(cornerRadius: 8)).accessibilityHidden(true)
            } else { Label("In your library", systemImage: "music.note").foregroundStyle(AppColors.accentPrimary) }
            Text(candidate.title).font(.headline)
            Text(Self.subtitle(candidate)).font(.subheadline).foregroundStyle(AppColors.textSecondary)
            if let warning = Self.warning(candidate) {
                Label(warning, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(AppColors.error)
            }
        }.accessibilityElement(children: .combine)
    }
    static func duration(_ ms: Int64?) -> String? {
        guard let ms, ms > 0 else { return nil }
        let seconds = Int(ms / 1000)
        return seconds >= 3600 ? String(format: "%d:%02d:%02d", seconds / 3600, seconds / 60 % 60, seconds % 60)
                               : String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
    static func subtitle(_ candidate: PlaylistMigrationCandidate) -> String {
        [candidate.evidence["channel"] ?? candidate.artist, duration(candidate.durationMs),
         candidate.confidence.map { "\(Int(($0 * 100).rounded()))% match" }].compactMap { $0 }.joined(separator: " · ")
    }
    /// Concise version/identity warnings; never hides the strict checks, never shows internals.
    static func warning(_ candidate: PlaylistMigrationCandidate) -> String? {
        let gates = (candidate.evidence["hardGateFailures"] ?? "").lowercased()
        var notes: [String] = []
        if gates.contains("duration mismatch") { notes.append("Length differs from Spotify") }
        if gates.contains("version") { notes.append("May be a different version") }
        if gates.contains("title identity") { notes.append("Title differs") }
        if gates.contains("featured") { notes.append("Featured artists differ") }
        return notes.isEmpty ? nil : notes.prefix(2).joined(separator: " · ")
    }
}

struct MigrationCandidateInspection: View {
    @Environment(\.openURL) private var openURL
    let entry: PlaylistMigrationEntry
    let repository: GRDBPlaylistMigrationRepository
    var lookup: YouTubeManualLookup? = nil
    @State private var candidates: [PlaylistMigrationCandidate] = []
    @State private var reload = 0
    @State private var selecting: PlaylistMigrationCandidate?
    @State private var actionError: String?
    @State private var error: String?
    @State private var reason: String?
    private var canSelect: Bool {
        entry.localTrackID == nil && [.pending, .needsReview, .failed, .unavailable].contains(entry.status)
            && !candidates.contains { $0.decision == .accepted }
    }
    var body: some View {
        Section("Suggested Recordings") {
            if let error { Text(error) }
            if let reason, canSelect { Text(reason).foregroundStyle(AppColors.textSecondary) }
            if let actionError { Text(actionError).foregroundStyle(AppColors.error) }
            if candidates.isEmpty { Text(entry.status == .pending ? "Not searched yet." : "No suggestions yet.").foregroundStyle(AppColors.textSecondary) }
            ForEach(candidates.filter { $0.decision != .rejected }) { candidate in
                VStack(alignment: .leading, spacing: AppSpacing.sm) {
                    CandidateSummaryCard(candidate: candidate)
                    if candidate.decision == .accepted {
                        Text(candidate.provider == "youtube" ? "Selected · Not downloaded yet" : "Selected · Available offline")
                            .font(.caption).foregroundStyle(AppColors.accentPrimary)
                    }
                    // Separate, explicitly styled controls: each has its own hit area in the row.
                    HStack(spacing: AppSpacing.sm) {
                        if candidate.decision == .pending && canSelect {
                            Button(candidate.provider == "youtube" ? "Use This Video" : "Use This Recording") { selecting = candidate }
                                .buttonStyle(.borderedProminent).frame(minHeight: 44)
                                .accessibilityIdentifier("migration-candidate-select-" + candidate.id.uuidString)
                        }
                        if let url = MatchingCandidateArtwork.watchURL(candidate) {
                            Button("Preview") { openURL(url) }.buttonStyle(.bordered).frame(minHeight: 44)
                                .accessibilityLabel("Preview on YouTube")
                        }
                        if candidate.decision == .pending && canSelect {
                            Button("Not This One", role: .destructive) { reject(candidate) }.buttonStyle(.borderless).frame(minHeight: 44)
                                .accessibilityIdentifier("migration-candidate-reject-" + candidate.id.uuidString)
                        }
                    }
                }.padding(.vertical, 6).accessibilityIdentifier("migration-candidate-" + candidate.id.uuidString)
            }
            if let lookup {
                ManualYouTubeSelectionView(entry: entry, repository: repository, lookup: lookup,
                    accepted: candidates.first { $0.provider == "youtube" && $0.decision == .accepted }) { reload += 1 }
            }
            if canSelect, let url = YouTubeSearchProviderAdapter.browserSearchURL(entry.source) {
                Button { openURL(url) } label: { Label("Search on YouTube", systemImage: "safari") }.buttonStyle(.borderless).frame(minHeight: 44)
            }
        }.confirmationDialog("Use this recording?", isPresented: Binding(get: { selecting != nil }, set: { if !$0 { selecting = nil } }),
                             titleVisibility: .visible, presenting: selecting) { candidate in
            Button("Use This Recording") { select(candidate) }
            Button("Cancel", role: .cancel) { selecting = nil }
        } message: { candidate in
            Text(CandidateSummaryCard.warning(candidate).map { "\($0). Use it only if this is the right song." }
                 ?? "It's linked to this song. Nothing is downloaded yet.")
        }.task(id: "\(entry.updatedAt.timeIntervalSince1970)-\(reload)") {
            do {
                candidates = try await repository.candidates(entryID: entry.id).sorted {
                    ($0.confidence ?? 0) == ($1.confidence ?? 0) ? $0.id.uuidString < $1.id.uuidString : ($0.confidence ?? 0) > ($1.confidence ?? 0)
                }; error = nil
                reason = MatchingUserText.reason(try await repository.issues(migrationID: entry.migrationID)
                    .first { $0.entryID == entry.id && $0.resolution == .open && $0.code == "matching-attempt" }?.message)
            } catch { self.error = "Suggestions couldn't be loaded. Reopen this song." }
        }
    }
    private func select(_ candidate: PlaylistMigrationCandidate) {
        selecting = nil; actionError = nil
        Task {
            do { try await repository.selectCandidate(for: entry, candidateID: candidate.id); reload += 1 }
            catch SongMatchingError.staleAttempt { actionError = "This song is being updated. Try again in a moment." }
            catch { actionError = "This recording couldn't be saved." }
        }
    }
    private func reject(_ candidate: PlaylistMigrationCandidate) {
        actionError = nil
        Task {
            do { try await repository.rejectCandidate(entryID: entry.id, candidateID: candidate.id); reload += 1 }
            catch { actionError = "That couldn't be changed. Try again." }
        }
    }
}

/// Paste → validate → inspect → explicit confirmation, entirely inside the app.
/// Confirmation records a matched YouTube candidate only (pending acquisition); it
/// never creates a track, never marks audio playable and never opens another app.
/// Only the separate "Preview on YouTube" button opens a URL.
struct ManualYouTubeSelectionView: View {
    @Environment(\.openURL) private var openURL
    let entry: PlaylistMigrationEntry
    let repository: GRDBPlaylistMigrationRepository
    let lookup: YouTubeManualLookup
    let accepted: PlaylistMigrationCandidate?
    /// Review queue hook; defaults to saving through the repository.
    var onConfirm: ((YouTubeManualLookupResult) async throws -> Void)? = nil
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
                Text("Selected: \(accepted.title)").font(.headline)
                Text("Not downloaded yet.").font(.caption).foregroundStyle(AppColors.textSecondary)
                Button("Change Video", role: .destructive) { reject(accepted) }
                    .buttonStyle(.bordered).disabled(busy).frame(minHeight: 44).accessibilityIdentifier("migration-manual-reject")
            } else if selectable {
                Text("Paste a YouTube link").font(.headline)
                HStack {
                    TextField("youtube.com/watch?v=…", text: $link)
                        .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                        .onChange(of: link) { _, _ in preview = nil; message = nil }
                        .accessibilityIdentifier("migration-manual-link")
                    Button("Look Up") { look() }.buttonStyle(.bordered)
                        .disabled(busy || link.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty).frame(minHeight: 44)
                        .accessibilityIdentifier("migration-manual-lookup")
                }
                if busy { ProgressView() }
                if let preview { previewView(preview) }
            }
            if let message { Text(message).font(.caption).foregroundStyle(AppColors.error) }
        }.tint(AppColors.accentPrimary)
            .confirmationDialog("Use this video for this song?", isPresented: $confirming, titleVisibility: .visible) {
                Button("Use This Video") { confirm() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text(preview?.metadataVerified == false
                     ? "Video details couldn't be read. Use it only if you've checked it's the right song. Nothing is downloaded yet."
                     : "It's linked to this song. Nothing is downloaded yet.")
            }
    }
    @ViewBuilder private func previewView(_ value: YouTubeManualLookupResult) -> some View {
        let video = value.video
        YouTubeArtwork(url: video.thumbnailURL ?? YouTubeManualLookup.fallbackThumbnail(video.id))
            .frame(height: 170).clipShape(RoundedRectangle(cornerRadius: 8)).accessibilityHidden(true)
        Text(video.title.isEmpty ? "Title unavailable" : video.title).font(.headline)
        Text([video.channel, video.duration == nil ? nil : video.durationLabel].compactMap { $0 }.joined(separator: " · "))
            .font(.subheadline).foregroundStyle(AppColors.textSecondary)
        if !value.metadataVerified {
            Label("Details unavailable — check the video first", systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(AppColors.error)
        }
        if [.live, .upcoming, .unavailable].contains(video.availability) {
            Label("This video may not be playable", systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(AppColors.error)
        }
        HStack(spacing: AppSpacing.sm) {
            Button("Use This Video") { confirming = true }.buttonStyle(.borderedProminent).disabled(busy).frame(minHeight: 44)
                .accessibilityIdentifier("migration-manual-confirm")
            if let url = video.canonicalURL {
                Button("Preview on YouTube") { openURL(url) }.buttonStyle(.bordered).frame(minHeight: 44)
                    .accessibilityIdentifier("migration-manual-preview")
            }
        }
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
            } catch YouTubeError.invalidURL { message = "That isn't a YouTube video link."
            } catch YouTubeError.videoUnavailable { message = "This video is unavailable."
            } catch { message = "Video details couldn't be loaded. Try again." }
        }
    }
    private func confirm() {
        guard let preview else { return }
        busy = true; message = nil
        Task {
            defer { busy = false }
            do {
                if let onConfirm { try await onConfirm(preview) }
                else { try await repository.confirmYouTubeCandidate(for: entry, video: preview.video, metadataVerified: preview.metadataVerified) }
                self.preview = nil; link = ""; changed()
            } catch SongMatchingError.staleAttempt { message = "This song is being updated. Try again in a moment."
            } catch PlaylistMigrationStorageError.invalidCandidate { message = "This song already has a video. Change it first."
            } catch { message = "The video couldn't be saved. Try again." }
        }
    }
    private func reject(_ candidate: PlaylistMigrationCandidate) {
        busy = true; message = nil
        Task {
            defer { busy = false }
            do { try await repository.rejectYouTubeSelection(entryID: entry.id, candidateID: candidate.id); changed() }
            catch { message = "That couldn't be changed. Try again." }
        }
    }
}
