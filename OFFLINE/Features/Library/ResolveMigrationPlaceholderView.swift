import SwiftUI

struct ResolveMigrationPlaceholderView: View {
    @EnvironmentObject private var library: MusicLibraryService
    @Environment(\.dismiss) private var dismiss
    let entry: PlaylistMigrationEntry
    @State private var selected: StoredTrack?
    @State private var confirming = false
    @State private var saving = false
    @State private var error: String?
    var body: some View {
        NavigationStack {
            List {
                Section("Original Spotify Occurrence") { MigrationSourceMetadataView(source: entry.source, showsIdentity: true) }
                Section {
                    Text("Resolve this placeholder only after verifying the performer, recording version and duration. This associates existing audio; it does not add another playlist occurrence.")
                    if let error { Text(error).foregroundStyle(AppColors.error) }
                }
                Section("Choose Existing Local Recording") {
                    ForEach(library.snapshot.tracks.filter { $0.availability == .available }) { track in
                        Button { selected = track; confirming = true } label: {
                            VStack(alignment: .leading) {
                                Text(track.title)
                                Text(library.artistName(track.artistID) + " • " + library.albumTitle(track.albumID)).font(.caption)
                                if let duration = track.durationMs { Text("\(duration / 1000) seconds").font(.caption) }
                            }
                        }.disabled(saving)
                    }
                }
            }.scrollContentBackground(.hidden).screenBackground().navigationTitle("Resolve Placeholder")
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() }.disabled(saving) } }
                .confirmationDialog("Confirm this is the intended recording?", isPresented: $confirming, titleVisibility: .visible) {
                    Button("Confirm Recording") { confirm() }
                    Button("Cancel", role: .cancel) { selected = nil }
                } message: { Text("The source metadata will be preserved. Confirming associates “\(selected?.title ?? "")” only after local audio verification.") }
        }.interactiveDismissDisabled(saving)
    }
    private func confirm() {
        guard let track = selected, let repository = library.storage?.playlistMigrations else { return }
        saving = true
        Task {
            defer { saving = false }
            do { try await repository.confirmLocalRecording(for: entry, trackID: track.id); dismiss() }
            catch { self.error = "The recording could not be verified, or this source entry changed. Reopen the entry and try again." }
        }
    }
}
