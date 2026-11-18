import SwiftUI
import UIKit
import UniformTypeIdentifiers

// MARK: - Hub

/// Phase 11.4 "Music Sharing" hub, opened from Profile, Settings and Library.
struct LibrarySharingHubView: View {
    @Environment(\.themePalette) private var palette
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var container: AppContainer
    @State private var exporting = false
    @State private var importing = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: AppSpacing.section) {
                    SharingExplainer()
                    VStack(spacing: 0) {
                        SharingActionRow(title: "Export Library", detail: "Share your playlists and songs as a file", icon: "square.and.arrow.up",
                                         identifier: "sharing-export") { exporting = true }
                        Divider().overlay(AppColors.divider)
                        SharingActionRow(title: "Import Muzik Belesh Library", detail: "Open a .mbelesh file someone shared with you",
                                         icon: "square.and.arrow.down", identifier: "sharing-import") { importing = true }
                    }
                    .padding(.horizontal, AppSpacing.lg)
                    .background(AppColors.backgroundSecondary).clipShape(RoundedRectangle(cornerRadius: AppRadius.card))
                    .disabled(!container.sharing.isAvailable)
                    PortableImportActivityList(sharing: container.sharing)
                }
                .padding(AppSpacing.lg)
            }
            .screenBackground()
            .navigationTitle("Music Sharing")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() }.accessibilityIdentifier("sharing-done") } }
            .sheet(isPresented: $exporting) { LibraryExportView(initialScope: .library) }
            .sheet(isPresented: $importing) { LibraryImportView() }
        }
    }
}

private struct SharingExplainer: View {
    @Environment(\.themePalette) private var palette
    var body: some View {
        HStack(alignment: .top, spacing: AppSpacing.md) {
            Image(systemName: "music.note.list").font(.title2).foregroundStyle(palette.accent).frame(width: 32)
            VStack(alignment: .leading, spacing: AppSpacing.xs) {
                Text("Share your music, not your files").font(.headline).foregroundStyle(AppColors.textPrimary)
                Text("A Muzik Belesh library file lists songs and playlists. It never contains audio, your profile, listening activity or settings. Songs are downloaded again on the receiving iPhone.")
                    .font(.subheadline).foregroundStyle(AppColors.textSecondary)
            }
        }.frame(maxWidth: .infinity, alignment: .leading).cardSurface()
    }
}

private struct SharingActionRow: View {
    @Environment(\.themePalette) private var palette
    let title: String
    let detail: String
    let icon: String
    let identifier: String
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(spacing: AppSpacing.md) {
                Image(systemName: icon).foregroundStyle(palette.accent).frame(width: 24)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).foregroundStyle(AppColors.textPrimary)
                    Text(detail).font(.caption).foregroundStyle(AppColors.textSecondary)
                }
                Spacer()
                Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(AppColors.textTertiary)
            }.frame(minHeight: 60).contentShape(Rectangle())
        }.buttonStyle(.plain).accessibilityIdentifier(identifier)
    }
}

// MARK: - Export

struct LibraryExportView: View {
    @Environment(\.themePalette) private var palette
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var container: AppContainer
    @EnvironmentObject private var library: MusicLibraryService

    enum Mode: String, CaseIterable, Identifiable { case playlist = "This Playlist", choose = "Playlists", library = "Entire Library"; var id: String { rawValue } }

    let initialScope: LibraryExportScope
    @State private var mode: Mode = .library
    @State private var chosen: Set<String> = []
    @State private var plan: PortableLibraryExportPlan?
    @State private var loading = false
    @State private var failure: String?
    @State private var share: PreparedLibraryShare?
    @State private var saving: PreparedLibraryShare?
    @State private var preparing = false

    init(initialScope: LibraryExportScope) {
        self.initialScope = initialScope
        switch initialScope {
        case .playlist(let id): _mode = State(initialValue: .playlist); _chosen = State(initialValue: [id])
        case .playlists(let ids): _mode = State(initialValue: .choose); _chosen = State(initialValue: Set(ids))
        case .library: _mode = State(initialValue: .library)
        }
    }

