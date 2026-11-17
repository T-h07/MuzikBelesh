import SwiftUI
import UniformTypeIdentifiers

/// Offline-download controls for one imported playlist. Every number is derived from
/// persisted occurrences, acquisition links and shared download jobs.
struct PlaylistAcquisitionControls: View {
    @ObservedObject var acquisition: PlaylistAcquisitionCoordinator
    let presentation: MigrationPlaylistPresentation
    let playlistID: String
    @State private var busy = false
    var body: some View {
        let summary = acquisition.summary(for: presentation)
        let migrationID = presentation.session.id.uuidString
        VStack(alignment: .leading, spacing: AppSpacing.sm) {
            Text("Offline Downloads").font(.headline)
            Text(headline(summary)).font(.subheadline.weight(.semibold)).foregroundStyle(AppColors.accentPrimary)
                .accessibilityIdentifier("acquisition-status")
            if summary.total > 0 {
                ProgressView(value: Double(summary.availableOffline), total: Double(summary.total)).tint(AppColors.accentPrimary)
                    .accessibilityLabel("Available offline").accessibilityValue("\(summary.availableOffline) of \(summary.total)")
            }
            let active = [count(summary.downloading, "downloading"), count(summary.queued, "queued"),
                          count(summary.waitingForWiFi, "waiting for Wi-Fi"), count(summary.verifying, "verifying"),
                          count(summary.paused, "paused")].compactMap { $0 }
            if !active.isEmpty { Text(active.joined(separator: " • ")).font(.caption).foregroundStyle(AppColors.textSecondary).accessibilityIdentifier("acquisition-active-breakdown") }
            let other = [count(summary.failed, "failed"), count(summary.unsupported, "unsupported source"),
                         count(summary.awaitingReview, "awaiting a confirmed match")].compactMap { $0 }
            if !other.isEmpty { Text(other.joined(separator: " • ")).font(.caption).foregroundStyle(AppColors.textSecondary).accessibilityIdentifier("acquisition-attention-breakdown") }
            if summary.waitingForWiFi > 0 {
                Text("Wi-Fi only is on. Downloads continue when Wi-Fi is available.").font(.caption).foregroundStyle(AppColors.textSecondary)
            }
            if summary.resourceLimited && summary.acquiring > 0 {
                Text("Low Power Mode or device temperature limits downloads to one at a time.").font(.caption).foregroundStyle(AppColors.textSecondary)
                    .accessibilityIdentifier("acquisition-resource-limited")
            }
            if let error = acquisition.lastError { Text(error).font(.caption).foregroundStyle(AppColors.error) }
            HStack(spacing: AppSpacing.sm) {
                if summary.userPaused {
                    Button { run { await acquisition.continueDownloads(migrationID: migrationID) } } label: { Label("Continue Downloads", systemImage: "arrow.down.circle") }
                        .buttonStyle(.matchingPrimary).accessibilityIdentifier("acquisition-continue")
                } else if summary.hasAcquisitionWork {
                    Button { run { await acquisition.pause(migrationID: migrationID) } } label: { Label("Pause Downloads", systemImage: "pause") }
                        .buttonStyle(.matchingPrimary).accessibilityIdentifier("acquisition-pause")
                }
                if summary.hasAcquisitionWork || summary.availableOffline > 0 {
                    NavigationLink { PlaylistAcquisitionQueueView(acquisition: acquisition, playlistID: playlistID) } label: { Text("View Queue") }
                        .buttonStyle(.matchingSecondary).accessibilityIdentifier("acquisition-view-queue")
                }
            }.disabled(busy)
            if summary.failed > 0 {
                Button { run { await acquisition.retryFailed(migrationID: migrationID) } } label: { Label("Retry Failed", systemImage: "arrow.clockwise") }
                    .buttonStyle(.matchingSecondary).disabled(busy).accessibilityIdentifier("acquisition-retry-failed")
            }
        }.padding(.vertical, AppSpacing.xs).accessibilityIdentifier("acquisition-controls")
    }
    private func count(_ value: Int, _ label: String) -> String? { value > 0 ? "\(value) \(label)" : nil }
    private func headline(_ summary: PlaylistAcquisitionSummary) -> String {
        if summary.total == 0 { return "Empty source playlist — no audio to acquire." }
        if summary.complete { return "All \(summary.total) songs available offline" }
        if summary.userPaused { return "Downloads paused • \(summary.availableOffline) of \(summary.total) available offline" }
        if summary.downloading > 0 { return "Downloading • \(summary.availableOffline) of \(summary.total) available offline" }
        if summary.acquiring > 0 { return "Waiting to download • \(summary.availableOffline) of \(summary.total) available offline" }
        return "\(summary.availableOffline) of \(summary.total) available offline"
    }
    private func run(_ action: @escaping @MainActor () async -> Void) {
        busy = true
        Task { await action(); busy = false }
    }
}

