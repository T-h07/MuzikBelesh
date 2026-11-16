import SwiftUI
import UIKit

/// One pasted link, parsed with the app's existing YouTube URL validator.
struct ParsedYouTubeLink: Equatable, Sendable {
    enum Status: Equatable, Sendable {
        case valid(String)
        /// Same video as an earlier link in this batch, or already in the playlist.
        case duplicate(String, inPlaylist: Bool)
        case invalid(String)
    }
    let text: String
    let status: Status

    var videoID: String? {
        switch status {
        case .valid(let id), .duplicate(let id, _): id
        case .invalid: nil
        }
    }

    /// Parses links in order. Tracking parameters are ignored by the validator, so
    /// different spellings of one video are recognised as duplicates.
    static func parse(_ lines: [String], existing: Set<String>) -> [ParsedYouTubeLink] {
        var seen = Set<String>()
        return lines.compactMap { raw -> ParsedYouTubeLink? in
            let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            do {
                let id = try YouTubeURLValidator.parse(text)
                if existing.contains(id) { seen.insert(id); return ParsedYouTubeLink(text: text, status: .duplicate(id, inPlaylist: true)) }
                if !seen.insert(id).inserted { return ParsedYouTubeLink(text: text, status: .duplicate(id, inPlaylist: false)) }
                return ParsedYouTubeLink(text: text, status: .valid(id))
            } catch let error as YouTubeURLValidationError {
                return ParsedYouTubeLink(text: text, status: .invalid(message(error)))
            } catch {
                return ParsedYouTubeLink(text: text, status: .invalid("This link couldn't be read."))
            }
        }
    }

    /// Splits pasted text into candidate links (newlines, spaces, commas).
    static func split(_ text: String) -> [String] {
        text.components(separatedBy: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: ","))).filter { !$0.isEmpty }
    }

    static func message(_ error: YouTubeURLValidationError) -> String {
        switch error {
        case .empty: "Enter a YouTube link."
        case .invalidScheme: "Use a secure https:// YouTube link."
        case .untrustedHost: "This isn't a YouTube link."
        case .unsupportedPath: "This YouTube page isn't a single video."
        case .invalidVideoID: "The video ID in this link isn't valid."
        case .malformed: "This link couldn't be read."
        }
    }
}

/// "Add Songs → From YouTube Links": paste one or many links, review them, add them all.
/// Every accepted link becomes a playlist entry at once and is queued in the shared
/// download queue (Wi-Fi-only, concurrency and background rules unchanged).
struct AddYouTubeLinksView: View {
    @EnvironmentObject private var library: MusicLibraryService
    @EnvironmentObject private var container: AppContainer
    @Environment(\.dismiss) private var dismiss
    let playlistID: String
    private struct Draft: Identifiable, Equatable { let id = UUID(); var text = "" }
    @State private var pasted = ""
    @State private var drafts: [Draft] = [Draft()]
    @State private var includeDuplicates = Set<String>()
    @State private var existing = Set<String>()
    @State private var working = false
    @State private var error: String?
    @FocusState private var focused: UUID?