    private var modes: [Mode] {
        if case .playlist = initialScope { return Mode.allCases }
        return [.choose, .library]
    }

    private var scope: LibraryExportScope? {
        switch mode {
        case .library: return .library
        case .playlist:
            if case .playlist(let id) = initialScope { return .playlist(id) }
            return nil
        case .choose:
            let ids = library.snapshot.playlists.map(\.id).filter(chosen.contains)
            return ids.isEmpty ? nil : .playlists(ids)
        }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: AppSpacing.xl) {
                    Picker("Export", selection: $mode) { ForEach(modes) { Text($0.rawValue).tag($0) } }
                        .pickerStyle(.segmented).accessibilityIdentifier("export-scope")
                    if mode == .choose { playlistChooser }
                    summary
                    privacy
                    actions
                }.padding(AppSpacing.lg)
            }
            .screenBackground()
            .navigationTitle("Export")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() }.accessibilityIdentifier("export-close") } }
            .task(id: scope) { await load() }
            .sheet(item: $share) { LibraryShareSheet(url: $0.url).ignoresSafeArea() }
            .sheet(item: $saving) { LibraryExportPicker(url: $0.url) }
        }
    }

    private var playlistChooser: some View {
        VStack(alignment: .leading, spacing: AppSpacing.sm) {
            HStack {
                Text("PLAYLISTS").font(.caption.weight(.semibold)).foregroundStyle(AppColors.textSecondary)
                Spacer()
                Button(chosen.count == library.snapshot.playlists.count ? "Select None" : "Select All") {
                    chosen = chosen.count == library.snapshot.playlists.count ? [] : Set(library.snapshot.playlists.map(\.id))
                }.font(.caption.weight(.semibold)).foregroundStyle(palette.accent)
            }
            VStack(spacing: 0) {
                if library.snapshot.playlists.isEmpty {
                    Text("You have no playlists yet.").font(.subheadline).foregroundStyle(AppColors.textSecondary).frame(maxWidth: .infinity, minHeight: 52, alignment: .leading)
                }
                ForEach(library.snapshot.playlists) { playlist in
                    Button {
                        if chosen.contains(playlist.id) { chosen.remove(playlist.id) } else { chosen.insert(playlist.id) }
                    } label: {
                        HStack(spacing: AppSpacing.md) {
                            Image(systemName: chosen.contains(playlist.id) ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(chosen.contains(playlist.id) ? palette.accent : AppColors.textTertiary)
                            Text(playlist.name).foregroundStyle(AppColors.textPrimary).lineLimit(1)
                            Spacer()
                        }.frame(minHeight: 48).contentShape(Rectangle())
                    }.buttonStyle(.plain).accessibilityIdentifier("export-playlist-" + playlist.id)
                    if playlist.id != library.snapshot.playlists.last?.id { Divider().overlay(AppColors.divider) }
                }
            }
            .padding(.horizontal, AppSpacing.lg)
            .background(AppColors.backgroundSecondary).clipShape(RoundedRectangle(cornerRadius: AppRadius.card))
        }
    }

    @ViewBuilder private var summary: some View {
        if loading {
            HStack(spacing: AppSpacing.md) { ProgressView().tint(palette.accent); Text("Preparing preview…").foregroundStyle(AppColors.textSecondary) }
                .frame(maxWidth: .infinity, alignment: .leading).cardSurface()
        } else if let failure {
            Text(failure).font(.subheadline).foregroundStyle(AppColors.error).frame(maxWidth: .infinity, alignment: .leading).cardSurface()
                .accessibilityIdentifier("export-error")
        } else if let plan {
            VStack(alignment: .leading, spacing: AppSpacing.sm) {
                Text(plan.suggestedFilename).font(.headline).foregroundStyle(AppColors.textPrimary).lineLimit(2)
                SharingMetric("Songs", plan.summary.songs, identifier: "export-songs")
                SharingMetric("Playlists", plan.summary.playlists, identifier: "export-playlists")
                SharingMetric("Playlist entries", plan.summary.occurrences, identifier: "export-occurrences")
                SharingMetric("Songs with a recording reference", plan.summary.songsWithRecordings, identifier: "export-references")
                SharingMetric("Songs the recipient's app will search for", plan.summary.songsNeedingDiscovery, identifier: "export-discovery")
                if plan.summary.unassignedSongs > 0 { SharingMetric("Songs not in any playlist", plan.summary.unassignedSongs, identifier: "export-unassigned") }
                HStack {
                    Text("File size").foregroundStyle(AppColors.textSecondary)
                    Spacer()
                    Text(ByteCountFormatter.string(fromByteCount: Int64(plan.summary.encodedBytes), countStyle: .file)).foregroundStyle(AppColors.textPrimary)
                }.font(.subheadline).accessibilityIdentifier("export-size")
            }.cardSurface()
        } else {
            Text("Choose at least one playlist.").font(.subheadline).foregroundStyle(AppColors.textSecondary)
                .frame(maxWidth: .infinity, alignment: .leading).cardSurface()
        }
    }

    private var privacy: some View {
        VStack(alignment: .leading, spacing: AppSpacing.xs) {
            Label("Not the audio files", systemImage: "info.circle").font(.subheadline.weight(.semibold)).foregroundStyle(AppColors.textPrimary)
            Text("This file contains song details, playlist order and public YouTube recording references. It does not contain audio, so it stays small. The recipient's iPhone downloads each song itself.")
                .font(.caption).foregroundStyle(AppColors.textSecondary)
            Text("Never included: your profile name and photo, listening activity, play history, liked songs, queue, settings, theme, server addresses or anything about this device.")
                .font(.caption).foregroundStyle(AppColors.textSecondary)
        }.frame(maxWidth: .infinity, alignment: .leading).cardSurface()
    }

    private var actions: some View {
        VStack(spacing: AppSpacing.md) {
            Button { Task { await prepare { share = $0 } } } label: {
                Label(preparing ? "Preparing…" : "Share", systemImage: "square.and.arrow.up").frame(maxWidth: .infinity, minHeight: 48)
            }
            .buttonStyle(.borderedProminent).tint(palette.accent).foregroundStyle(palette.onAccent)
            .disabled(plan == nil || preparing).accessibilityIdentifier("export-share")
            Button { Task { await prepare { saving = $0 } } } label: {
                Label("Save to Files", systemImage: "folder").frame(maxWidth: .infinity, minHeight: 44)
            }
            .tint(palette.accent).disabled(plan == nil || preparing).accessibilityIdentifier("export-save")
            Text("Share works with AirDrop, Messages, Mail and Files.").font(.caption).foregroundStyle(AppColors.textTertiary)
        }
    }

    private func load() async {
        guard let scope else { plan = nil; failure = nil; return }
        loading = true; failure = nil
        defer { loading = false }
        do {
            let value = try await container.sharing.exportPlan(scope)
            try Task.checkCancellation()
            plan = value
        } catch is CancellationError {
        } catch {
            plan = nil
            failure = (error as? LocalizedError)?.errorDescription ?? "The library could not be prepared for export."
        }
    }

    private func prepare(_ present: (PreparedLibraryShare) -> Void) async {
        guard let plan, !preparing else { return }
        preparing = true
        defer { preparing = false }
        do { present(try await container.sharing.prepareShare(plan)) }
        catch { failure = (error as? LocalizedError)?.errorDescription ?? "The library file could not be written." }
    }
}

