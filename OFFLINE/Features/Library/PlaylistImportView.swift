import SwiftUI
import UniformTypeIdentifiers

@MainActor final class PlaylistImportViewModel: ObservableObject {
    @Published var report: PlaylistImportReport?
    @Published var duplicate: [UUID: PlaylistImportDuplicate] = [:]
    @Published var selected: Set<UUID> = []
    @Published var names: [UUID: String] = [:]
    @Published var results: [UUID: PlaylistImportCommit] = [:]
    @Published var failures: [UUID: String] = [:]
    @Published var busy = false
    @Published var progress = ""
    @Published var error: String?
    private var work: Task<Void, Never>?
    private let storage: StorageCoordinator
    init(storage: StorageCoordinator) { self.storage = storage }
    func cancel() { work?.cancel() }

    func load(_ url: URL) {
        guard !busy else { return }
        busy = true; error = nil; report = nil; results = [:]; failures = [:]
        progress = "Reading and validating metadata…"
        work = Task {
            defer { busy = false }
            do {
                let report = try await PlaylistMetadataFileImporter(stagingRoot: storage.paths.imports).prepare(file: url)
                let duplicates = try await PlaylistImportCoordinator(persistence: storage.playlistMigrations).review(report)
                try Task.checkCancellation()
                self.report = report; duplicate = duplicates
                selected = Set(report.candidates.filter { $0.source != nil && duplicates[$0.id] != .ambiguous }.map(\.id))
                names = Dictionary(uniqueKeysWithValues: report.candidates.map { ($0.id, $0.name) })
                progress = "Review the playlists before importing."
            } catch is CancellationError { error = "Reading cancelled. Nothing was imported." }
            catch let problem as PlaylistImportProblem { error = problem.localizedDescription }
            catch { error = "Unable to prepare the import review. Check file access and local database availability, then retry." }
        }
    }

    func commit() {
        guard !busy, let report else { return }
        let candidates = report.candidates.filter { selected.contains($0.id) && $0.source != nil && results[$0.id] == nil && duplicate[$0.id] != .ambiguous }
        guard !candidates.isEmpty else { return }
        busy = true; error = nil
        work = Task {
            defer { busy = false }
            let coordinator = PlaylistImportCoordinator(persistence: storage.playlistMigrations)
            for (index, candidate) in candidates.enumerated() {
                if Task.isCancelled { error = "Import cancelled. Completed playlists are kept; remaining playlists were not imported."; break }
                progress = "Importing playlist \(index + 1) of \(candidates.count)…"
                do {
                    let result = try await coordinator.commit(candidate, destinationName: names[candidate.id] ?? candidate.name)
                    results[candidate.id] = result; failures[candidate.id] = nil
                    selected.remove(candidate.id)
                } catch is CancellationError {
                    error = "Import cancelled. Completed playlists are kept; remaining playlists were not imported."; break
                } catch let problem as PlaylistImportProblem { failures[candidate.id] = problem.localizedDescription }
                catch let problem as PlaylistMigrationStorageError { failures[candidate.id] = problem.localizedDescription + " This playlist was not imported." }
                catch let problem as LibraryError { failures[candidate.id] = problem.localizedDescription + " This playlist was not imported." }
                catch { failures[candidate.id] = "The database transaction could not commit. This playlist was not imported. Check available storage and retry." }
            }
            progress = "\(results.count) playlist(s) committed or already present • \(failures.count) commit error(s)"
        }
    }

    #if DEBUG
    func loadUITestFixture() {
        guard ProcessInfo.processInfo.arguments.contains("--ui-testing"), ProcessInfo.processInfo.arguments.contains("--playlist-import-fixture") else { return }
        do {
            let url = storage.paths.documents.appendingPathComponent("Synthetic Import.csv")
            let csv = "Track Name,Artist Name(s)\n" + (0..<500).map { "Synthetic song \($0 % 3),Synthetic artist\n" }.joined()
            try Data(csv.utf8).write(to: url)
            load(url)
        } catch { self.error = "Unable to stage the synthetic UI fixture." }
    }
    #endif
}