/// Playlist-scoped view of the single shared download queue, in source order.
struct PlaylistAcquisitionQueueView: View {
    @EnvironmentObject private var library: MusicLibraryService
    @EnvironmentObject private var container: AppContainer
    @ObservedObject var acquisition: PlaylistAcquisitionCoordinator
    let playlistID: String
    @State private var importing: PlaylistMigrationEntry?
    var body: some View {
        let rows = library.migrationRows(playlistID)
        let linked = rows.filter { $0.playableTrack == nil && acquisition.displayStates[$0.id] != nil }
        let attention = linked.filter { acquisition.displayStates[$0.id]?.needsAttention == true }
        let active = linked.filter { acquisition.displayStates[$0.id]?.isActive == true }
        let waiting = linked.filter { state in
            guard let value = acquisition.displayStates[state.id] else { return false }
            return !value.isActive && !value.needsAttention && value != .availableOffline
        }
        let done = rows.filter { $0.playableTrack != nil }
        List {
            if linked.isEmpty && done.isEmpty {
                Text("No confirmed songs are waiting to download. Review songs to confirm recordings.").foregroundStyle(AppColors.textSecondary)
            }
            section("Downloading", active)
            section("Waiting", waiting)
            section("Needs Attention", attention)
            if !attention.isEmpty, let issues = container.migrationIssues {
                Section {
                    NavigationLink { MigrationIssuesView(issues: issues, playlistID: playlistID) } label: {
                        Label("Open Migration Issues", systemImage: "exclamationmark.bubble")
                    }.accessibilityIdentifier("acquisition-open-issues")
                } footer: {
                    Text("Migration Issues explains each problem and lists every way to fix it.").foregroundStyle(AppColors.textSecondary)
                }.listRowBackground(AppColors.backgroundPrimary)
            }
            if !done.isEmpty {
                Section("Available Offline") {
                    Text("\(done.count) of \(rows.count) songs").foregroundStyle(AppColors.textSecondary)
                }.listRowBackground(AppColors.backgroundPrimary)
            }
        }.scrollContentBackground(.hidden).screenBackground()
            .navigationTitle("Download Queue").navigationBarTitleDisplayMode(.inline)
            .sheet(item: $importing) { AcquisitionLocalImportView(entry: $0) }
    }
    @ViewBuilder private func section(_ title: String, _ rows: [MigrationPlaylistRow]) -> some View {
        if !rows.isEmpty {
            Section(title) {
                ForEach(rows) { row in
                    AcquisitionQueueRow(row: row, state: acquisition.displayStates[row.id] ?? .queued,
                                        retry: { Task { await acquisition.retry(entryID: row.id) } },
                                        importFile: { importing = row.entry })
                }
            }.listRowBackground(AppColors.backgroundPrimary)
        }
    }
}