private struct SharingMetric: View {
    let title: String
    let value: Int
    let identifier: String
    init(_ title: String, _ value: Int, identifier: String) { self.title = title; self.value = value; self.identifier = identifier }
    var body: some View {
        HStack {
            Text(title).foregroundStyle(AppColors.textSecondary)
            Spacer()
            Text(value.formatted()).foregroundStyle(AppColors.textPrimary).monospacedDigit()
        }.font(.subheadline).accessibilityElement(children: .combine).accessibilityIdentifier(identifier)
    }
}

struct LibraryShareSheet: UIViewControllerRepresentable {
    let url: URL
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [url], applicationActivities: nil)
    }
    func updateUIViewController(_ controller: UIActivityViewController, context: Context) { }
}

struct LibraryExportPicker: UIViewControllerRepresentable {
    let url: URL
    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        UIDocumentPickerViewController(forExporting: [url], asCopy: true)
    }
    func updateUIViewController(_ controller: UIDocumentPickerViewController, context: Context) { }
}

// MARK: - Import

struct LibraryImportView: View {
    @Environment(\.themePalette) private var palette
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var container: AppContainer

    /// A document delivered by Open in / AirDrop; nil shows the file picker.
    var inbox: PortableInboxDocument? = nil

    @State private var choosing = false
    @State private var loading = false
    @State private var failure: String?
    @State private var preview: PortableImportPreview?
    @State private var selections: [String: PortableImportSelection] = [:]
    @State private var includeUnassigned = false
    @State private var automatic = true
    @State private var committing = false
    @State private var committed: PortableImportCommit?
    @State private var expanded: Set<String> = []