    private var allowsRepeats: Bool { library.isMigrationPlaylist(playlistID) }
    private var parsed: [ParsedYouTubeLink] { ParsedYouTubeLink.parse(drafts.map(\.text), existing: existing) }
    /// Video IDs to submit, in order: valid links plus duplicates the user chose to add again.
    private var submission: [String] {
        parsed.compactMap { link -> String? in
            switch link.status {
            case .valid(let id): id
            case .duplicate(let id, _): allowsRepeats && includeDuplicates.contains(link.text) ? id : nil
            case .invalid: nil
            }
        }
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    TextEditor(text: $pasted)
                        .frame(minHeight: 96).scrollContentBackground(.hidden)
                        .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                        .accessibilityLabel("Paste YouTube links").accessibilityIdentifier("youtube-links-paste")
                    HStack(spacing: AppSpacing.sm) {
                        Button { takePasted() } label: { Label("Add These Links", systemImage: "text.badge.plus") }
                            .buttonStyle(.matchingSecondary).disabled(pasted.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                            .accessibilityIdentifier("youtube-links-take-pasted")
                        Button { pasteFromClipboard() } label: { Label("Paste", systemImage: "doc.on.clipboard") }
                            .buttonStyle(.matchingSecondary).accessibilityIdentifier("youtube-links-paste-clipboard")
                    }
                } header: { Text("Paste one or more links") } footer: {
                    Text("One link per line works best. youtube.com, youtu.be, music.youtube.com and Shorts links are supported.")
                }.listRowBackground(AppColors.backgroundSecondary)

                Section {
                    ForEach($drafts) { $draft in
                        let status = ParsedYouTubeLink.parse([draft.text], existing: existing).first?.status
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                TextField("https://youtu.be/…", text: $draft.text)
                                    .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                                    .focused($focused, equals: draft.id)
                                    .accessibilityIdentifier("youtube-link-field")
                                Button { remove(draft.id) } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(AppColors.textSecondary) }
                                    .buttonStyle(.borderless).accessibilityLabel("Remove this link")
                            }
                            if let status { statusLine(status, text: draft.text) }
                        }
                    }
                    Button { addDraft() } label: { Label("Add Another Link", systemImage: "plus") }
                        .accessibilityIdentifier("youtube-links-add-another")
                } header: { Text("Links") }.listRowBackground(AppColors.backgroundPrimary)

                Section {
                    Text(summary).font(.subheadline).foregroundStyle(AppColors.textSecondary).accessibilityIdentifier("youtube-links-summary")
                    if let error { Text(error).foregroundStyle(AppColors.error) }
                    Button { submit() } label: {
                        Text(working ? "Adding…" : (submission.count == 1 ? "Add 1 Song" : "Add \(submission.count) Songs")).frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.matchingPrimaryWide).disabled(submission.isEmpty || working)
                    .accessibilityIdentifier("youtube-links-submit")
                } footer: {
                    Text("Songs appear in the playlist right away and download automatically. You can keep using the app; progress also shows in Downloads.")
                }.listRowBackground(AppColors.backgroundPrimary)
            }
            .scrollContentBackground(.hidden).screenBackground().tint(AppColors.accentPrimary)
            .navigationTitle("Add YouTube Links").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() }.disabled(working) } }
            .task { existing = (try? library.repository?.youtubeVideoIDs(inPlaylist: playlistID)) ?? [] }
        }.interactiveDismissDisabled(working)
    }

    @ViewBuilder private func statusLine(_ status: ParsedYouTubeLink.Status, text: String) -> some View {
        switch status {
        case .valid:
            Label("Ready to add", systemImage: "checkmark.circle").font(.caption).foregroundStyle(AppColors.accentPrimary)
        case .invalid(let reason):
            Label(reason, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(AppColors.error)
        case .duplicate(_, let inPlaylist):
            VStack(alignment: .leading, spacing: 4) {
                Label(inPlaylist ? "Already in this playlist" : "Same video as an earlier link", systemImage: "square.on.square")
                    .font(.caption).foregroundStyle(AppColors.warning)
                if allowsRepeats {
                    Toggle("Add it again", isOn: Binding(get: { includeDuplicates.contains(text) },
                                                         set: { if $0 { includeDuplicates.insert(text) } else { includeDuplicates.remove(text) } }))
                        .font(.caption).tint(AppColors.accentPrimary)
                } else {
                    Text("A song appears once in this playlist.").font(.caption).foregroundStyle(AppColors.textSecondary)
                }
            }
        }
    }

    private var summary: String {
        let values = parsed
        let valid = values.filter { if case .valid = $0.status { return true }; return false }.count
        let invalid = values.filter { if case .invalid = $0.status { return true }; return false }.count
        let duplicates = values.count - valid - invalid
        var parts = ["\(valid) valid"]
        if invalid > 0 { parts.append("\(invalid) invalid") }
        if duplicates > 0 { parts.append("\(duplicates) duplicate\(duplicates == 1 ? "" : "s")") }
        return parts.joined(separator: " · ")
    }

    private func takePasted() {
        let lines = ParsedYouTubeLink.split(pasted)
        guard !lines.isEmpty else { return }
        drafts.removeAll { $0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        drafts += lines.map { Draft(text: $0) }
        pasted = ""
    }
    private func pasteFromClipboard() {
        guard let value = UIPasteboard.general.string, !value.isEmpty else { error = "The clipboard doesn't contain any links."; return }
        pasted = pasted.isEmpty ? value : pasted + "\n" + value
        takePasted()
    }
    private func addDraft() {
        let draft = Draft()
        drafts.append(draft)
        focused = draft.id
    }
    private func remove(_ id: UUID) {
        drafts.removeAll { $0.id == id }
        if drafts.isEmpty { drafts = [Draft()] }
    }
    private func submit() {
        let ids = submission
        guard !ids.isEmpty else { return }
        working = true; error = nil
        Task {
            defer { working = false }
            do {
                let result: PlaylistLinkSubmissionResult
                if let acquisition = container.playlistAcquisition { result = try await acquisition.submitLinks(ids, playlistID: playlistID) }
                else if let repository = library.repository { result = try repository.submitLinks(ids, playlistID: playlistID) }
                else { throw LibraryError.operationFailed }
                if result.alreadyInPlaylist.isEmpty { dismiss() }
                else { error = "\(result.alreadyInPlaylist.count) link(s) were already in this playlist and were not added again." }
            } catch { self.error = "The songs couldn't be added. Check the links and try again." }
        }
    }
}

/// A playlist entry added by YouTube link whose audio is not in the library yet.
struct PlaylistLinkDownloadRow: View {
    @EnvironmentObject private var library: MusicLibraryService
    @EnvironmentObject private var container: AppContainer
    let link: PlaylistLinkDownloadRecord
    var body: some View {
        if let acquisition = container.playlistAcquisition {
            PlaylistLinkDownloadContent(link: link, acquisition: acquisition, downloads: container.downloads)
        } else {
            PlaylistLinkDownloadContent(link: link, acquisition: nil, downloads: container.downloads)
        }
    }
}

private struct PlaylistLinkDownloadContent: View {
    @EnvironmentObject private var library: MusicLibraryService
    let link: PlaylistLinkDownloadRecord
    let acquisition: PlaylistAcquisitionCoordinator?
    @ObservedObject var downloads: DownloadManager
    var body: some View {
        let state = acquisition?.linkStates[link.id]
        let failed = link.state == .failed
        HStack(spacing: AppSpacing.md) {
            Image(systemName: failed ? "exclamationmark.triangle" : "arrow.down.circle")
                .foregroundStyle(failed ? AppColors.error : AppColors.accentPrimary)
                .frame(width: 44, height: 44).background(AppColors.backgroundSecondary, in: RoundedRectangle(cornerRadius: 6))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).foregroundStyle(AppColors.textPrimary).lineLimit(1)
                Text(failed ? "Download failed" : (state?.label ?? "Waiting to download"))
                    .font(.caption).foregroundStyle(failed ? AppColors.error : AppColors.textSecondary)
                    .accessibilityIdentifier("link-entry-status-" + link.id)
                if failed, let failure = link.failure { Text(failure).font(.caption2).foregroundStyle(AppColors.textSecondary).lineLimit(2) }
            }
            Spacer(minLength: 0)
            if failed {
                Button("Retry") { retry() }.buttonStyle(.matchingSecondary).accessibilityIdentifier("link-entry-retry-" + link.id)
            }
            Menu {
                if failed { Button { retry() } label: { Label("Retry Download", systemImage: "arrow.clockwise") } }
                Button(role: .destructive) { remove() } label: { Label("Remove from Playlist", systemImage: "minus.circle") }
            } label: { Image(systemName: "ellipsis").foregroundStyle(AppColors.textSecondary).frame(width: 44, height: 44) }
                .accessibilityLabel("Options for \(title)").accessibilityIdentifier("link-entry-options-" + link.id)
        }
        .accessibilityIdentifier("link-entry-" + link.id)
        .swipeActions { Button("Remove from Playlist", role: .destructive) { remove() } }
    }
    private var title: String {
        let jobTitle = downloads.job(for: link.videoID)?.title ?? ""
        return jobTitle.isEmpty || jobTitle == "YouTube video" ? "YouTube video" : jobTitle
    }
    private func retry() {
        Task {
            if let acquisition { await acquisition.retryLink(id: link.id) }
            else { library.perform { try library.repository?.resetLink(id: link.id) } }
        }
    }
    private func remove() {
        Task {
            if let acquisition { await acquisition.removeLink(id: link.id) }
            else { library.perform { _ = try library.repository?.removeLink(id: link.id) } }
        }
    }
}

/// Migration diagnostics on request (playlist `•••` → Migration Details): matching and
/// download progress, completion summary, Migration Issues, review, retry and cancel.
/// The migration keeps running whether or not this is open.
struct MigrationDetailsSheet: View {
    @Environment(\.dismiss) private var dismiss
    let playlistID: String
    var body: some View {
        NavigationStack {
            List { MigrationPlaylistDashboard(playlistID: playlistID) }
                .scrollContentBackground(.hidden).screenBackground().tint(AppColors.accentPrimary)
                .navigationTitle("Migration Details").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() }.accessibilityIdentifier("migration-details-done") } }
        }
    }
}
