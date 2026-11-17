import SwiftUI

/// Where a song's options were opened from. Removal always targets the occurrence.
enum SongOptionsContext: Identifiable {
    /// An ordinary library song, optionally inside an ordinary playlist.
    case library(trackID: String, playlistID: String?, contextIDs: [String], kind: String)
    /// A song added manually to an imported playlist (one occurrence).
    case manual(row: LocalPlaylistRow, playlistID: String)
    /// A Spotify-imported occurrence that is ready with verified offline audio.
    case imported(entryID: UUID, playlistID: String)

    var id: String {
        switch self {
        case .library(let trackID, let playlistID, _, _): "library-\(trackID)-\(playlistID ?? "")"
        case .manual(let row, _): "manual-" + row.id
        case .imported(let entryID, _): "imported-" + entryID.uuidString
        }
    }
}

/// A normal song screen (Spotify / Apple Music style) for playable songs: large artwork,
/// title, artist, duration, Play/Pause and song actions. Matching candidates are never
/// shown here; Change Video is the explicit entry point for replacing the recording.
struct SongOptionsView: View {
    @Environment(\.themePalette) private var palette
    @EnvironmentObject private var library: MusicLibraryService
    @EnvironmentObject private var container: AppContainer
    @EnvironmentObject private var audioPlayer: AudioPlayerService
    @Environment(\.dismiss) private var dismiss
    let context: SongOptionsContext
    @State private var accepted: PlaylistMigrationCandidate?
    @State private var showingPlaylists = false
    @State private var changingVideo = false
    @State private var confirmingDownloadDeletion = false
    @State private var confirmingLibraryDeletion = false
    @State private var working = false
    @State private var error: String?

    private struct Details {
        let track: StoredTrack
        let title: String
        let artist: String
        let album: String?
        let durationMs: Int64?
        let playlistID: String?
    }

    private var details: Details? {
        switch context {
        case .library(let trackID, let playlistID, _, _):
            guard let track = library.track(trackID) else { return nil }
            return Details(track: track, title: track.title, artist: library.artistName(track.artistID), album: library.albumTitle(track.albumID),
                           durationMs: track.durationMs, playlistID: playlistID)
        case .manual(let row, let playlistID):
            let track = library.track(row.track.id) ?? row.track
            return Details(track: track, title: track.title, artist: library.artistName(track.artistID), album: library.albumTitle(track.albumID),
                           durationMs: track.durationMs, playlistID: playlistID)
        case .imported(let entryID, let playlistID):
            // The song is identified by its original metadata; the artwork and duration
            // come from the verified recording that actually plays.
            guard let row = library.snapshot.migrationPresentations[playlistID]?.rowsByID[entryID], let track = row.playableTrack else { return nil }
            let source = row.entry.source
            return Details(track: track, title: source.title, artist: source.primaryArtist ?? library.artistName(track.artistID),
                           album: source.album, durationMs: track.durationMs ?? source.durationMs, playlistID: playlistID)
        }
    }