    init(inbox: PortableInboxDocument? = nil) { self.inbox = inbox }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: AppSpacing.xl) {
                    if let committed { done(committed) }
                    else if let preview { previewContent(preview) }
                    else if loading {
                        HStack(spacing: AppSpacing.md) { ProgressView().tint(palette.accent); Text("Checking library file…").foregroundStyle(AppColors.textSecondary) }
                            .frame(maxWidth: .infinity, alignment: .leading).cardSurface()
                    } else { start }
                }.padding(AppSpacing.lg)
            }
            .screenBackground()
            .navigationTitle("Import Library")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(committed == nil ? "Cancel" : "Done") { close() }.disabled(committing).accessibilityIdentifier("import-library-close")
                }
            }
            .fileImporter(isPresented: $choosing, allowedContentTypes: [.muzikBeleshLibrary], allowsMultipleSelection: false) { result in
                switch result {
                case .success(let urls): if let url = urls.first { Task { await open(url) } }
                case .failure: failure = "The file could not be opened."
                }
            }
            .task { if let inbox, preview == nil, !loading { await open(inbox.url) } }
            .interactiveDismissDisabled(committing)
        }
    }

    private var start: some View {
        VStack(alignment: .leading, spacing: AppSpacing.lg) {
            SharingExplainer()
            if let failure {
                Text(failure).font(.subheadline).foregroundStyle(AppColors.error).frame(maxWidth: .infinity, alignment: .leading).cardSurface()
                    .accessibilityIdentifier("import-library-error")
            }
            Button { choosing = true } label: {
                Label("Choose Library File", systemImage: "doc.badge.plus").frame(maxWidth: .infinity, minHeight: 48)
            }
            .buttonStyle(.borderedProminent).tint(palette.accent).foregroundStyle(palette.onAccent)
            .disabled(!container.sharing.isAvailable).accessibilityIdentifier("import-library-choose")
        }
    }

    @ViewBuilder private func previewContent(_ preview: PortableImportPreview) -> some View {
        VStack(alignment: .leading, spacing: AppSpacing.sm) {
            Text(preview.documentName).font(.headline).foregroundStyle(AppColors.textPrimary).lineLimit(2)
            SharingMetric("Songs", preview.summary.songs, identifier: "import-songs")
            SharingMetric("Playlists", preview.summary.playlists, identifier: "import-playlists")
            SharingMetric("Playlist entries", preview.summary.occurrences, identifier: "import-occurrences")
            SharingMetric("Already downloaded here", preview.alreadyAvailable, identifier: "import-available")
            SharingMetric("Probably already in your library", preview.likelyAvailable, identifier: "import-likely")
            SharingMetric("With a recording reference", preview.summary.songsWithRecordings, identifier: "import-references")
        }.cardSurface()

        if !preview.playlists.isEmpty {
            VStack(alignment: .leading, spacing: AppSpacing.sm) {
                Text("PLAYLISTS").font(.caption.weight(.semibold)).foregroundStyle(AppColors.textSecondary)
                ForEach(preview.playlists) { option in playlistCard(option) }
            }
        }
        if preview.unassignedSongs > 0 { unassignedCard(preview) }

        VStack(alignment: .leading, spacing: AppSpacing.xs) {
            Toggle(isOn: $automatic) {
                Text("Automatically find and download missing songs").foregroundStyle(AppColors.textPrimary)
            }.tint(palette.accent).accessibilityIdentifier("import-automatic")
            Text(automatic
                 ? "Songs you already have are reused first. Shared recordings that pass every matching check are downloaded, following your Wi-Fi setting; anything uncertain waits for your review."
                 : "Songs you already have are reused. Nothing is searched or downloaded until you start it from the playlist.")
                .font(.caption).foregroundStyle(AppColors.textSecondary)
        }.cardSurface()

        if let failure {
            Text(failure).font(.subheadline).foregroundStyle(AppColors.error).accessibilityIdentifier("import-library-error")
        }
        Button { Task { await confirm(preview) } } label: {
            Label(committing ? "Importing…" : "Import \(selectedCount(preview)) \(selectedCount(preview) == 1 ? "Playlist" : "Playlists")",
                  systemImage: "square.and.arrow.down").frame(maxWidth: .infinity, minHeight: 48)
        }
        .buttonStyle(.borderedProminent).tint(palette.accent).foregroundStyle(palette.onAccent)
        .disabled(committing || selectedCount(preview) == 0 || hasInvalidName(preview)).accessibilityIdentifier("import-library-confirm")
        Text("Nothing is replaced or overwritten. Imported playlists appear in your Library right away.").font(.caption).foregroundStyle(AppColors.textTertiary)
    }

    private func playlistCard(_ option: PortableImportPlaylistOption) -> some View {
        let binding = Binding<PortableImportSelection>(
            get: { selections[option.id] ?? .init(included: false, name: option.originalName) },
            set: { selections[option.id] = $0 })
        return VStack(alignment: .leading, spacing: AppSpacing.sm) {
            Toggle(isOn: binding.included) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(option.originalName).foregroundStyle(AppColors.textPrimary).lineLimit(2)
                    Text("\(option.occurrences.formatted()) songs").font(.caption).foregroundStyle(AppColors.textSecondary)
                }
            }.tint(palette.accent).accessibilityIdentifier("import-playlist-" + option.id)
            switch option.duplicate {
            case .identical(let existing):
                Label("You already have this playlist as “\(existing)”. It is skipped unless you turn it on to import a separate copy.",
                      systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(AppColors.warning)
            case .sameName:
                Label("A different playlist with this name exists. This one will be imported under a new name.",
                      systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(AppColors.warning)
            case .none: EmptyView()
            }
            if binding.wrappedValue.included {
                TextField("Playlist name", text: binding.name)
                    .textInputAutocapitalization(.words).padding(AppSpacing.sm)
                    .background(AppColors.backgroundTertiary).clipShape(RoundedRectangle(cornerRadius: AppRadius.small))
                    .foregroundStyle(AppColors.textPrimary).accessibilityIdentifier("import-name-" + option.id)
            }
            DisclosureGroup(isExpanded: Binding(get: { expanded.contains(option.id) }, set: { if $0 { expanded.insert(option.id) } else { expanded.remove(option.id) } })) {
                songList(option.songTitles, total: option.occurrences)
            } label: { Text("Show songs").font(.caption.weight(.semibold)).foregroundStyle(palette.accent) }
        }.cardSurface()
    }

    private func unassignedCard(_ preview: PortableImportPreview) -> some View {
        VStack(alignment: .leading, spacing: AppSpacing.sm) {
            Toggle(isOn: $includeUnassigned) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Include songs not in any playlist").foregroundStyle(AppColors.textPrimary)
                    Text("\(preview.unassignedSongs.formatted()) songs").font(.caption).foregroundStyle(AppColors.textSecondary)
                }
            }.tint(palette.accent).accessibilityIdentifier("import-unassigned")
            Text("These songs were in the sender's library but in no playlist. They are added to a new playlist called “\(PortableImportNames.unassignedCollection)” so you can find and manage them.")
                .font(.caption).foregroundStyle(AppColors.textSecondary)
            DisclosureGroup(isExpanded: Binding(get: { expanded.contains("unassigned") }, set: { if $0 { expanded.insert("unassigned") } else { expanded.remove("unassigned") } })) {
                songList(preview.unassignedTitles, total: preview.unassignedSongs)
            } label: { Text("Show songs").font(.caption.weight(.semibold)).foregroundStyle(palette.accent) }
        }.cardSurface()
    }

    private func songList(_ titles: [String], total: Int) -> some View {
        VStack(alignment: .leading, spacing: AppSpacing.xs) {
            ForEach(Array(titles.enumerated()), id: \.offset) { index, title in
                Text("\(index + 1). \(title)").font(.caption).foregroundStyle(AppColors.textSecondary).lineLimit(1)
            }
            if total > titles.count { Text("and \((total - titles.count).formatted()) more").font(.caption).foregroundStyle(AppColors.textTertiary) }
        }.frame(maxWidth: .infinity, alignment: .leading).padding(.top, AppSpacing.xs)
    }

    private func done(_ result: PortableImportCommit) -> some View {
        VStack(alignment: .leading, spacing: AppSpacing.lg) {
            Label(result.reused ? "Already imported" : "Imported", systemImage: "checkmark.circle.fill")
                .font(.headline).foregroundStyle(palette.accent).accessibilityIdentifier("import-library-done")
            Text("\(result.playlistIDs.count) \(result.playlistIDs.count == 1 ? "playlist was" : "playlists were") added to your Library. You can close this screen; progress continues in the background.")
                .font(.subheadline).foregroundStyle(AppColors.textSecondary)
            PortableImportActivityFinder(sharing: container.sharing, importID: result.importID)
        }
    }

    private func selectedCount(_ preview: PortableImportPreview) -> Int {
        preview.playlists.filter { selections[$0.id]?.included == true }.count + (includeUnassigned && preview.unassignedSongs > 0 ? 1 : 0)
    }

    private func hasInvalidName(_ preview: PortableImportPreview) -> Bool {
        preview.playlists.contains { option in
            guard let selection = selections[option.id], selection.included else { return false }
            return (try? LibraryIdentity.validatedName(selection.name)) == nil
        }
    }

    private func open(_ url: URL) async {
        loading = true; failure = nil
        defer { loading = false }
        do {
            let value = try await container.sharing.preview(url: url)
            preview = value
            selections = value.defaultSelections
            includeUnassigned = value.playlists.isEmpty && value.unassignedSongs > 0
        } catch is CancellationError {
        } catch {
            failure = (error as? LocalizedError)?.errorDescription ?? "This library file could not be read."
        }
    }

    private func confirm(_ preview: PortableImportPreview) async {
        guard !committing else { return }
        committing = true; failure = nil
        defer { committing = false }
        do {
            committed = try await container.sharing.confirm(preview, selections: selections, includeUnassigned: includeUnassigned, automaticAcquisition: automatic)
            if let inbox { container.sharing.finishInbox(inbox) }
        } catch {
            failure = (error as? LocalizedError)?.errorDescription ?? "The library could not be imported. Nothing was changed."
        }
    }

    private func close() {
        if let inbox { container.sharing.finishInbox(inbox) }
        dismiss()
    }
}

