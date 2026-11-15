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
            error = nil
        } catch { self.error = "This song couldn't be loaded." }
    }
    func next() async { if index + 1 < items.count { await show(index + 1) } }
    func previous() async { if index > 0 { await show(index - 1) } }
    /// Skip for Now: leaves the song unresolved and moves on (no confirmation).
    func skip() async { await advance(markingResolved: false) }

    /// Use This Video/Recording for an already-discovered candidate.
    func select(_ candidate: PlaylistMigrationCandidate) async {
        guard let entry else { return }
        do {
            try await repository.selectCandidate(for: entry, candidateID: candidate.id)
            await advance(markingResolved: true)
        } catch SongMatchingError.staleAttempt { error = "This song is being updated. Try again in a moment."; await show(index) }
        catch { self.error = "This recording couldn't be saved."; await show(index) }
    }
    /// Confirm a pasted YouTube link. Saves inside the app (pending acquisition) and advances.
    func confirmManual(_ result: YouTubeManualLookupResult) async throws {
        guard let entry else { return }
        try await repository.confirmYouTubeCandidate(for: entry, video: result.video, metadataVerified: result.metadataVerified)
        await advance(markingResolved: true)
    }
    func reject(_ candidate: PlaylistMigrationCandidate) async {
        do {
            try await repository.rejectCandidate(entryID: candidate.entryID, candidateID: candidate.id)
            if candidate.decision == .accepted { resolved.remove(candidate.entryID); caughtUp = false }
        } catch { self.error = "That couldn't be changed. Try again." }
        await show(index)
    }
    func preview(_ candidate: PlaylistMigrationCandidate) {
        if let url = MatchingCandidateArtwork.watchURL(candidate) { openURL(url) }
    }

    private func advance(markingResolved: Bool) async {
        guard let current else { return }
        if markingResolved { resolved.insert(current.id) }
        let count = items.count
        // Next unresolved after the current one, wrapping; the current item counts only when skipping alone.
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
    @StateObject private var model: MigrationReviewQueueModel
    private let lookup: YouTubeManualLookup?
    init(model: @autoclosure @escaping () -> MigrationReviewQueueModel, lookup: YouTubeManualLookup?) {
        _model = StateObject(wrappedValue: model()); self.lookup = lookup
    }
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @State private var confirming: PlaylistMigrationCandidate?
    @State private var drag: CGFloat = 0
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: AppSpacing.md) {
                if !model.loaded { ProgressView().frame(maxWidth: .infinity) }
                else if model.caughtUp { caughtUp }
                else if let item = model.current { card(item) }
                if let error = model.error { Text(error).foregroundStyle(AppColors.error) }
            }.padding()
        }
        .background(AppColors.backgroundPrimary.ignoresSafeArea())
        .tint(AppColors.accentPrimary)
        .navigationTitle(model.caughtUp || !model.loaded ? "Review Songs" : "Review \(model.position) of \(model.items.count)")
        .navigationBarTitleDisplayMode(.inline)
        .task { model.openURL = { openURL($0) }; if !model.loaded { await model.load() } }
        .confirmationDialog("Use this recording?", isPresented: Binding(get: { confirming != nil }, set: { if !$0 { confirming = nil } }),
                            titleVisibility: .visible, presenting: confirming) { candidate in
            Button("Use This Recording") { Task { await model.select(candidate) } }
            Button("Cancel", role: .cancel) { confirming = nil }
        } message: { candidate in
            Text(CandidateSummaryCard.warning(candidate).map { "\($0). Use it only if this is the right song." }
                 ?? "It's linked to this song. Nothing is downloaded yet.")
        }
    }

    private var caughtUp: some View {
        VStack(spacing: AppSpacing.md) {
            Image(systemName: "checkmark.circle.fill").font(.system(size: 48)).foregroundStyle(AppColors.accentPrimary).accessibilityHidden(true)
            Text("You're all caught up.").font(.title3.weight(.semibold))
            Button("Back to Playlist") { dismiss() }.buttonStyle(.borderedProminent).frame(minHeight: 44)
        }.frame(maxWidth: .infinity).padding(.top, 40).accessibilityIdentifier("review-caught-up")
    }

    @ViewBuilder private func card(_ item: MigrationResolutionItem) -> some View {
        let source = item.entry.source
        VStack(alignment: .leading, spacing: 4) {
            Text("\(model.remaining) left to review").font(.caption).foregroundStyle(AppColors.textSecondary)
            Text(source.title).font(.title3.weight(.semibold))
            Text([source.primaryArtist, source.album, CandidateSummaryCard.duration(source.durationMs)].compactMap { $0 }.joined(separator: " · "))
                .font(.subheadline).foregroundStyle(AppColors.textSecondary)
        }.accessibilityElement(children: .combine)
        .offset(x: drag)
        .gesture(DragGesture(minimumDistance: 30)
            .onChanged { drag = $0.translation.width / 4 }
            .onEnded { value in
                drag = 0
                // Swiping only navigates; it never confirms or rejects.
                if value.translation.width < -80 { Task { await model.next() } }
                else if value.translation.width > 80 { Task { await model.previous() } }
            })

        if let accepted = model.accepted {
            CandidateSummaryCard(candidate: accepted)
            Text(accepted.provider == "youtube" ? "Selected · Not downloaded yet" : "Selected · Available offline")
                .font(.caption).foregroundStyle(AppColors.accentPrimary)
            if accepted.provider == "youtube" {
                Button("Change Video", role: .destructive) { Task { await model.reject(accepted) } }.buttonStyle(.bordered).frame(minHeight: 44)
            }
        } else {
            ForEach(model.pendingCandidates.prefix(3)) { candidate in
                VStack(alignment: .leading, spacing: AppSpacing.sm) {
                    CandidateSummaryCard(candidate: candidate)
                    HStack(spacing: AppSpacing.sm) {
                        Button(candidate.provider == "youtube" ? "Use This Video" : "Use This Recording") { confirming = candidate }
                            .buttonStyle(.borderedProminent).frame(minHeight: 44)
                            .accessibilityIdentifier("review-use-" + candidate.id.uuidString)
                        if candidate.provider == "youtube" {
                            Button("Preview") { model.preview(candidate) }.buttonStyle(.bordered).frame(minHeight: 44)
                                .accessibilityLabel("Preview on YouTube")
                        }
                        Button("Not This One") { Task { await model.reject(candidate) } }.buttonStyle(.borderless).frame(minHeight: 44)
                    }
                }.padding(.vertical, 6)
            }
            if model.pendingCandidates.isEmpty {
                Text(MatchingUserText.reason(item.reason) ?? "No suggestions found.").foregroundStyle(AppColors.textSecondary)
            }
            if let lookup, let entry = model.entry {
                ManualYouTubeSelectionView(entry: entry, repository: model.repository, lookup: lookup, accepted: nil,
                                           onConfirm: { try await model.confirmManual($0) }) { }
                if let url = YouTubeSearchProviderAdapter.browserSearchURL(entry.source) {
                    Button { openURL(url) } label: { Label("Search on YouTube", systemImage: "safari") }.buttonStyle(.borderless).frame(minHeight: 44)
                }
            }
        }

        HStack {
            Button { Task { await model.previous() } } label: { Label("Previous", systemImage: "chevron.left") }
                .disabled(model.index == 0).frame(minHeight: 44)
            Spacer()
            Button("Skip for Now") { Task { await model.skip() } }.buttonStyle(.bordered).frame(minHeight: 44)
                .accessibilityIdentifier("review-skip")
            Spacer()
            Button { Task { await model.next() } } label: { Label("Next", systemImage: "chevron.right").labelStyle(.titleAndIcon) }
                .disabled(model.index + 1 >= model.items.count).frame(minHeight: 44)
        }.buttonStyle(.borderless)
    }
}
