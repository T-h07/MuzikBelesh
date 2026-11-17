import SwiftUI

/// Phase 10.7: the one place to investigate and fix problematic songs of an imported
/// playlist. Rows are the persisted, classified report (one per original occurrence),
/// observed from `MigrationIssueCoordinator`; closing this screen changes nothing.
struct MigrationIssuesView: View {
    @Environment(\.themePalette) private var palette
    @EnvironmentObject private var container: AppContainer
    @ObservedObject var issues: MigrationIssueCoordinator
    let playlistID: String
    @State private var filter: MigrationIssueFilter = .all
    @State private var bulkRunning = false
    @State private var bulkMessage: String?
    @State private var bulkError: String?
    @State private var rowMessages: [UUID: String] = [:]
    @State private var rowErrors: [UUID: String] = [:]
    @State private var skipping: MigrationOccurrenceReport?

    var body: some View {
        List {
            if let report = issues.report(forPlaylist: playlistID) {
                Section {
                    MigrationCompletionSummaryView(summary: report.summary)
                        .listRowInsets(EdgeInsets(top: 8, leading: 12, bottom: 8, trailing: 12))
                    filterBar(report)
                    if eligibleCount(report) > 0 {
                        Button { retryAll(report.summary.migrationID) } label: {
                            Label(bulkRunning ? "Queuing retries…" : "Retry All Eligible Failures (\(eligibleCount(report)))", systemImage: "arrow.clockwise")
                        }.buttonStyle(.matchingPrimaryWide).disabled(bulkRunning || report.context.cancelled)
                            .accessibilityIdentifier("migration-issues-retry-all")
                    }
                    if let bulkMessage { Text(bulkMessage).font(.caption).foregroundStyle(palette.accent).accessibilityIdentifier("migration-issues-bulk-message") }
                    if let bulkError { Text(bulkError).font(.caption).foregroundStyle(AppColors.error) }
                    if let error = issues.lastError { Text(error).font(.caption).foregroundStyle(AppColors.error) }
                }.listRowBackground(AppColors.backgroundPrimary)
                let rows = report.rows(filter)
                Section(filter.title) {
                    if rows.isEmpty {
                        Text(emptyText).foregroundStyle(AppColors.textSecondary).accessibilityIdentifier("migration-issues-empty")
                    }
                    // Lazy, stable identities: one row per source occurrence.
                    ForEach(rows) { row in
                        MigrationIssueListRow(row: row, playlistID: playlistID, issues: issues,
                                              message: rowMessages[row.id], error: rowErrors[row.id],
                                              retry: { retry(row) }, skip: { skipping = row }, restore: { restore(row) })
                    }
                }.listRowBackground(AppColors.backgroundPrimary)
            } else {
                Section {
                    ProgressView().tint(palette.accent)
                    Text("Reading migration results…").foregroundStyle(AppColors.textSecondary)
                }.listRowBackground(AppColors.backgroundPrimary)
            }
        }
        .scrollContentBackground(.hidden).screenBackground().tint(palette.accent)
        .navigationTitle("Migration Issues").navigationBarTitleDisplayMode(.inline)
        .onAppear { issues.requestReconcile(immediately: true) }
        .refreshable { await issues.reconcileNow() }
        .confirmationDialog("Skip this song?", isPresented: Binding(get: { skipping != nil }, set: { if !$0 { skipping = nil } }),
                            titleVisibility: .visible, presenting: skipping) { row in
            Button("Skip Song", role: .destructive) { skip(row) }.accessibilityIdentifier("migration-issues-skip-confirm")
            Button("Cancel", role: .cancel) { skipping = nil }
        } message: { row in
            Text("“\(row.entry.source.title)” stays listed at position \(row.position + 1) as skipped. No downloaded music is deleted, and you can restore it later.")
        }
    }

    private var emptyText: String {
        switch filter {
        case .all: "No songs need attention."
        case .needsReview: "No songs are waiting for your review."
        case .failed: "No songs failed."
        case .waiting: "Nothing is waiting or retrying."
        case .skipped: "No songs were skipped."
        case .resolved: "No songs have been resolved yet."
        }
    }

    private func eligibleCount(_ report: MigrationIssueReport) -> Int {
        report.occurrences.filter { $0.assessment.disposition == .failed
            && ($0.assessment.actions.contains(.retrySong) || $0.assessment.actions.contains(.retryDownload)) }.count
    }

    private func filterBar(_ report: MigrationIssueReport) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: AppSpacing.sm) {
                ForEach(MigrationIssueFilter.allCases) { value in
                    let count = report.count(value)
                    Button { filter = value } label: {
                        Text("\(value.title) \(count)").font(.caption.weight(.semibold)).lineLimit(1)
                            .padding(.horizontal, 12).frame(minHeight: 36)
                            .foregroundStyle(filter == value ? palette.onAccent : AppColors.textPrimary)
                            .background(filter == value ? palette.accent : AppColors.backgroundSecondary, in: Capsule())
                    }.buttonStyle(.plain)
                        .accessibilityLabel("\(value.title), \(count)")
                        .accessibilityAddTraits(filter == value ? .isSelected : [])
                        .accessibilityIdentifier("migration-issues-filter-" + value.rawValue)
                }
            }.padding(.vertical, 2)
        }
    }

    private func retryAll(_ migrationID: UUID) {
        bulkRunning = true; bulkError = nil; bulkMessage = nil
        Task {
            defer { bulkRunning = false }
            do { bulkMessage = try await issues.retryAllEligible(migrationID: migrationID).message }
            catch { bulkError = (error as? LocalizedError)?.errorDescription ?? "Retries couldn't be queued. Try again." }
        }
    }

    private func retry(_ row: MigrationOccurrenceReport) {
        rowErrors[row.id] = nil; rowMessages[row.id] = nil
        Task {
            do { rowMessages[row.id] = try await issues.retry(row) }
            catch { rowErrors[row.id] = (error as? LocalizedError)?.errorDescription ?? "The retry couldn't be scheduled. Try again." }
        }
    }

    private func skip(_ row: MigrationOccurrenceReport) {
        skipping = nil; rowErrors[row.id] = nil
        Task {
            do { try await issues.skip(row); rowMessages[row.id] = "Skipped." }
            catch { rowErrors[row.id] = (error as? LocalizedError)?.errorDescription ?? "This song couldn't be skipped. Try again." }
        }
    }

    private func restore(_ row: MigrationOccurrenceReport) {
        rowErrors[row.id] = nil
        Task {
            do { try await issues.restore(row); rowMessages[row.id] = "Restored." }
            catch { rowErrors[row.id] = (error as? LocalizedError)?.errorDescription ?? "This song couldn't be restored. Try again." }
        }
    }
}

