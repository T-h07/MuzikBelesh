import SwiftUI

struct MigrationPlaylistPlaybackHeader: View {
    @EnvironmentObject private var library: MusicLibraryService
    @Environment(\.scenePhase) private var scenePhase
    let playlistID: String
    var body: some View {
        let rows = library.migrationRows(playlistID)
        let manual = library.manualRows(playlistID)
        let ready = (library.snapshot.migrationPresentations[playlistID]?.progress.ready ?? 0) + manual.filter(\.available).count
        VStack(alignment: .leading, spacing: AppSpacing.md) {
            Text("\(rows.count) imported • \(manual.count) manually added • \(rows.count + manual.count) total • \(ready) available offline")
                .font(.caption).foregroundStyle(AppColors.textSecondary).accessibilityIdentifier("migration-playlist-count")
            HStack {
                Button { Task { await library.playMigration(playlistID: playlistID) } } label: {
                    Label("Play", systemImage: "play.fill").frame(maxWidth: .infinity, minHeight: 44)
                }.buttonStyle(.borderedProminent).tint(AppColors.accentPrimary).foregroundStyle(.black).accessibilityIdentifier("collection-play")
                Button { Task { await library.playMigration(playlistID: playlistID, shuffle: true) } } label: {
                    Label("Shuffle", systemImage: "shuffle").frame(maxWidth: .infinity, minHeight: 44)
                }.buttonStyle(.bordered).tint(AppColors.accentPrimary).accessibilityIdentifier("collection-shuffle")
            }.disabled(ready == 0)
            if ready == 0 {
                Text(rows.isEmpty ? "This source playlist is empty." : "Source songs are saved. No local audio is available yet.")
                    .font(.caption).foregroundStyle(AppColors.textSecondary)
            }
        }.task { await recover() }
            .onChange(of: scenePhase) { _, phase in if phase == .active { Task { await recover() } } }
    }
    private func recover() async {
        guard let repository = library.storage?.playlistMigrations else { return }
        // Filesystem recovery is bounded and awaited; never scan files in row rendering.
        do { try await Task.detached(priority: .utility) { try repository.recover() }.value }
        catch { library.report(error) }
    }
}

struct MigrationPlaylistOccurrenceRow: View {
    @EnvironmentObject private var library: MusicLibraryService
    let row: MigrationPlaylistRow
    let playlistID: String
    var body: some View {
        HStack(spacing: AppSpacing.sm) {
            NavigationLink {
                MigrationOccurrenceDetailView(playlistID: playlistID, occurrenceID: row.id)
            } label: {
                MigrationOccurrenceLabel(row: row).equatable()
            }.accessibilityIdentifier("migration-occurrence-" + row.id.uuidString)
            if row.playableTrack != nil {
                Button { Task { await library.playMigration(playlistID: playlistID, occurrenceID: row.id.uuidString) } } label: {
                    Image(systemName: "play.circle.fill").frame(width: 44, height: 44)
                }.buttonStyle(.borderless).tint(AppColors.accentPrimary)
                    .accessibilityLabel("Play \(row.entry.source.title), source position \(row.entry.position + 1)")
                    .accessibilityIdentifier("migration-occurrence-play-" + row.id.uuidString)
            }
        }
    }
}

private struct MigrationOccurrenceLabel: View, Equatable {
    let row: MigrationPlaylistRow
    var body: some View {
        HStack(spacing: AppSpacing.md) {
            if let track = row.playableTrack { StoredArtworkView(track: track, size: 44) }
            else {
                Image(systemName: "music.note.list").foregroundStyle(AppColors.textSecondary)
                    .frame(width: 44, height: 44).background(AppColors.backgroundPrimary)
                    .accessibilityLabel("Placeholder artwork")
                    .accessibilityIdentifier("migration-artwork-fallback-" + row.id.uuidString)
            }
            VStack(alignment: .leading, spacing: 4) {
                MigrationSourceMetadataView(source: row.entry.source)
                Text(row.effectiveStatus.displayName).font(.caption).foregroundStyle(AppColors.textSecondary)
                    .accessibilityIdentifier("migration-entry-status-" + row.id.uuidString)
            }
        }.padding(.vertical, 4)
    }
}

