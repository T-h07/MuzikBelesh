import SwiftUI

/// Resolution counter and entry point to the unresolved-songs workflow.
struct MigrationResolutionSummaryLink: View {
    let playlistID: String
    let session: PlaylistMigrationSession
    let repository: GRDBPlaylistMigrationRepository
    @State private var overview: MigrationResolutionOverview?
    var body: some View {
        NavigationLink {
            MigrationResolutionListView(playlistID: playlistID, migrationID: session.id, repository: repository)
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                Label("All Songs by Status", systemImage: "list.bullet.rectangle")
                if let overview { Text(overview.summary).font(.caption).foregroundStyle(AppColors.textSecondary) }
            }.frame(minHeight: 44)
        }.accessibilityIdentifier("migration-resolution-list")
            .task(id: session.updatedAt) { overview = try? await repository.resolutionOverview(migrationID: session.id) }
    }
}

struct MigrationResolutionListView: View {
    @EnvironmentObject private var library: MusicLibraryService
    let playlistID: String
    let migrationID: UUID
    let repository: GRDBPlaylistMigrationRepository
    @State private var overview: MigrationResolutionOverview?
    @State private var filter: MigrationResolutionCategory = .needsReview
    @State private var error: String?
    private let filters: [MigrationResolutionCategory] = [.confirmed, .needsReview, .discoveryFailed, .discoveryDeferred, .noCandidate, .awaiting]
    var body: some View {
        List {
            if let overview {
                Section {
                    Text(overview.summary).font(.headline).accessibilityIdentifier("migration-resolution-summary")
                    Picker("Show", selection: $filter) {
                        ForEach(filters, id: \.self) { Text("\($0.title) (\(overview.count($0)))").tag($0) }
                    }
                }
                Section(filter.title) {
                    let items = overview.items.filter { $0.category == filter }
                    if items.isEmpty { Text("No entries in this group.").foregroundStyle(AppColors.textSecondary) }
                    ForEach(items) { item in
                        NavigationLink {
                            MigrationOccurrenceDetailView(playlistID: playlistID, occurrenceID: item.id)
                        } label: {
                            VStack(alignment: .leading, spacing: 3) {
                                Text("\(item.entry.position + 1). \(item.entry.source.title)").font(.body)
                                Text(([item.entry.source.primaryArtist] + [item.entry.source.album]).compactMap { $0 }.joined(separator: " • "))
                                    .font(.caption).foregroundStyle(AppColors.textSecondary)
                                if item.pendingCandidates > 0 && item.category.isUnresolved {
                                    Text("\(item.pendingCandidates) suggestion\(item.pendingCandidates == 1 ? "" : "s")").font(.caption)
                                }
                                if item.category.isUnresolved, item.category != .needsReview, let reason = MatchingUserText.reason(item.reason) {
                                    Text(reason).font(.caption).foregroundStyle(AppColors.textSecondary)
                                }
                            }
                        }.accessibilityIdentifier("migration-resolution-" + item.id.uuidString)
                    }
                }
            } else if let error { Text(error) } else { ProgressView() }
        }.scrollContentBackground(.hidden).screenBackground().tint(AppColors.accentPrimary)
            .navigationTitle("Song Resolution").navigationBarTitleDisplayMode(.inline)
            .task(id: library.snapshot.migrationPresentations[playlistID]?.session.updatedAt) { await load() }
            .refreshable { await load() }
            .onAppear { Task { await load() } }
    }
    private func load() async {
        do { overview = try await repository.resolutionOverview(migrationID: migrationID); error = nil }
        catch { self.error = "Resolution status could not be read. Reopen this screen to retry." }
    }
}

/// Retry one unresolved occurrence without touching any other entry.
struct MigrationRetrySongButton: View {
    @ObservedObject var model: PlaylistMatchingViewModel
    let entry: PlaylistMigrationEntry
    var body: some View {
        Button("Retry This Song") { model.retry(entry.migrationID, entry: entry.id) }
            .disabled(model.busy).frame(minHeight: 44).accessibilityIdentifier("migration-retry-song")
    }
}