// MARK: - Progress

struct PortableImportActivityList: View {
    @ObservedObject var sharing: LibrarySharingService
    var body: some View {
        if !sharing.activities.isEmpty {
            VStack(alignment: .leading, spacing: AppSpacing.sm) {
                Text("IMPORTS").font(.caption.weight(.semibold)).foregroundStyle(AppColors.textSecondary).accessibilityAddTraits(.isHeader)
                ForEach(sharing.activities) { PortableImportActivityCard(sharing: sharing, activity: $0) }
            }
        }
    }
}

private struct PortableImportActivityFinder: View {
    @ObservedObject var sharing: LibrarySharingService
    let importID: String
    var body: some View {
        if let activity = sharing.activities.first(where: { $0.id == importID }) {
            PortableImportActivityCard(sharing: sharing, activity: activity)
        }
    }
}

struct PortableImportActivityCard: View {
    @Environment(\.themePalette) private var palette
    @ObservedObject var sharing: LibrarySharingService
    let activity: PortableImportActivity
    @State private var confirmingCancel = false
    @State private var working = false

    init(sharing: LibrarySharingService, activity: PortableImportActivity) { self.sharing = sharing; self.activity = activity }

    private var progress: PortableImportProgress { activity.progress }
    private var isPaused: Bool { sharing.paused.contains(activity.id) }