struct MigrationSourceMetadataView: View {
    let source: PlaylistMigrationSourceTrack
    var showsIdentity = false
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text("\(source.position + 1).").foregroundStyle(AppColors.textSecondary).accessibilityLabel("Source position \(source.position + 1)")
                Text(source.title).foregroundStyle(AppColors.textPrimary)
            }
            Text(source.primaryArtist ?? "Unknown Artist").font(.caption).foregroundStyle(AppColors.textSecondary)
            if !source.additionalArtists.isEmpty { Text(source.additionalArtists.joined(separator: ", ")).font(.caption).foregroundStyle(AppColors.textSecondary) }
            if let album = source.album { Text(album).font(.caption).foregroundStyle(AppColors.textSecondary) }
            if let ms = source.durationMs { Text("\(ms / 60000):\(String(format: "%02d", (ms / 1000) % 60))").font(.caption).foregroundStyle(AppColors.textSecondary) }
            if showsIdentity, let id = source.sourceTrackID { Text("Source track: \(id)").font(.caption).textSelection(.enabled) }
            // No source URLs, provider requests, or remote artwork loads.
        }
    }
}

struct MigrationPlaylistDashboard: View {
    @EnvironmentObject private var library: MusicLibraryService
    @EnvironmentObject private var container: AppContainer
    let playlistID: String
    @State private var expanded = false
    var body: some View {
        if let value = library.snapshot.migrationPresentations[playlistID] {
            Section {
                Button {
                    expanded.toggle()
                } label: {
                    Label(expanded ? "Hide Migration Details" : "Show Migration Details", systemImage: expanded ? "chevron.up" : "chevron.down")
                        .frame(minHeight: 44)
                }.accessibilityIdentifier("migration-dashboard-toggle")
                    .accessibilityValue(expanded ? "Expanded" : "Collapsed")
                Text("\(value.session.source.displayName) • \(value.rows.count) entries • \(value.session.status.displayName)").font(.caption)
                MigrationProgressOverview(progress: value.progress)
                if let model = container.playlistMatching, let repository = library.storage?.playlistMigrations {
                    PlaylistMatchingControls(model: model, session: value.session, repository: repository)
                }
                if expanded {
                    LabeledContent("Original playlist", value: value.session.sourcePlaylistName)
                    LabeledContent("Source provider", value: value.session.source.displayName)
                    LabeledContent("Original entries", value: String(value.session.expectedEntryCount))
                    LabeledContent("Imported", value: value.session.createdAt.formatted(date: .abbreviated, time: .shortened))
                    LabeledContent("Lifecycle", value: value.session.status.displayName)
                    LabeledContent("Pending or active", value: String(value.progress.pendingOrActive))
                    LabeledContent("Review required", value: String(value.progress.needsReview))
                    LabeledContent("Failed or unavailable", value: String(value.progress.failed + value.progress.unavailable))
                    Text("Entry Status Breakdown").font(.headline)
                    ForEach(PlaylistMigrationEntryStatus.allCases, id: \.self) { status in
                        LabeledContent(status == .pending ? "Pending / awaiting local audio" : status.displayName, value: String(value.statusCounts[status, default: 0]))
                            .accessibilityIdentifier("migration-breakdown-" + status.rawValue)
                    }
                    Text("Issues").font(.headline)
                    if let failure = value.session.failureInformation { Text(failure).foregroundStyle(AppColors.error) }
                    if value.issues.isEmpty { Text("No recorded migration issues.").foregroundStyle(AppColors.textSecondary) }
                    ForEach(value.issues) { issue in
                        MigrationIssueView(issue: issue, position: issue.entryID.flatMap { value.rowsByID[$0]?.entry.position })
                    }
                }
            }.listRowBackground(AppColors.backgroundPrimary)
        }
    }
}

struct MigrationProgressOverview: View {
    let progress: PlaylistMigrationProgress
    var body: some View {
        VStack(alignment: .leading, spacing: AppSpacing.sm) {
            Text("Metadata: \(progress.actual) / \(progress.expected) imported")
            Text(progress.metadataComplete ? "Metadata complete" : "Source snapshot incomplete").font(.caption)
            if progress.expected > 0 {
                ProgressView(value: Double(min(progress.actual, progress.expected)), total: Double(progress.expected))
                    .accessibilityLabel("Metadata imported").accessibilityValue("\(progress.actual) of \(progress.expected)")
            }
            Text("Available offline: \(progress.ready) / \(progress.actual)").accessibilityIdentifier("migration-available-offline-count")
            if progress.actual > 0 {
                ProgressView(value: Double(progress.ready), total: Double(progress.actual))
                    .accessibilityLabel("Audio available offline").accessibilityValue("\(progress.ready) of \(progress.actual)")
            }
            Text("Unresolved: \(progress.unresolved)").accessibilityIdentifier("migration-unresolved-count")
            if progress.actual == 0 { Text("Empty source playlist — no audio to acquire.").font(.caption) }
        }.tint(AppColors.accentPrimary).accessibilityIdentifier("migration-overall-progress")
    }
}