struct PlaylistImportView: View {
    @StateObject private var model: PlaylistImportViewModel
    @State private var showingFiles = false
    @Environment(\.dismiss) private var dismiss
    init(storage: StorageCoordinator) { _model = StateObject(wrappedValue: PlaylistImportViewModel(storage: storage)) }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text("Import Spotify playlist metadata from account-data JSON, Exportify CSV or a ZIP archive. Songs remain placeholders until local audio is available.")
                        .font(.callout).foregroundStyle(AppColors.textSecondary)
                    Button(model.report == nil ? "Choose Export File" : "Choose Another File") { showingFiles = true }
                        .disabled(model.busy).accessibilityIdentifier("playlist-import-choose-file")
                }
                if model.busy {
                    Section {
                        ProgressView(model.progress)
                        Button("Cancel Import", role: .cancel) { model.cancel() }.accessibilityIdentifier("playlist-import-cancel")
                    }
                } else if !model.progress.isEmpty { Text(model.progress).font(.callout).accessibilityIdentifier("playlist-import-progress") }
                if let error = model.error { Text(error).foregroundStyle(AppColors.error).accessibilityIdentifier("playlist-import-error") }
                if let report = model.report {
                    Section("Import Review") {
                        Text(report.filename).font(.headline)
                        Text(report.format)
                        Text("\(report.validCount) valid • \(report.candidates.count - report.validCount) invalid playlists")
                            .accessibilityIdentifier("playlist-import-counts")
                        ForEach(Array(report.notes.enumerated()), id: \.offset) { _, note in Text(note).font(.caption) }
                    }
                    ForEach(report.candidates) { candidate in candidateSection(candidate) }
                    Section {
                        Button("Import Selected Playlists") { model.commit() }
                            .disabled(model.busy || model.selected.isEmpty)
                            .accessibilityIdentifier("playlist-import-confirm")
                    }
                }
            }
            .scrollContentBackground(.hidden).screenBackground().tint(AppColors.accentPrimary)
            .navigationTitle("Import Spotify Playlist").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() }.disabled(model.busy) } }
            .fileImporter(isPresented: $showingFiles, allowedContentTypes: [.json, .commaSeparatedText, .zip], allowsMultipleSelection: false) { result in
                switch result {
                case .success(let urls): if let url = urls.first { model.load(url) }
                case .failure: model.error = "The Files picker could not provide the document. Select a downloaded JSON, CSV or ZIP file and try again."
                }
            }
            .interactiveDismissDisabled(model.busy)
            .onDisappear { model.cancel() }
            .onAppear {
                #if DEBUG
                if model.report == nil && !model.busy { model.loadUITestFixture() }
                #endif
            }
        }.preferredColorScheme(.dark)
    }

    @ViewBuilder private func candidateSection(_ candidate: PlaylistImportCandidate) -> some View {
        Section(candidate.name) {
            Text(candidate.location).font(.caption).foregroundStyle(AppColors.textSecondary)
            if let count = candidate.entryCount { Text("\(count) source entries • \(candidate.format)") }
            else { Text("Source entry count unavailable • \(candidate.format)").font(.caption) }
            if let result = model.results[candidate.id] {
                Text(result.existing ? "Already imported — existing playlist retained" : "Metadata imported — awaiting local audio")
                    .accessibilityIdentifier("playlist-import-success")
                if let id = result.session.destinationPlaylistID {
                    NavigationLink("Open Playlist") { PlaylistDetailView(playlistID: id) }.accessibilityIdentifier("playlist-import-open")
                }
            } else if candidate.source != nil {
                let status = model.duplicate[candidate.id] ?? .new
                Text(status.message).font(.callout)
                Toggle("Select Playlist", isOn: Binding(get: { model.selected.contains(candidate.id) }, set: {
                    if $0 { model.selected.insert(candidate.id) } else { model.selected.remove(candidate.id) }
                })).disabled(model.busy || status == .ambiguous)
                if case .existing = status { EmptyView() }
                else {
                    TextField("Destination playlist name", text: Binding(get: { model.names[candidate.id] ?? candidate.name }, set: { model.names[candidate.id] = $0 }))
                        .disabled(model.busy || status == .ambiguous).accessibilityIdentifier("playlist-import-destination-name")
                }
            } else { Text("Not importable — no playlist was committed").foregroundStyle(AppColors.error) }
            ForEach(Array(candidate.diagnostics.enumerated()), id: \.offset) { _, message in Text(message).font(.caption) }
            if let failure = model.failures[candidate.id] { Text(failure).font(.callout).foregroundStyle(AppColors.error) }
        }
    }
}
