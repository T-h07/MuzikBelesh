import SwiftUI

/// One-song-at-a-time review of unresolved Spotify occurrences, in playlist order.
/// Only the current item's entry and candidates are loaded. Selecting or confirming
/// saves atomically and advances; navigating never confirms or rejects anything.
@MainActor final class MigrationReviewQueueModel: ObservableObject {
    @Published private(set) var items: [MigrationResolutionItem] = []
    @Published private(set) var index = 0
    @Published private(set) var entry: PlaylistMigrationEntry?
    @Published private(set) var candidates: [PlaylistMigrationCandidate] = []
    @Published private(set) var resolved: Set<UUID> = []
    @Published private(set) var loaded = false
    @Published private(set) var caughtUp = false
    /// True while a selection is being saved; repeated submissions are ignored.
    @Published private(set) var saving = false
    @Published var error: String?
    let repository: GRDBPlaylistMigrationRepository
    let migrationID: UUID
    /// The only path that may open an external URL (explicit preview).
    var openURL: (URL) -> Void = { _ in }
    static let queueCategories: Set<MigrationResolutionCategory> = [.needsReview, .noCandidate, .discoveryFailed]

    init(repository: GRDBPlaylistMigrationRepository, migrationID: UUID) {
        self.repository = repository; self.migrationID = migrationID
    }
    var current: MigrationResolutionItem? { items.indices.contains(index) ? items[index] : nil }
    var remaining: Int { items.filter { !resolved.contains($0.id) }.count }
    var position: Int { index + 1 }
    /// Every saved pending suggestion, best first. No arbitrary limit.
    var pendingCandidates: [PlaylistMigrationCandidate] { candidates.filter { $0.decision == .pending } }
    var accepted: PlaylistMigrationCandidate? { candidates.first { $0.decision == .accepted } }

    func load() async {
        do {
            // Playlist order is preserved: overview items follow source positions.
            items = try await repository.resolutionOverview(migrationID: migrationID).items.filter { Self.queueCategories.contains($0.category) }
            loaded = true; caughtUp = items.isEmpty
            await show(0)
        } catch { self.error = "Songs couldn't be loaded." }
    }
    func show(_ position: Int) async {
        guard items.indices.contains(position) else { return }
        index = position
        let id = items[position].id
        do {
            let fresh = try await repository.entry(id: id)
            let rows = try await repository.candidates(entryID: id)
            guard index == position else { return } // A newer navigation won.
            entry = fresh
            candidates = rows.filter { $0.decision != .rejected }.sorted {
                ($0.confidence ?? 0) == ($1.confidence ?? 0) ? $0.id.uuidString < $1.id.uuidString : ($0.confidence ?? 0) > ($1.confidence ?? 0)
            }
        } catch { self.error = "This song couldn't be loaded." }
    }
    func next() async { guard !saving, index + 1 < items.count else { return }; error = nil; await show(index + 1) }
    func previous() async { guard !saving, index > 0 else { return }; error = nil; await show(index - 1) }
    /// Skip for Now: leaves the song unresolved and moves on (no confirmation).
    func skip() async { guard !saving else { return }; error = nil; await advance(markingResolved: false) }

    /// Use This Video/Recording for the exact candidate the user confirmed. On failure
    /// the queue stays on the same song.
    func select(_ candidate: PlaylistMigrationCandidate) async {
        guard !saving, let current, candidate.entryID == current.id else { return }
        saving = true; error = nil
        defer { saving = false }
        do {
            // Re-read just before saving so a concurrent matching update is not a stale write.
            let fresh = try await repository.entry(id: current.id)
            try await repository.selectCandidate(for: fresh, candidateID: candidate.id)
        } catch SongMatchingError.staleAttempt { error = "This song is being updated. Try again in a moment."; await show(index); return }
        catch { self.error = "This recording couldn't be saved."; await show(index); return }
        await advance(markingResolved: true)
    }
    /// Save a pasted YouTube link (pending acquisition, never downloaded). Does not advance,
    /// so the caller can dismiss the keyboard first; then call `advanceAfterResolve()`.
    func saveManual(_ result: YouTubeManualLookupResult) async throws {
        guard !saving, let current else { return }
        saving = true; error = nil
        defer { saving = false }
        let fresh = try await repository.entry(id: current.id)
        try await repository.confirmYouTubeCandidate(for: fresh, video: result.video, metadataVerified: result.metadataVerified)
        resolved.insert(current.id)
    }
    func advanceAfterResolve() async { await advance(markingResolved: true) }
    /// Save and advance in one step.
    func confirmManual(_ result: YouTubeManualLookupResult) async throws {
        try await saveManual(result)
        await advanceAfterResolve()
    }
    func reject(_ candidate: PlaylistMigrationCandidate) async {
        guard !saving else { return }
        saving = true
        do {
            try await repository.rejectCandidate(entryID: candidate.entryID, candidateID: candidate.id)
            if candidate.decision == .accepted { resolved.remove(candidate.entryID); caughtUp = false }
        } catch { self.error = "That couldn't be changed. Try again." }
        saving = false
        await show(index)
    }
    func preview(_ candidate: PlaylistMigrationCandidate) {
        if let url = MatchingCandidateArtwork.watchURL(candidate) { openURL(url) }
    }

