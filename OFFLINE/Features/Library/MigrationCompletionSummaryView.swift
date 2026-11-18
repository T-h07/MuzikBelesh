import SwiftUI

/// Reusable, non-intrusive completion summary. Every number is derived from persisted
/// state; dismissing only hides the highlight for this processing cycle — issues,
/// retry state and lifecycle are never changed, and the summary stays available.
struct MigrationCompletionSummaryView: View {
    @Environment(\.themePalette) private var palette
    let summary: MigrationCompletionSummary
    var highlighted = false
    var onDismiss: (() -> Void)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: AppSpacing.sm) {
            HStack(alignment: .firstTextBaseline) {
                Image(systemName: icon).foregroundStyle(summary.fullyReady ? palette.accent : statusColor)
                    .accessibilityHidden(true)
                Text(summary.outcome.title).font(.headline).foregroundStyle(AppColors.textPrimary)
                    .accessibilityIdentifier("migration-summary-title")
                Spacer(minLength: 0)
                if highlighted, let onDismiss {
                    Button("Dismiss", action: onDismiss).font(.caption).buttonStyle(.borderless).tint(palette.accent)
                        .accessibilityHint("Hides this highlight. The summary stays available.")
                        .accessibilityIdentifier("migration-summary-dismiss")
                }
            }
            Text(summary.sentence).font(.subheadline).foregroundStyle(AppColors.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("migration-summary-sentence")
            Grid(alignment: .leading, horizontalSpacing: AppSpacing.md, verticalSpacing: 4) {
                row("Original songs", summary.total, id: "total")
                row("Playable offline", summary.playable, id: "playable")
                row("Unresolved", summary.unresolved, id: "unresolved")
                if summary.unresolved > 0 {
                    if summary.needsReview > 0 { row("  Needs review", summary.needsReview, id: "review", secondary: true) }
                    if summary.failed > 0 { row("  Failed", summary.failed, id: "failed", secondary: true) }
                    if summary.waiting > 0 { row("  In progress or waiting", summary.waiting, id: "waiting", secondary: true) }
                }
                row("Skipped", summary.skipped, id: "skipped")
            }.font(.caption)
        }
        .padding(AppSpacing.md)
        .background(AppColors.backgroundSecondary, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(highlighted ? palette.accent : .clear, lineWidth: 1))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("migration-completion-summary")
    }

    private var icon: String {
        switch summary.outcome {
        case .fullyReady: "checkmark.circle.fill"
        case .finishedWithIssues: "exclamationmark.triangle.fill"
        case .paused: "pause.circle"
        case .cancelled: "xmark.circle"
        case .inProgress, .notStarted: "arrow.triangle.2.circlepath"
        }
    }
    private var statusColor: Color { summary.outcome == .finishedWithIssues ? AppColors.error : AppColors.textSecondary }

    @ViewBuilder private func row(_ label: String, _ value: Int, id: String, secondary: Bool = false) -> some View {
        GridRow {
            Text(label).foregroundStyle(secondary ? AppColors.textSecondary : AppColors.textPrimary)
            Text("\(value)").monospacedDigit().foregroundStyle(AppColors.textPrimary)
                .accessibilityIdentifier("migration-summary-" + id)
        }
    }
}

/// Dashboard entry point: the summary plus one clearly labeled navigation action that
/// stays available after matching stops, cancellation, partial completion or restart.
struct MigrationIssuesEntry: View {
    @ObservedObject var issues: MigrationIssueCoordinator
    let playlistID: String
    var body: some View {
        if let migrationID = issues.migrationID(forPlaylist: playlistID), let summary = issues.summaries[migrationID] {
            VStack(alignment: .leading, spacing: AppSpacing.sm) {
                if summary.outcome.settled || summary.outcome == .cancelled || summary.outcome == .paused {
                    if issues.hasNewCompletion(migrationID) {
                        MigrationCompletionSummaryView(summary: summary, highlighted: true) {
                            Task { await issues.dismissCompletion(migrationID) }
                        }
                    } else {
                        MigrationCompletionSummaryView(summary: summary)
                    }
                }
                NavigationLink {
                    MigrationIssuesView(issues: issues, playlistID: playlistID)
                } label: {
                    HStack {
                        Label(summary.attention > 0 ? "Migration Issues (\(summary.attention))" : "Migration Issues",
                              systemImage: summary.attention > 0 ? "exclamationmark.bubble" : "checklist")
                        Spacer(minLength: 0)
                        if summary.waiting > 0 {
                            Text("\(summary.waiting) in progress").font(.caption).foregroundStyle(AppColors.textSecondary)
                        }
                    }.frame(minHeight: 44)
                }
                .accessibilityLabel(summary.attention > 0 ? "Migration Issues, \(summary.attention) songs need attention" : "Migration Issues")
                .accessibilityIdentifier("migration-issues-link")
            }
        }
    }
}