    var body: some View {
        NavigationStack {
            Group {
                if let details { content(details) }
                else {
                    VStack(spacing: AppSpacing.md) {
                        Text("This song is no longer available here.").foregroundStyle(AppColors.textSecondary)
                        Button("Close") { dismiss() }.buttonStyle(.matchingSecondary)
                    }.frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .screenBackground()
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } } }
            .navigationBarTitleDisplayMode(.inline)
        }
        .task(id: importedEntryID) { await loadDecision() }
    }

    private var importedEntryID: UUID? {
        if case .imported(let entryID, _) = context { return entryID }
        return nil
    }

    @ViewBuilder private func content(_ details: Details) -> some View {
        let track = details.track
        let current = audioPlayer.state.currentTrackID == track.id
        let playing = current && audioPlayer.state.isPlaying
        ScrollView {
            VStack(spacing: AppSpacing.lg) {
                StoredArtworkView(track: track, size: 260)
                    .clipShape(RoundedRectangle(cornerRadius: 12)).shadow(radius: 12)
                    .accessibilityLabel("Artwork for \(details.title)")
                    .accessibilityIdentifier("song-options-artwork")
                VStack(spacing: 6) {
                    Text(details.title).font(.title2.bold()).foregroundStyle(AppColors.textPrimary).multilineTextAlignment(.center)
                        .lineLimit(3).accessibilityIdentifier("song-options-title")
                    Text(details.artist).font(.headline).foregroundStyle(palette.accent).lineLimit(2)
                        .accessibilityIdentifier("song-options-artist")
                    let secondary = [details.album, details.durationMs.map(Self.duration)].compactMap { $0 }.joined(separator: " · ")
                    if !secondary.isEmpty {
                        Text(secondary).font(.subheadline).foregroundStyle(AppColors.textSecondary).accessibilityIdentifier("song-options-subtitle")
                    }
                }.padding(.horizontal, AppSpacing.lg)
                Button { togglePlayback(details, current: current) } label: {
                    Label(playing ? "Pause" : "Play", systemImage: playing ? "pause.fill" : "play.fill").frame(maxWidth: .infinity, minHeight: 48)
                }
                .buttonStyle(.borderedProminent).tint(palette.accent).foregroundStyle(palette.onAccent)
                .disabled(track.availability != .available)
                .padding(.horizontal, AppSpacing.lg)
                .accessibilityIdentifier("song-options-play")
                if let pending = replacementTitle {
                    Text("Replacing with “\(pending)”. This recording keeps playing until the new one is verified.")
                        .font(.caption).foregroundStyle(AppColors.textSecondary).multilineTextAlignment(.center).padding(.horizontal, AppSpacing.lg)
                }
                actions(details)
                if let error { Text(error).font(.caption).foregroundStyle(AppColors.error).padding(.horizontal, AppSpacing.lg) }
            }.padding(.vertical, AppSpacing.lg)
        }
        .sheet(isPresented: $showingPlaylists) { AddToPlaylistView(trackIDs: [track.id]) }
        .sheet(isPresented: $changingVideo) { changeVideoSheet }
        .confirmationDialog("Delete this download?", isPresented: $confirmingDownloadDeletion, titleVisibility: .visible) {
            Button("Delete Download", role: .destructive) { deleteAudio(track) }.accessibilityIdentifier("song-options-confirm-delete-download")
            Button("Cancel", role: .cancel) { }
        } message: { Text(downloadDeletionMessage(track)) }
        .confirmationDialog("Delete from Library?", isPresented: $confirmingLibraryDeletion, titleVisibility: .visible) {
            Button("Delete from Library", role: .destructive) { deleteAudio(track) }.accessibilityIdentifier("song-options-confirm-delete-library")
            Button("Cancel", role: .cancel) { }
        } message: { Text(libraryDeletionMessage(track)) }
    }

    @ViewBuilder private func actions(_ details: Details) -> some View {
        let track = details.track
        VStack(spacing: 0) {
            row("Play Next", "text.insert", id: "song-options-play-next") { container.audioPlayer.queue.playNext(trackID: track.id) }
                .disabled(track.availability != .available)
            row("Add to Queue", "text.badge.plus", id: "song-options-queue") { container.audioPlayer.queue.addToQueue(trackID: track.id) }
                .disabled(track.availability != .available)
            row("Add to Playlist", "rectangle.stack.badge.plus", id: "song-options-add-to-playlist") { showingPlaylists = true }
            if case .imported = context, accepted != nil {
                row("Change Video", "arrow.triangle.2.circlepath", id: "song-options-change-video") { changingVideo = true }
            }
            if let playlistID = details.playlistID {
                row("Remove from Playlist", "minus.circle", id: "song-options-remove", destructive: true) { remove(playlistID: playlistID) }
            }
            if case .imported = context, track.metadataSource == "youtube", library.playlistUses(of: track.id) == 0 {
                row("Delete Download", "arrow.down.circle.dotted", id: "song-options-delete-download", destructive: true) { confirmingDownloadDeletion = true }
            }
            row("Delete from Library", "trash", id: "song-options-delete-library", destructive: true) { confirmingLibraryDeletion = true }
        }
        .disabled(working)
        .background(AppColors.backgroundSecondary, in: RoundedRectangle(cornerRadius: 12))
        .padding(.horizontal, AppSpacing.lg)
    }

    private func row(_ title: String, _ icon: String, id: String, destructive: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: AppSpacing.md) {
                Image(systemName: icon).frame(width: 24)
                Text(title)
                Spacer()
            }
            .foregroundStyle(destructive ? AppColors.error : AppColors.textPrimary)
            .frame(minHeight: 50).padding(.horizontal, AppSpacing.md).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(id)
    }

    @ViewBuilder private var changeVideoSheet: some View {
        if case .imported(let entryID, let playlistID) = context,
           let row = library.snapshot.migrationPresentations[playlistID]?.rowsByID[entryID],
           let accepted, let repository = library.storage?.playlistMigrations {
            NavigationStack {
                List {
                    Section {
                        RecordingReplacementControls(entry: row.entry, accepted: accepted, repository: repository,
                                                     lookup: container.youtubeManualLookup) { Task { await loadDecision() } }
                    } footer: {
                        Text("The current recording keeps playing until the new video is downloaded and verified. If it fails or you cancel, nothing changes.")
                    }.listRowBackground(AppColors.backgroundPrimary)
                }
                .scrollContentBackground(.hidden).screenBackground()
                .navigationTitle("Change Video").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Done") { changingVideo = false } } }
            }
        } else {
            Text("This song can't change its video right now.").foregroundStyle(AppColors.textSecondary)
        }
    }

    private var replacementTitle: String? {
        guard let importedEntryID else { return nil }
        return container.playlistAcquisition?.replacement(for: importedEntryID)?.title
    }

    private func loadDecision() async {
        guard let importedEntryID, let repository = library.storage?.playlistMigrations else { accepted = nil; return }
        accepted = try? await repository.candidates(entryID: importedEntryID).first { $0.decision == .accepted }
    }

    private func togglePlayback(_ details: Details, current: Bool) {
        if current { Task { await audioPlayer.togglePlayback() }; return }
        switch context {
        case .library(let trackID, _, let contextIDs, let kind):
            Task { await library.play(trackID, ids: contextIDs.isEmpty ? [trackID] : contextIDs, kind: kind, sourceID: details.playlistID) }
        case .manual(let row, let playlistID):
            Task { await library.playMigration(playlistID: playlistID, occurrenceID: row.occurrence.playbackID) }
        case .imported(let entryID, let playlistID):
            Task { await library.playMigration(playlistID: playlistID, occurrenceID: entryID.uuidString) }
        }
    }

    private func remove(playlistID: String) {
        switch context {
        case .library(let trackID, _, _, _): library.removeFromOrdinaryPlaylist(trackID, playlistID: playlistID); dismiss()
        case .manual(let row, _): library.removeManualRow(row, playlistID: playlistID); dismiss()
        case .imported(let entryID, _):
            let title = details?.title ?? "Song"
            working = true
            Task {
                await library.removeImportedOccurrence(entryID, title: title, playlistID: playlistID)
                working = false
                dismiss()
            }
        }
    }

    /// Both deletions use the library's existing safe deletion (journaled file removal;
    /// imported occurrences sharing the recording stay as placeholders that can be
    /// downloaded again). Delete Download is offered only when no ordinary playlist or
    /// manual occurrence would lose the song.
    private func deleteAudio(_ track: StoredTrack) {
        working = true; error = nil
        Task {
            defer { working = false }
            do { _ = try await library.deleteTrack(id: track.id, confirmed: true); dismiss() }
            catch { self.error = MusicLibraryService.message(error) }
        }
    }

    private func downloadDeletionMessage(_ track: StoredTrack) -> String {
        let shared = library.importedUses(of: track.id)
        let others = shared > 1 ? " \(shared - 1) other imported song\(shared == 2 ? " uses" : "s use") this recording and will also need it downloaded again." : ""
        return "The downloaded audio is removed from this iPhone. The song stays in its playlist and can be downloaded again from Migration Issues." + others
    }

    private func libraryDeletionMessage(_ track: StoredTrack) -> String {
        let playlists = library.playlistUses(of: track.id), imported = library.importedUses(of: track.id)
        var text = "This removes the audio file from Muzik Belesh, with its likes and queue references."
        if playlists > 0 { text += " It is removed from \(playlists) playlist\(playlists == 1 ? "" : "s") it was added to." }
        if imported > 0 { text += " \(imported) imported song\(imported == 1 ? " keeps its place" : "s keep their place") but will need audio again." }
        return text
    }

    static func duration(_ ms: Int64) -> String { String(format: "%d:%02d", ms / 60000, (ms / 1000) % 60) }
}