    var body: some View {
        VStack(alignment: .leading, spacing: AppSpacing.sm) {
            HStack {
                Text(activity.documentName).font(.headline).foregroundStyle(AppColors.textPrimary).lineLimit(1)
                Spacer()
                Text(status).font(.caption.weight(.semibold)).foregroundStyle(isPaused ? AppColors.warning : AppColors.textSecondary)
            }
            ProgressView(value: progress.fractionAvailable).tint(palette.accent).accessibilityLabel("\(progress.available) of \(progress.songs) songs available")
            Text("\(progress.available.formatted()) of \(progress.songs.formatted()) songs available offline").font(.subheadline).foregroundStyle(AppColors.textPrimary)
            VStack(alignment: .leading, spacing: 2) {
                line("Reused from your library", progress.reusedLocally)
                line("Downloading", progress.downloading)
                line("Verifying", progress.verifying)
                line("Waiting to download", progress.queued)
                line("Searching", progress.searching)
                line("Needs your review", progress.needsReview)
                line(activity.automaticAcquisition ? "Not searched yet" : "Not downloaded", progress.waiting)
                line("Couldn't be downloaded", progress.failed)
                line("Skipped", progress.skipped)
            }
            if activity.phase != .cancelled { controls }
        }
        .cardSurface()
        .accessibilityIdentifier("import-activity-" + activity.id)
        .confirmationDialog("Stop this import?", isPresented: $confirmingCancel, titleVisibility: .visible) {
            Button("Stop Import", role: .destructive) { run { await sharing.cancel(activity) } }
            Button("Keep Going", role: .cancel) { }
        } message: { Text("Remaining searches and downloads stop. Imported playlists and songs already available are kept.") }
    }

