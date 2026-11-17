import SwiftUI

/// "Change Video" for a song that already plays offline. The choice is staged: the new
/// video is downloaded through the shared queue and verified, and only then replaces the
/// current recording. Until then — and if it fails or is cancelled — the current
/// recording stays associated and playable.
struct RecordingReplacementControls: View {
    @EnvironmentObject private var container: AppContainer
    let entry: PlaylistMigrationEntry
    let accepted: PlaylistMigrationCandidate
    let repository: GRDBPlaylistMigrationRepository
    let lookup: YouTubeManualLookup
    let changed: () -> Void
    @State private var choosing = false

    var body: some View {
        if let acquisition = container.playlistAcquisition {
            RecordingReplacementStatus(acquisition: acquisition, entry: entry, accepted: accepted, repository: repository, lookup: lookup,
                                       choosing: $choosing, changed: changed)
        } else {
            Text("Selected: \(accepted.title)").font(.headline)
            Text("Available offline.").font(.caption).foregroundStyle(AppColors.textSecondary)
        }
    }
}

private struct RecordingReplacementStatus: View {
    @ObservedObject var acquisition: PlaylistAcquisitionCoordinator
    let entry: PlaylistMigrationEntry
    let accepted: PlaylistMigrationCandidate
    let repository: GRDBPlaylistMigrationRepository
    let lookup: YouTubeManualLookup
    @Binding var choosing: Bool
    let changed: () -> Void
    @State private var busy = false
    @State private var error: String?
    @State private var confirmingCancel = false

    var body: some View {
        VStack(alignment: .leading, spacing: AppSpacing.sm) {
            Text("Selected: \(accepted.title)").font(.headline)
            Text("Available offline.").font(.caption).foregroundStyle(AppColors.accentPrimary)
                .accessibilityIdentifier("migration-replacement-current")
            if let pending = acquisition.replacement(for: entry.id) {
                let state = acquisition.replacementStates[entry.id]
                VStack(alignment: .leading, spacing: 4) {
                    Text("Replacing with: \(pending.title)").font(.subheadline.weight(.semibold))
                    Text(pending.state == .failed ? "Replacement failed" : (state?.label ?? "Waiting to download"))
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(pending.state == .failed ? AppColors.error : AppColors.accentPrimary)
                        .accessibilityIdentifier("migration-replacement-state")
                    if case .downloading(let progress?)? = state { ProgressView(value: progress).tint(AppColors.accentPrimary) }
                    if let failure = pending.failure, pending.state == .failed {
                        Text(failure).font(.caption).foregroundStyle(AppColors.textSecondary)
                    }
                    Text("The current recording keeps playing until the new one is downloaded and verified.")
                        .font(.caption).foregroundStyle(AppColors.textSecondary)
                }
                HStack(spacing: AppSpacing.sm) {
                    if pending.state == .failed {
                        Button("Retry") { run { try await acquisition.retryReplacement(entryID: entry.id) } }
                            .buttonStyle(.matchingSecondary).disabled(busy).accessibilityIdentifier("migration-replacement-retry")
                    }
                    Button("Cancel Replacement", role: .destructive) { confirmingCancel = true }
                        .buttonStyle(.matchingSecondary).disabled(busy).accessibilityIdentifier("migration-replacement-cancel")
                }
            } else if choosing {
                ManualYouTubeSelectionView(entry: entry, repository: repository, lookup: lookup, accepted: nil,
                    onConfirm: { result in
                        // Re-read just before staging so a concurrent change is never overwritten.
                        let fresh = try await repository.entry(id: entry.id)
                        try await acquisition.stageReplacement(for: fresh, video: result.video, metadataVerified: result.metadataVerified)
                    }, replacementMode: true) { choosing = false; changed() }
                Button("Keep Current Video") { choosing = false }.buttonStyle(.matchingSecondary)
            } else {
                Button("Change Video") { choosing = true }
                    .buttonStyle(.matchingSecondary).disabled(busy).frame(minHeight: 44)
                    .accessibilityHint("Choose another video. The current one keeps playing until the new one is ready.")
                    .accessibilityIdentifier("migration-manual-reject")
            }
            if let error { Text(error).font(.caption).foregroundStyle(AppColors.error) }
        }
        .confirmationDialog("Cancel the replacement?", isPresented: $confirmingCancel, titleVisibility: .visible) {
            Button("Cancel Replacement", role: .destructive) { run { try await acquisition.cancelReplacement(entryID: entry.id) } }
            Button("Keep Replacing", role: .cancel) {}
        } message: { Text("The current recording stays on this song.") }
    }

    private func run(_ action: @escaping () async throws -> Void) {
        busy = true; error = nil
        Task {
            defer { busy = false }
            do { try await action(); changed() }
            catch { self.error = "That couldn't be changed. Try again." }
        }
    }
}