/// Feedback for Remove from Playlist with an Undo action. Hides itself after a few seconds.
struct PlaylistRemovalUndoBanner: View {
    @Environment(\.themePalette) private var palette
    @EnvironmentObject private var library: MusicLibraryService
    let undo: PlaylistRemovalUndo
    var body: some View {
        HStack(spacing: AppSpacing.md) {
            Text("Removed “\(undo.title)” from this playlist").font(.subheadline).foregroundStyle(AppColors.textPrimary).lineLimit(2)
                .accessibilityIdentifier("playlist-removal-message")
            Spacer(minLength: 0)
            Button("Undo") { Task { await library.undoRemoval() } }
                .font(.subheadline.weight(.semibold)).foregroundStyle(palette.accent).frame(minHeight: 44)
                .accessibilityIdentifier("playlist-removal-undo")
        }
        .padding(.horizontal, AppSpacing.lg).padding(.vertical, AppSpacing.sm)
        .background(AppColors.backgroundTertiary, in: RoundedRectangle(cornerRadius: 12))
        .padding(.horizontal, AppSpacing.md).padding(.bottom, AppSpacing.sm)
        .task(id: undo.id) {
            try? await Task.sleep(for: .seconds(6))
            if library.pendingUndo?.id == undo.id { library.pendingUndo = nil }
        }
    }
}
