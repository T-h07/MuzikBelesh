import SwiftUI
import UniformTypeIdentifiers

struct PlaylistImportView: View {
    @ObservedObject var model: PlaylistImportViewModel
    @EnvironmentObject private var library: MusicLibraryService
    @State private var showingFiles = false
    @State private var expanded: Set<UUID> = []
    @FocusState private var destinationFocus: UUID?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text("Import Spotify playlist metadata from account-data JSON, Exportify CSV or a ZIP archive. Songs remain placeholders until verified local audio is available.")
                        .font(.callout).foregroundStyle(AppColors.textSecondary)
                    Button(model.report == nil ? "Choose Export File" : "Choose Another File") { showingFiles = true }
                        .disabled(model.busy).accessibilityIdentifier("playlist-import-choose-file")
                }
                Section {
                    if model.busy {
                        ProgressView(model.progress).accessibilityIdentifier("playlist-import-operation-progress")
                        if model.completed + model.pending + model.failed > 0 {
                            Text("\(model.completed) completed • \(model.pending) pending • \(model.failed) failed")
                        }
                        Text("You can close this screen and use the app. Reopen Import Playlist to see results.").font(.caption)
                        Button("Cancel Import", role: .cancel) { model.cancel() }.accessibilityIdentifier("playlist-import-cancel")
                    } else if !model.progress.isEmpty {
                        Text(model.progress).font(.callout).accessibilityIdentifier("playlist-import-progress")
                    }
                    if let error = model.error { Text(error).foregroundStyle(AppColors.error).accessibilityIdentifier("playlist-import-error") }
                }
                if !model.results.isEmpty {
                    Section("Completed Playlists") {
                        ForEach(model.results.values.sorted { $0.session.createdAt < $1.session.createdAt }, id: \.session.id) { result in
                            VStack(alignment: .leading) {
                                Text(result.session.sourcePlaylistName).font(.headline)
                                Text(result.existing ? "Already imported — existing playlist retained" : "Metadata imported — awaiting local audio")
                                    .accessibilityIdentifier("playlist-import-success")
                                destinationLink(result.session.destinationPlaylistID)
                            }
                        }
                    }
                }
                if model.report == nil && !model.failures.isEmpty {
                    Section("Uncommitted Playlists") {
                        ForEach(model.failures.keys.sorted { $0.uuidString < $1.uuidString }, id: \.self) { id in
                            Text(model.failures[id] ?? "").foregroundStyle(AppColors.error)
                        }
                        Text("Choose the export again to review and retry. Completed destinations will be identified as duplicates.")
                    }
                }
                if let report = model.report {
                    Section("Import Review") {
                        Text(report.filename).font(.headline)
                        Text(report.format)
                        Text("\(report.candidates.count) detected playlists")
                        Text("\(report.validCount) valid • \(report.candidates.count - report.validCount) invalid playlists")
                            .accessibilityIdentifier("playlist-import-counts")
                        Text("\(report.candidates.compactMap(\.entryCount).reduce(0, +)) known source entries")
                        if report.candidates.contains(where: { $0.entryCount == nil }) { Text("Some invalid sources have unknown entry counts.").font(.caption) }
                        Text(model.canCommit ? "Ready to import selected playlists" : "Select eligible playlists with valid destination names to continue")
                        ForEach(Array(report.notes.enumerated()), id: \.offset) { _, note in Text(note).font(.caption) }
                        Button("Select All Eligible") { model.selectAll(true) }.disabled(model.busy).accessibilityIdentifier("playlist-import-select-all")
                        Button("Deselect All") { model.selectAll(false) }.disabled(model.busy).accessibilityIdentifier("playlist-import-deselect-all")
                    }
                    ForEach(report.candidates) { candidate in candidateSection(candidate) }
                    Section("Confirm Import") {
                        let selected = model.selectedCandidates
                        Text("\(selected.count) selected • \(selected.compactMap(\.entryCount).reduce(0, +)) source entries • \(selected.count) new destinations")
                        Text("\(model.duplicate.values.filter { if case .existing = $0 { return true }; return false }.count) existing duplicates • \(report.candidates.count - selected.count) invalid or excluded playlists")
                        Button("Import Selected Playlists") { model.commit() }
                            .disabled(!model.canCommit).accessibilityIdentifier("playlist-import-confirm")
                    }
                }
            }
            .scrollDismissesKeyboard(.interactively)
            .scrollContentBackground(.hidden).screenBackground().tint(AppColors.accentPrimary)
            .navigationTitle("Import Playlist").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() }.accessibilityIdentifier("playlist-import-close") } }
            .fileImporter(isPresented: $showingFiles, allowedContentTypes: [.json, .commaSeparatedText, .zip], allowsMultipleSelection: false) { result in
                switch result {
                case .success(let urls): if let url = urls.first { expanded = []; model.load(url) }
                case .failure(let error):
                    if (error as NSError).code != CocoaError.userCancelled.rawValue {
                        model.error = "The Files picker could not provide the document. Select a downloaded JSON, CSV or ZIP file and try again."
                    }
                }
            }
            .onAppear {
                model.presentationOpened()
                #if DEBUG
                if model.report == nil && !model.busy { model.loadUITestFixture() }
                #endif
            }
        }.preferredColorScheme(.dark)
    }

    @ViewBuilder private func destinationLink(_ id: String?) -> some View {
        if let id, let playlist = library.snapshot.playlists.first(where: { $0.id == id }) {
            Text("Destination: \(playlist.name)").font(.caption)
            NavigationLink("Open Playlist") { PlaylistDetailView(playlistID: id) }.accessibilityIdentifier("playlist-import-open")
        } else { Text("Destination is not available in the Library.").font(.caption) }
    }

    @ViewBuilder private func candidateSection(_ candidate: PlaylistImportCandidate) -> some View {
        Section(candidate.name) {
            Text(candidate.location).font(.caption).foregroundStyle(AppColors.textSecondary)
            Text(candidate.format).font(.caption)
            if let count = candidate.entryCount { Text("\(count) source entries") }
            else { Text("Source entry count unavailable").font(.caption) }
            Text(candidate.source == nil ? "Validation failed — not importable" : "Source metadata validated")
            if let result = model.results[candidate.id] {
                Text("Committed"); destinationLink(result.session.destinationPlaylistID)
            } else if candidate.source != nil {
                let status = model.duplicate[candidate.id] ?? .ambiguous
                Text(status.message).font(.callout)
                if case .existing(let migrationID) = status {
                    destinationLink(library.snapshot.migrationSessions.first { $0.id == migrationID }?.destinationPlaylistID)
                } else {
                    Toggle("Select Playlist", isOn: Binding(get: { model.selected.contains(candidate.id) }, set: {
                        if $0 { model.selected.insert(candidate.id) } else { model.selected.remove(candidate.id) }
                    })).disabled(model.busy || !model.isEligible(candidate)).accessibilityIdentifier("playlist-import-select-" + candidate.id.uuidString)
                    TextField("Destination playlist name", text: Binding(get: { model.names[candidate.id] ?? candidate.name }, set: { model.names[candidate.id] = $0 }))
                        .focused($destinationFocus, equals: candidate.id).submitLabel(.done).onSubmit { destinationFocus = nil }
                        .disabled(model.busy || !model.isEligible(candidate)).accessibilityIdentifier("playlist-import-destination-name")
                    if (try? LibraryIdentity.validatedName(model.names[candidate.id] ?? candidate.name)) == nil {
                        Text(LibraryError.invalidName.localizedDescription).foregroundStyle(AppColors.error)
                    }
                }
            }
            ForEach(Array(candidate.diagnostics.enumerated()), id: \.offset) { _, message in Text(message).font(.caption) }
            if let failure = model.failures[candidate.id] { Text(failure).font(.callout).foregroundStyle(AppColors.error) }
            if let source = candidate.source {
                Button(expanded.contains(candidate.id) ? "Hide Source Songs" : "Show Source Songs") {
                    if !expanded.insert(candidate.id).inserted { expanded.remove(candidate.id) }
                }.accessibilityIdentifier("playlist-import-preview-" + candidate.id.uuidString)
                // Direct List children remain virtualized even for a 10,000-entry source.
                if expanded.contains(candidate.id) {
                    ForEach(source.entries) { track in MigrationSourceMetadataView(source: track, showsIdentity: true) }
                    if source.entries.isEmpty { Text("This source playlist is empty.") }
                }
            }
        }
    }
}