private struct AcquisitionQueueRow: View {
    let row: MigrationPlaylistRow
    let state: AcquisitionDisplayState
    let retry: () -> Void
    let importFile: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: AppSpacing.xs) {
            HStack(alignment: .firstTextBaseline) {
                Text("\(row.entry.position + 1).").foregroundStyle(AppColors.textSecondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(row.entry.source.title).foregroundStyle(AppColors.textPrimary).lineLimit(1)
                    Text(row.entry.source.primaryArtist ?? "Unknown Artist").font(.caption).foregroundStyle(AppColors.textSecondary).lineLimit(1)
                }
            }
            Text(state.label).font(.caption.weight(.semibold))
                .foregroundStyle(state.needsAttention ? AppColors.error : AppColors.accentPrimary)
                .accessibilityIdentifier("acquisition-entry-state-" + row.id.uuidString)
            if case .downloading(let progress?) = state {
                ProgressView(value: progress).tint(AppColors.accentPrimary)
            }
            if let detail = state.detail { Text(detail).font(.caption).foregroundStyle(AppColors.textSecondary) }
            if state.needsAttention {
                HStack(spacing: AppSpacing.sm) {
                    if case .failed(_, true) = state {
                        Button("Retry", action: retry).buttonStyle(.matchingSecondary)
                            .accessibilityIdentifier("acquisition-retry-" + row.id.uuidString)
                    }
                    Button("Import Audio from Files", action: importFile).buttonStyle(.matchingSecondary)
                        .accessibilityIdentifier("acquisition-import-" + row.id.uuidString)
                }
            }
        }.padding(.vertical, 2)
    }
}

/// Per-occurrence acquisition state in the playlist list and the entry inspector.
struct AcquisitionOccurrenceStatus: View {
    @ObservedObject var acquisition: PlaylistAcquisitionCoordinator
    let row: MigrationPlaylistRow
    var body: some View {
        let state = row.playableTrack == nil ? acquisition.displayStates[row.id] : nil
        MigrationOccurrenceStatusText(row: row, text: state?.label ?? row.effectiveStatus.displayName,
                                      attention: state?.needsAttention == true).equatable()
    }
}

struct MigrationOccurrenceStatusText: View, Equatable {
    let row: MigrationPlaylistRow
    let text: String
    let attention: Bool
    var body: some View {
        Text(text).font(.caption).foregroundStyle(attention ? AppColors.error : AppColors.textSecondary)
            .accessibilityIdentifier("migration-entry-status-" + row.id.uuidString)
    }
}

/// Acquisition details and fallback actions in the occurrence inspector.
struct AcquisitionOccurrenceSection: View {
    @ObservedObject var acquisition: PlaylistAcquisitionCoordinator
    let row: MigrationPlaylistRow
    @State private var importing: PlaylistMigrationEntry?
    var body: some View {
        let state = row.playableTrack == nil ? acquisition.displayStates[row.id] : nil
        let unresolved = row.entry.localTrackID == nil && [.pending, .matching, .needsReview, .matched, .failed, .unavailable].contains(row.entry.status)
        if state != nil || unresolved {
            Section("Offline Audio") {
                if let state {
                    Text(state.label).accessibilityIdentifier("acquisition-inspector-state")
                    if case .downloading(let progress?) = state { ProgressView(value: progress).tint(AppColors.accentPrimary) }
                    if let detail = state.detail { Text(detail).font(.caption).foregroundStyle(AppColors.textSecondary) }
                    if case .failed(_, true) = state {
                        Button("Retry Download") { Task { await acquisition.retry(entryID: row.id) } }
                            .buttonStyle(.matchingSecondary).accessibilityIdentifier("acquisition-inspector-retry")
                    }
                }
                if unresolved {
                    Button("Import Audio from Files") { importing = row.entry }
                        .buttonStyle(.matchingSecondary).accessibilityIdentifier("acquisition-inspector-import")
                    Text("Use a local MP3 or M4A file when this recording cannot be downloaded. You confirm the file before it is used.")
                        .font(.caption).foregroundStyle(AppColors.textSecondary)
                }
            }.sheet(item: $importing) { AcquisitionLocalImportView(entry: $0) }
        }
    }
}

