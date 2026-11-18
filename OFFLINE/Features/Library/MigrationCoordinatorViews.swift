import SwiftUI

/// Phase 10.6: one compact, derived migration status with per-playlist controls.
/// Matching progress and offline availability are shown separately, so 500 imported
/// songs with 20 downloaded never look complete. Hidden until the migration starts.
struct MigrationCoordinatorStatusView: View {
    @Environment(\.themePalette) private var palette
    @ObservedObject var coordinator: PlaylistMigrationCoordinator
    let session: PlaylistMigrationSession
    @State private var confirmingCancel = false
    @State private var busy = false
    @State private var error: String?

    var body: some View {
        if let status = coordinator.status(for: session.id), status.state != .pending {
            let progress = status.progress
            VStack(alignment: .leading, spacing: AppSpacing.sm) {
                Text("Migration").font(.headline)
                Text(status.message).font(.subheadline.weight(.semibold)).foregroundStyle(palette.accent)
                    .accessibilityIdentifier("migration-coordinator-status")
                Text("Matched \(progress.matchingCompleted) of \(progress.total) · Offline \(progress.availableOffline) of \(progress.total)")
                    .font(.caption).foregroundStyle(AppColors.textSecondary)
                    .accessibilityIdentifier("migration-coordinator-progress")
                let details = [count(progress.awaitingReview, "awaiting review"), count(progress.confirmed, "confirmed"),
                               count(progress.queuedDownloads, "queued"), count(progress.downloading, "downloading"),
                               count(progress.verifying, "verifying"), count(progress.failedOrUnsupported, "need attention")].compactMap { $0 }
                if !details.isEmpty {
                    Text(details.joined(separator: " · ")).font(.caption).foregroundStyle(AppColors.textSecondary)
                }
                if let wait = status.waitUntil, wait > Date() {
                    (Text("Continues automatically ") + Text(wait, style: .relative)).font(.caption).foregroundStyle(AppColors.textSecondary)
                }
                if let error { Text(error).font(.caption).foregroundStyle(AppColors.error) }
                HStack(spacing: AppSpacing.sm) {
                    if status.state == .userPaused {
                        Button("Resume Playlist") { run { try await coordinator.resumeMigration(session.id) } }
                            .buttonStyle(.matchingSecondary).disabled(busy).accessibilityIdentifier("migration-resume-playlist")
                    } else if pausable(status.state) {
                        Button("Pause Playlist") { run { try await coordinator.pauseMigration(session.id) } }
                            .buttonStyle(.matchingSecondary).disabled(busy).accessibilityIdentifier("migration-pause-playlist")
                    }
                    if !status.state.isTerminal && status.state != .cancelling {
                        Button("Cancel Migration", role: .destructive) { confirmingCancel = true }
                            .buttonStyle(.matchingSecondary).disabled(busy).accessibilityIdentifier("migration-cancel")
                    }
                }
            }
            .confirmationDialog("Cancel this migration?", isPresented: $confirmingCancel, titleVisibility: .visible) {
                Button("Cancel Migration", role: .destructive) { run { try await coordinator.cancelMigration(session.id) } }
                    .accessibilityIdentifier("migration-cancel-confirm")
                Button("Keep Migrating", role: .cancel) {}
            } message: {
                Text("Matching and new downloads for this playlist stop. Songs already in your library stay available offline.")
            }
        }
    }

    private func pausable(_ state: MigrationLifecycleState) -> Bool {
        [.matching, .acquiring, .waitingForNetwork, .coolingDown, .systemSuspended, .resourceDeferred].contains(state)
    }
    private func count(_ value: Int, _ label: String) -> String? { value > 0 ? "\(value) \(label)" : nil }
    private func run(_ action: @escaping () async throws -> Void) {
        busy = true; error = nil
        Task {
            defer { busy = false }
            do { try await action() } catch { self.error = "That couldn't be changed. Try again." }
        }
    }
}
