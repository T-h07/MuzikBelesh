import SwiftUI

/// One source occurrence: original Spotify metadata, the classified issue, candidate
/// evidence (the existing review experience) and only the recovery actions that make
/// sense for its actual state. Every action is delegated to its owning subsystem.
struct MigrationIssueDetailView: View {
    @EnvironmentObject private var container: AppContainer
    @EnvironmentObject private var library: MusicLibraryService
    @ObservedObject var issues: MigrationIssueCoordinator
    let playlistID: String
    let occurrenceID: UUID
    @State private var attaching: PlaylistMigrationEntry?
    @State private var importing: PlaylistMigrationEntry?
    @State private var confirmingSkip = false
    @State private var confirmingRelease = false
    @State private var message: String?
    @State private var error: String?

    var body: some View {
        List {
            if let report = issues.report(forPlaylist: playlistID), let row = report.occurrence(occurrenceID) {
                Section("Original Spotify Song") {
                    MigrationSourceMetadataView(source: row.entry.source, showsIdentity: true)
                }.listRowBackground(AppColors.backgroundPrimary)
                issueSection(row)
                actionsSection(row, cancelled: report.context.cancelled)
                if let repository = library.storage?.playlistMigrations,
                   row.assessment.stage == .matching || row.assessment.actions.contains(.reviewCandidates) || row.entry.status == .needsReview {
                    // Reuses the existing candidate review (confirm, reject, manual YouTube link).
                    MigrationCandidateInspection(entry: row.entry, repository: repository, lookup: container.youtubeManualLookup)
                        .listRowBackground(AppColors.backgroundPrimary)
                }
                if row.resolvedIssues > 0 {
                    Section("History") {
                        Text(row.resolvedIssues == 1 ? "1 earlier problem with this song was resolved." : "\(row.resolvedIssues) earlier problems with this song were resolved.")
                            .font(.caption).foregroundStyle(AppColors.textSecondary)
                    }.listRowBackground(AppColors.backgroundPrimary)
                }
            } else {
                Text("This song is no longer part of the migration report.").foregroundStyle(AppColors.textSecondary)
                    .listRowBackground(AppColors.backgroundPrimary)
            }
        }
        .scrollContentBackground(.hidden).screenBackground().tint(AppColors.accentPrimary)
        .navigationTitle("Song Issue").navigationBarTitleDisplayMode(.inline)
        .sheet(item: $attaching, onDismiss: { issues.requestReconcile(immediately: true) }) { ResolveMigrationPlaceholderView(entry: $0) }
        .sheet(item: $importing, onDismiss: { issues.requestReconcile(immediately: true) }) { AcquisitionLocalImportView(entry: $0) }
    }

    @ViewBuilder private func issueSection(_ row: MigrationOccurrenceReport) -> some View {
        let assessment = row.assessment
        Section("Current Status") {
            if let category = assessment.category {
                Text(category.title).font(.headline)
                    .foregroundStyle(assessment.disposition.needsAttention ? AppColors.error : AppColors.textPrimary)
                    .accessibilityIdentifier("migration-issue-category")
            }
            if let explanation = assessment.explanation { Text(explanation).fixedSize(horizontal: false, vertical: true) }
            LabeledContent("Status", value: assessment.status).accessibilityIdentifier("migration-issue-detail-status")
            if let stage = assessment.stage { LabeledContent("Stage", value: stageTitle(stage)) }
            if assessment.disposition.isUnresolved {
                LabeledContent("Recovery", value: assessment.automaticRecovery ? "Automatic" : (assessment.disposition == .waiting ? "Waiting for you to resume" : "Needs your action"))
            }
            if assessment.retryCount > 0 { LabeledContent("Attempts", value: String(assessment.retryCount)) }
            if let next = assessment.nextRetryAt, next > Date() {
                LabeledContent("Next attempt") { Text(next, style: .relative) }
            }
            if let last = assessment.lastAttemptAt {
                LabeledContent("Last attempt", value: last.formatted(date: .abbreviated, time: .shortened))
            }
            if row.pendingCandidates > 0 {
                LabeledContent("Suggested recordings", value: String(row.pendingCandidates))
            }
            if let state = container.playlistAcquisition?.displayStates[row.id], row.entry.localTrackID == nil {
                LabeledContent("Download", value: state.label)
            }
        }.listRowBackground(AppColors.backgroundPrimary)
    }