    private func advance(markingResolved: Bool) async {
        guard let current else { return }
        if markingResolved { resolved.insert(current.id) }
        let count = items.count
        // Next unresolved after the current one, wrapping.
        for step in 1...max(1, count) {
            let candidate = (index + step) % count
            if !resolved.contains(items[candidate].id) && (candidate != index || !markingResolved) {
                if candidate == index { return } // Only this skipped song remains.
                await show(candidate); return
            }
        }
        caughtUp = true
    }
}

struct MigrationReviewQueueView: View {
    @Environment(\.themePalette) private var palette
    @StateObject private var model: MigrationReviewQueueModel
    private let lookup: YouTubeManualLookup?
    init(model: @autoclosure @escaping () -> MigrationReviewQueueModel, lookup: YouTubeManualLookup?) {
        _model = StateObject(wrappedValue: model()); self.lookup = lookup
    }
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    /// The exact candidate whose button was tapped; cleared on dismissal and navigation.
    @State private var confirming: PlaylistMigrationCandidate?
    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: AppSpacing.md) {
                    Color.clear.frame(height: 0).id("review-top")
                    if !model.loaded { ProgressView().frame(maxWidth: .infinity) }
                    else if model.caughtUp { caughtUp }
                    else if let item = model.current { card(item) }
                    if let error = model.error {
                        Text(error).foregroundStyle(AppColors.error).accessibilityIdentifier("review-error")
                    }
                }.padding(.horizontal, AppSpacing.lg).padding(.top, AppSpacing.md)
            }
            .scrollDismissesKeyboard(.interactively)
            .safeAreaInset(edge: .bottom) { if model.loaded && !model.caughtUp { navigationBar } }
            // Each newly opened song starts at the top; scroll position is kept only within a song.
            .onChange(of: model.index) { _, _ in
                confirming = nil
                KeyboardDismissal.dismiss()
                proxy.scrollTo("review-top", anchor: .top)
            }
        }
        .background(AppColors.backgroundPrimary.ignoresSafeArea())
        .tint(palette.accent)
        .navigationTitle(model.caughtUp || !model.loaded ? "Review Songs" : "Review \(model.position) of \(model.items.count)")
        .navigationBarTitleDisplayMode(.inline)
        .task { model.openURL = { openURL($0) }; if !model.loaded { await model.load() } }
        .confirmationDialog("Use this recording?", isPresented: Binding(get: { confirming != nil }, set: { if !$0 { confirming = nil } }),
                            titleVisibility: .visible, presenting: confirming) { candidate in
            Button("Use This Recording") {
                confirming = nil
                Task { await model.select(candidate) }
            }.accessibilityIdentifier("review-confirm-use")
            Button("Cancel", role: .cancel) { confirming = nil }
        } message: { candidate in
            Text("\(candidate.title)\n" + (CandidateSummaryCard.warning(candidate).map { "\($0). Use it only if this is the right song." }
                 ?? "It's linked to this song. Nothing is downloaded yet."))
        }
    }

    private var caughtUp: some View {
        VStack(spacing: AppSpacing.md) {
            Image(systemName: "checkmark.circle").font(.system(size: 48)).foregroundStyle(palette.accent).accessibilityHidden(true)
            Text("You're all caught up.").font(.title3.weight(.semibold))
            Button("Back to Playlist") { dismiss() }.buttonStyle(.matchingPrimary)
                .accessibilityIdentifier("review-back-to-playlist")
        }.frame(maxWidth: .infinity).padding(.top, 40).accessibilityIdentifier("review-caught-up")
    }

    private var navigationBar: some View {
        HStack(spacing: AppSpacing.sm) {
            Button { KeyboardDismissal.dismiss(); Task { await model.previous() } } label: { Label("Previous", systemImage: "chevron.left") }
                .buttonStyle(.matchingSecondary).disabled(model.index == 0 || model.saving)
                .accessibilityIdentifier("review-previous")
            Button("Skip for Now") { KeyboardDismissal.dismiss(); Task { await model.skip() } }
                .buttonStyle(.matchingSecondaryWide).disabled(model.saving)
                .accessibilityIdentifier("review-skip")
            Button { KeyboardDismissal.dismiss(); Task { await model.next() } } label: { Label("Next", systemImage: "chevron.right") }
                .buttonStyle(.matchingSecondary).disabled(model.index + 1 >= model.items.count || model.saving)
                .accessibilityIdentifier("review-next")
        }
        .labelStyle(.titleAndIcon)
        .padding(.horizontal, AppSpacing.lg).padding(.vertical, AppSpacing.sm)
        .background(AppColors.backgroundPrimary.opacity(0.96))
    }

    @ViewBuilder private func card(_ item: MigrationResolutionItem) -> some View {
        let source = item.entry.source
        VStack(alignment: .leading, spacing: 4) {
            Text("\(model.remaining) left to review").font(.caption).foregroundStyle(AppColors.textSecondary)
            Text(source.title).font(.title3.weight(.semibold)).accessibilityIdentifier("review-song-title")
            Text([source.primaryArtist, source.album, CandidateSummaryCard.duration(source.durationMs)].compactMap { $0 }.joined(separator: " · "))
                .font(.subheadline).foregroundStyle(AppColors.textSecondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("review-song-header")
        // Horizontal swipe on the song header only: navigates, never confirms or rejects,
        // and leaves vertical scrolling and candidate taps untouched.
        .gesture(DragGesture(minimumDistance: 30).onEnded { value in
            guard abs(value.translation.width) > max(80, abs(value.translation.height) * 2) else { return }
            KeyboardDismissal.dismiss()
            Task { if value.translation.width < 0 { await model.next() } else { await model.previous() } }
        })

        if let accepted = model.accepted {
            CandidateSummaryCard(candidate: accepted)
            let offline = model.entry?.status == .ready && model.entry?.localTrackID != nil
            Text(accepted.provider == "youtube" && !offline ? "Selected · Not downloaded yet" : "Selected · Available offline")
                .font(.caption).foregroundStyle(palette.accent)
            if accepted.provider == "youtube" && !offline {
                Button("Change Video") { Task { await model.reject(accepted) } }.buttonStyle(.matchingSecondary).disabled(model.saving)
            } else if accepted.provider == "youtube", let entry = model.entry, let lookup {
                // Already downloaded: a staged replacement keeps the current audio playable.
                RecordingReplacementControls(entry: entry, accepted: accepted, repository: model.repository, lookup: lookup) {
                    Task { await model.show(model.index) }
                }
            }
        } else {
            ForEach(model.pendingCandidates) { candidate in
                ReviewCandidateRow(candidate: candidate, saving: model.saving,
                                   use: { confirming = candidate }, preview: { model.preview(candidate) },
                                   reject: { Task { await model.reject(candidate) } })
            }
            if model.pendingCandidates.isEmpty {
                Text(MatchingUserText.reason(item.reason) ?? "No suggestions found.").foregroundStyle(AppColors.textSecondary)
            }
            if let lookup, let entry = model.entry {
                ManualYouTubeSelectionView(entry: entry, repository: model.repository, lookup: lookup, accepted: nil,
                                           onConfirm: { try await model.saveManual($0) }) { Task { await model.advanceAfterResolve() } }
                    .id(entry.id) // A new song gets a fresh field: no previous link, preview or focus.
                if let url = YouTubeSearchProviderAdapter.browserSearchURL(entry.source) {
                    Button { openURL(url) } label: { Label("Search on YouTube", systemImage: "safari") }.buttonStyle(.matchingSecondary)
                }
            }
        }
    }
}

/// One candidate: full-width primary action, secondary actions below. Every row's
/// controls have their own hit areas; nothing from neighbouring rows overlaps them.
private struct ReviewCandidateRow: View {
    let candidate: PlaylistMigrationCandidate
    let saving: Bool
    let use: () -> Void
    let preview: () -> Void
    let reject: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: AppSpacing.sm) {
            CandidateSummaryCard(candidate: candidate)
            Button(candidate.provider == "youtube" ? "Use This Video" : "Use This Recording", action: use)
                .buttonStyle(.matchingPrimaryWide).disabled(saving)
                .accessibilityIdentifier("review-use-" + candidate.id.uuidString)
            HStack(spacing: AppSpacing.sm) {
                if candidate.provider == "youtube" {
                    Button("Preview", action: preview).buttonStyle(.matchingSecondaryWide)
                        .accessibilityLabel("Preview on YouTube").accessibilityIdentifier("review-preview-" + candidate.id.uuidString)
                }
                Button("Not This One", action: reject).buttonStyle(.matchingSecondaryWide).disabled(saving)
                    .accessibilityIdentifier("review-reject-" + candidate.id.uuidString)
            }
        }
        .padding(AppSpacing.md)
        .background(AppColors.backgroundSecondary, in: RoundedRectangle(cornerRadius: AppRadius.card, style: .continuous))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("review-candidate-" + candidate.id.uuidString)
    }
}