/// Manual fallback: validate and import one file through the normal storage pipeline,
/// show both sets of metadata, then require explicit confirmation before associating it
/// with the existing occurrence (no new playlist entry is created).
struct AcquisitionLocalImportView: View {
    @EnvironmentObject private var library: MusicLibraryService
    @Environment(\.dismiss) private var dismiss
    let entry: PlaylistMigrationEntry
    @State private var showingFiles = false
    @State private var imported: ImportResult?
    @State private var working = false
    @State private var confirming = false
    @State private var error: String?
    var body: some View {
        NavigationStack {
            List {
                Section("Original Spotify Occurrence") { MigrationSourceMetadataView(source: entry.source, showsIdentity: true) }
                Section {
                    Text("Choose an audio file (MP3, M4A, AAC, WAV, AIFF or CAF). It is validated and stored in your library first; this song uses it only after you confirm it is the intended recording.")
                        .font(.caption).foregroundStyle(AppColors.textSecondary)
                    Button { showingFiles = true } label: { Label(imported == nil ? "Choose Audio File" : "Choose a Different File", systemImage: "folder") }
                        .buttonStyle(.matchingPrimaryWide).disabled(working).accessibilityIdentifier("acquisition-choose-file")
                    if working { ProgressView().tint(AppColors.accentPrimary) }
                    if let error { Text(error).foregroundStyle(AppColors.error) }
                }
                if let track = imported?.track {
                    Section("Imported File") {
                        LabeledContent("Title", value: track.title)
                        LabeledContent("Artist", value: library.artistName(track.artistID))
                        LabeledContent("Album", value: library.albumTitle(track.albumID))
                        if let ms = track.durationMs { LabeledContent("Duration", value: "\(ms / 60000):\(String(format: "%02d", (ms / 1000) % 60))") }
                        LabeledContent("Format", value: track.fileExtension.uppercased())
                        LabeledContent("Size", value: ByteCountFormatter.string(fromByteCount: track.fileSizeBytes, countStyle: .file))
                        if let name = track.originalFilename { LabeledContent("File", value: name) }
                        if imported?.duplicate == true { Text("This audio was already in your library; the existing copy is reused.").font(.caption) }
                        Button("Use for This Song") { confirming = true }
                            .buttonStyle(.matchingPrimaryWide).disabled(working).accessibilityIdentifier("acquisition-confirm-file")
                    }
                }
            }.scrollContentBackground(.hidden).screenBackground().navigationTitle("Import Audio")
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() }.disabled(working) } }
                .fileImporter(isPresented: $showingFiles, allowedContentTypes: [.audio, .supportedAudio], allowsMultipleSelection: false) { result in
                    guard case .success(let urls) = result, let url = urls.first else { return }
                    importFile(url)
                }
                .confirmationDialog("Is this the intended recording?", isPresented: $confirming, titleVisibility: .visible) {
                    Button("Confirm Recording") { confirm() }
                    Button("Cancel", role: .cancel) { }
                } message: {
                    Text("“\(imported?.track.title ?? "")” will be used for “\(entry.source.title)”. The Spotify entry and its position are preserved.")
                }
        }.interactiveDismissDisabled(working)
    }
    private func importFile(_ url: URL) {
        guard let storage = library.storage else { return }
        working = true; error = nil
        Task {
            defer { working = false }
            do { imported = try await storage.importAudio(from: url) }
            catch { self.error = "This file could not be imported. Choose a supported, playable audio file." }
        }
    }
    private func confirm() {
        guard let track = imported?.track, let repository = library.storage?.playlistMigrations else { return }
        working = true
        Task {
            defer { working = false }
            do { try await repository.confirmImportedRecording(for: entry, trackID: track.id); dismiss() }
            catch { self.error = "The audio could not be verified, or this song changed. Close and reopen it, then try again." }
        }
    }
}

/// Destination for a playlist-ready notification.
struct NotificationPlaylistSheet: View {
    @Environment(\.dismiss) private var dismiss
    let playlistID: String
    var body: some View {
        NavigationStack {
            PlaylistDetailView(playlistID: playlistID)
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } } }
        }
    }
}