    @ViewBuilder private func actionsSection(_ row: MigrationOccurrenceReport, cancelled: Bool) -> some View {
        let actions = row.assessment.actions
        let busy = issues.busyEntries.contains(row.id)
        if !actions.isEmpty {
            Section("Fix This Song") {
                if actions.contains(.retryDownload) {
                    Button { retry(row) } label: { Label("Retry Download", systemImage: "arrow.clockwise") }
                        .buttonStyle(.matchingPrimaryWide).disabled(busy).accessibilityIdentifier("migration-issue-detail-retry-download")
                } else if actions.contains(.retrySong) && !cancelled {
                    Button { retry(row) } label: { Label("Search Again", systemImage: "magnifyingglass") }
                        .buttonStyle(.matchingPrimaryWide).disabled(busy).accessibilityIdentifier("migration-issue-detail-retry-song")
                }
                if actions.contains(.chooseOtherRecording) {
                    Button { confirmingRelease = true } label: { Label("Choose Other Recording", systemImage: "rectangle.stack") }
                        .buttonStyle(.matchingSecondaryWide).disabled(busy).accessibilityIdentifier("migration-issue-detail-choose-other")
                }
                if actions.contains(.attachLocalRecording) {
                    Button { prepare(row) { attaching = $0 } } label: { Label("Use Song From Library", systemImage: "music.note.list") }
                        .buttonStyle(.matchingSecondaryWide).disabled(busy).accessibilityIdentifier("migration-issue-detail-attach")
                }
                if actions.contains(.importLocalFile) {
                    Button { prepare(row) { importing = $0 } } label: { Label("Import Local Audio", systemImage: "folder") }
                        .buttonStyle(.matchingSecondaryWide).disabled(busy).accessibilityIdentifier("migration-issue-detail-import")
                }
                if actions.contains(.skip) {
                    Button(role: .destructive) { confirmingSkip = true } label: { Label("Skip Song", systemImage: "forward") }
                        .buttonStyle(.matchingSecondaryWide).disabled(busy).accessibilityIdentifier("migration-issue-detail-skip")
                }
                if actions.contains(.restore) {
                    Button { restore(row) } label: { Label("Restore Song", systemImage: "arrow.uturn.backward") }
                        .buttonStyle(.matchingSecondaryWide).disabled(busy).accessibilityIdentifier("migration-issue-detail-restore")
                }
                if busy { ProgressView().tint(AppColors.accentPrimary) }
                if let message { Text(message).font(.caption).foregroundStyle(AppColors.accentPrimary).accessibilityIdentifier("migration-issue-detail-message") }
                if let error { Text(error).font(.caption).foregroundStyle(AppColors.error) }
            }
            .listRowBackground(AppColors.backgroundPrimary)
            .confirmationDialog("Skip this song?", isPresented: $confirmingSkip, titleVisibility: .visible) {
                Button("Skip Song", role: .destructive) { skip(row) }
                Button("Cancel", role: .cancel) { }
            } message: {
                Text("It stays listed at position \(row.position + 1) as skipped. No downloaded music is deleted, and you can restore it later.")
            }
            .confirmationDialog("Choose a different recording?", isPresented: $confirmingRelease, titleVisibility: .visible) {
                Button("Choose Other Recording") { release(row) }
                Button("Cancel", role: .cancel) { }
            } message: {
                Text("The current recording is set aside and won't be suggested again. Nothing downloads until you confirm another recording.")
            }
        }
    }

    private func stageTitle(_ stage: MigrationIssueStage) -> String {
        switch stage {
        case .matching: "Finding a recording"
        case .acquisition: "Downloading audio"
        case .association: "Linking local audio"
        }
    }

    private func run(_ action: @escaping () async throws -> String?) {
        error = nil; message = nil
        Task {
            do { message = try await action() }
            catch { self.error = (error as? LocalizedError)?.errorDescription ?? "That couldn't be done. Try again." }
        }
    }
    private func retry(_ row: MigrationOccurrenceReport) { run { try await issues.retry(row) } }
    private func skip(_ row: MigrationOccurrenceReport) { run { try await issues.skip(row); return "Skipped. You can restore this song any time." } }
    private func restore(_ row: MigrationOccurrenceReport) { run { try await issues.restore(row); return "Restored." } }
    private func release(_ row: MigrationOccurrenceReport) {
        run { try await issues.releaseSelection(row); return "Choose another recording from the suggestions below, or paste a YouTube link." }
    }
    private func prepare(_ row: MigrationOccurrenceReport, present: @escaping (PlaylistMigrationEntry) -> Void) {
        run {
            let entry = try await issues.prepareReassociation(row)
            present(entry)
            return nil
        }
    }
}