    private var status: String {
        if activity.phase == .cancelled { return "Stopped" }
        if isPaused { return "Paused" }
        if [.committed, .reconciling].contains(activity.phase) { return "Checking your library" }
        if progress.songs > 0 && progress.available == progress.songs { return "Complete" }
        if !progress.isSettled { return "In progress" }
        return progress.needsReview > 0 ? "Needs review" : "Waiting"
    }

    @ViewBuilder private func line(_ title: String, _ value: Int) -> some View {
        if value > 0 {
            HStack { Text(title); Spacer(); Text(value.formatted()).monospacedDigit() }
                .font(.caption).foregroundStyle(AppColors.textSecondary)
        }
    }

    private var controls: some View {
        HStack(spacing: AppSpacing.md) {
            if isPaused {
                Button("Resume") { run { await sharing.resume(activity) } }.accessibilityIdentifier("import-activity-resume")
            } else if !(progress.songs > 0 && progress.available == progress.songs) {
                Button("Pause") { run { await sharing.pause(activity) } }.accessibilityIdentifier("import-activity-pause")
            }
            if !activity.automaticAcquisition && progress.waiting > 0 && !isPaused {
                Button("Find Missing Songs") { run { await sharing.findMissingSongs(activity) } }.accessibilityIdentifier("import-activity-find")
            }
            Spacer()
            if !(progress.songs > 0 && progress.available == progress.songs) {
                Button("Stop", role: .destructive) { confirmingCancel = true }.accessibilityIdentifier("import-activity-cancel")
            }
        }
        .font(.subheadline.weight(.semibold)).tint(palette.accent).buttonStyle(.borderless).disabled(working)
    }

    private func run(_ action: @escaping () async -> Void) {
        working = true
        Task { await action(); working = false }
    }
}