/// One source occurrence: position, original metadata, explanation, status and the
/// actions valid for its actual state. Details open in place; the list keeps its filter
/// and scroll position.
private struct MigrationIssueListRow: View {
    @Environment(\.themePalette) private var palette
    let row: MigrationOccurrenceReport
    let playlistID: String
    @ObservedObject var issues: MigrationIssueCoordinator
    let message: String?
    let error: String?
    let retry: () -> Void
    let skip: () -> Void
    let restore: () -> Void

    var body: some View {
        let assessment = row.assessment
        let busy = issues.busyEntries.contains(row.id)
        VStack(alignment: .leading, spacing: AppSpacing.xs) {
            NavigationLink {
                MigrationIssueDetailView(issues: issues, playlistID: playlistID, occurrenceID: row.id)
            } label: {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text("\(row.position + 1).").foregroundStyle(AppColors.textSecondary).monospacedDigit()
                        Text(row.entry.source.title).foregroundStyle(AppColors.textPrimary).lineLimit(2)
                    }
                    Text(([row.entry.source.primaryArtist ?? "Unknown Artist"] + [row.entry.source.album].compactMap { $0 }).joined(separator: " · "))
                        .font(.caption).foregroundStyle(AppColors.textSecondary).lineLimit(1)
                    if let explanation = assessment.explanation {
                        Text(explanation).font(.caption).foregroundStyle(AppColors.textPrimary).fixedSize(horizontal: false, vertical: true)
                    }
                    Text(statusLine).font(.caption.weight(.semibold))
                        .foregroundStyle(assessment.disposition.needsAttention ? AppColors.error : palette.accent)
                        .accessibilityIdentifier("migration-issue-status-" + row.id.uuidString)
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(accessibilityText)
            .accessibilityIdentifier("migration-issue-row-" + row.id.uuidString)
            HStack(spacing: AppSpacing.sm) {
                if assessment.disposition == .failed, assessment.actions.contains(.retryDownload) || assessment.actions.contains(.retrySong) {
                    Button(assessment.actions.contains(.retryDownload) ? "Retry Download" : "Search Again", action: retry)
                        .buttonStyle(.matchingSecondary).disabled(busy)
                        .accessibilityIdentifier("migration-issue-retry-" + row.id.uuidString)
                }
                if assessment.actions.contains(.skip) && assessment.disposition != .waiting {
                    Button("Skip", action: skip).buttonStyle(.matchingSecondary).disabled(busy)
                        .accessibilityLabel("Skip \(row.entry.source.title)")
                        .accessibilityIdentifier("migration-issue-skip-" + row.id.uuidString)
                }
                if assessment.actions.contains(.restore) {
                    Button("Restore Song", action: restore).buttonStyle(.matchingSecondary).disabled(busy)
                        .accessibilityIdentifier("migration-issue-restore-" + row.id.uuidString)
                }
                if busy { ProgressView().tint(palette.accent) }
            }
            if let message { Text(message).font(.caption).foregroundStyle(palette.accent) }
            if let error { Text(error).font(.caption).foregroundStyle(AppColors.error) }
        }.padding(.vertical, 4)
    }

    private var statusLine: String {
        var text = row.assessment.status
        if let next = row.assessment.nextRetryAt, next > Date() {
            text += " · next try " + next.formatted(date: .omitted, time: .shortened)
        }
        if row.assessment.retryCount > 0 { text += " · \(row.assessment.retryCount) attempt\(row.assessment.retryCount == 1 ? "" : "s")" }
        return text
    }

    private var accessibilityText: String {
        var parts = ["Position \(row.position + 1)", row.entry.source.title, row.entry.source.primaryArtist ?? "Unknown Artist"]
        if let category = row.assessment.category { parts.append(category.title) }
        parts.append(row.assessment.status)
        return parts.joined(separator: ", ")
    }
}

/// Destination for a migration attention notification.
struct NotificationMigrationIssuesSheet: View {
    @EnvironmentObject private var container: AppContainer
    @Environment(\.dismiss) private var dismiss
    let playlistID: String
    var body: some View {
        NavigationStack {
            Group {
                if let issues = container.migrationIssues {
                    MigrationIssuesView(issues: issues, playlistID: playlistID)
                } else {
                    Text("Migration issues aren't available.").foregroundStyle(AppColors.textSecondary)
                }
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
                ToolbarItem(placement: .primaryAction) {
                    NavigationLink("Playlist") { PlaylistDetailView(playlistID: playlistID) }
                        .accessibilityIdentifier("migration-issues-open-playlist")
                }
            }
        }
    }
}