struct MigrationOccurrenceDetailView: View {
    @EnvironmentObject private var library: MusicLibraryService
    @EnvironmentObject private var container: AppContainer
    let playlistID: String
    let occurrenceID: UUID
    @State private var resolving: PlaylistMigrationEntry?
    var body: some View {
        List {
            if let value = library.snapshot.migrationPresentations[playlistID], let row = value.rowsByID[occurrenceID] {
                Section("Original Source Entry") { MigrationSourceMetadataView(source: row.entry.source, showsIdentity: true) }
                Section("Current State") {
                    Text(row.effectiveStatus.displayName).accessibilityIdentifier("migration-inspector-status")
                    Text(row.playableTrack == nil ? "No verified local audio available" : "Verified local audio associated and available")
                    if let id = row.entry.localTrackID { Text("Associated recording: \(id)").font(.caption) }
                    if row.entry.localTrackID == nil && [.pending, .matching, .needsReview, .unavailable, .failed].contains(row.entry.status) {
                        Button("Resolve Existing Placeholder") { resolving = row.entry }.frame(minHeight: 44)
                        Text("Choose and confirm an existing local recording for this Spotify occurrence. To append a separate occurrence, use Add Songs in the playlist.").font(.caption)
                    }
                }
                if let repository = library.storage?.playlistMigrations {
                    MigrationCandidateInspection(entry: row.entry, repository: repository, lookup: container.youtubeManualLookup)
                }
                Section("Entry Issues") {
                    let issues = value.issuesByEntry[occurrenceID] ?? []
                    if issues.isEmpty { Text("No recorded issues for this entry.") }
                    ForEach(issues) { MigrationIssueView(issue: $0, position: row.entry.position) }
                }
            } else { Text("This migration entry is no longer available.") }
        }.scrollContentBackground(.hidden).screenBackground()
            .navigationTitle("Source Entry").navigationBarTitleDisplayMode(.inline)
            .sheet(item: $resolving) { ResolveMigrationPlaceholderView(entry: $0) }
    }
}

private struct MigrationIssueView: View {
    let issue: PlaylistMigrationIssue
    let position: Int?
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("\(issue.severity.rawValue.capitalized) • \(issue.resolution.rawValue.capitalized)").font(.caption)
            if let position { Text("Source position \(position + 1)").font(.caption) }
            Text(issue.message)
            if let details = issue.technicalDetails { Text(details).font(.caption).foregroundStyle(AppColors.textSecondary) }
        }.accessibilityIdentifier("migration-issue-" + issue.id.uuidString)
    }
}

extension PlaylistMigrationEntryStatus {
    var displayName: String {
        switch self {
        case .pending: return "Awaiting local audio"
        case .matching: return "Matching"
        case .needsReview: return "Needs review"
        case .matched: return "Matched"
        case .queued: return "Queued"
        case .downloading: return "Downloading"
        case .verifying: return "Verifying"
        case .ready: return "Available offline"
        case .unavailable: return "Local audio unavailable"
        case .failed: return "Failed"
        case .skipped: return "Skipped"
        }
    }
}

extension PlaylistMigrationSource {
    var displayName: String {
        switch self {
        case .spotifyAccountExport: return "Spotify account export"
        case .exportify: return "Spotify / Exportify"
        case .spotifyAPI: return "Spotify"
        }
    }
}

extension PlaylistMigrationStatus {
    var displayName: String {
        switch self {
        case .preparing: return "Preparing"
        case .importingMetadata: return "Importing metadata"
        case .metadataReady: return "Metadata ready — awaiting local audio"
        case .matching: return "Matching"
        case .awaitingReview: return "Awaiting review"
        case .downloading: return "Downloading"
        case .verifying: return "Verifying"
        case .completed: return "Completed"
        case .partiallyCompleted: return "Partially completed"
        case .paused: return "Paused"
        case .cancelled: return "Cancelled"
        case .failed: return "Failed"
        }
    }
}
