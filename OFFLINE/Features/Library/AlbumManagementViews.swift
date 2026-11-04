import SwiftUI

struct AlbumDetailView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var library: MusicLibraryService
    let groupID: String
    @State private var showingEditor = false
    @State private var showingTracks = false
    @State private var confirmingDelete = false
    @State private var editMode: EditMode = .inactive
    private var group: LibraryGroup? { library.albumGroups.first { $0.id == groupID } }
    private var album: StoredAlbum? { library.snapshot.albums.first { $0.id == groupID } }
    private var songs: [StoredTrack] { library.tracks(group?.trackIDs ?? []) }
    var body: some View {
        List {
            if let group {
                Section {
                    VStack(alignment: .leading, spacing: AppSpacing.md) {
                        ManagedArtworkView(path: group.artworkRelativePath, fallbackID: group.id, size: 220).frame(maxWidth: .infinity)
                        Text(group.title).font(.title.bold()).foregroundStyle(AppColors.textPrimary).accessibilityIdentifier("album-detail-name")
                        Text(group.subtitle).foregroundStyle(AppColors.textSecondary)
                        if let year = album?.releaseYear { Text(String(year)).foregroundStyle(AppColors.textSecondary) }
                        if let description = album?.description, !description.isEmpty { Text(description).foregroundStyle(AppColors.textSecondary) }
                        Text("\(songs.count) songs • \(formatDuration(songs))").font(.caption).foregroundStyle(AppColors.textSecondary)
                        CollectionPlaybackButtons(tracks: songs, kind: "album", sourceID: groupID)
                        if album != nil {
                            Button { showingTracks = true } label: { Label("Add Songs", systemImage: "plus.circle") }.accessibilityIdentifier("album-add-songs")
                        } else {
                            Text("These songs have no primary album. Create an album to organize them.").font(.caption).foregroundStyle(AppColors.textSecondary)
                            Button("Create Album") { showingEditor = true }.accessibilityIdentifier("create-album")
                        }
                    }.padding(.vertical, AppSpacing.md)
                }.listRowBackground(AppColors.backgroundPrimary)
                Section {
                    if songs.isEmpty { Text("This album is empty. Add songs from your Library.").foregroundStyle(AppColors.textSecondary) }
                    ForEach(songs) { track in
                        Group {
                            if editMode == .active {
                                HStack {
                                    Text(track.title).lineLimit(1); Spacer()
                                    Button { move(track.id, delta: -1) } label: { Image(systemName: "arrow.up").frame(width: 44, height: 44) }.buttonStyle(.borderless).accessibilityLabel("Move up \(track.title)").accessibilityIdentifier("album-move-up-" + track.id)
                                    Button { move(track.id, delta: 1) } label: { Image(systemName: "arrow.down").frame(width: 44, height: 44) }.buttonStyle(.borderless).accessibilityLabel("Move down \(track.title)").accessibilityIdentifier("album-move-down-" + track.id)
                                }
                            } else {
                                StoredTrackRow(track: track, contextTrackIDs: group.trackIDs, contextKind: "album", contextSourceID: groupID, albumID: album?.id)
                                    .swipeActions {
                                        if album != nil { Button("Remove from Album", role: .destructive) { library.perform { try library.removeAlbumTrack(track.id, albumID: groupID) } } }
                                    }
                            }
                        }.listRowBackground(AppColors.backgroundPrimary)
                    }.onMove { source, destination in
                        var order = songs.map(\.id); order.move(fromOffsets: source, toOffset: destination)
                        library.perform { try library.reorderAlbum(order, albumID: groupID) }
                    }.moveDisabled(album == nil)
                }
            } else { Text("This album was removed.").foregroundStyle(AppColors.textSecondary) }
        }
        .environment(\.editMode, $editMode)
        .scrollContentBackground(.hidden).screenBackground().navigationTitle("Album").navigationBarTitleDisplayMode(.inline).toolbar(.visible, for: .navigationBar)
        .toolbar {
            if album != nil {
                ToolbarItemGroup(placement: .primaryAction) {
                    Button(editMode == .active ? "Done" : "Reorder") { editMode = editMode == .active ? .inactive : .active }.accessibilityIdentifier("album-reorder")
                    Menu {
                        Button("Edit Album") { showingEditor = true }
                        Button("Delete Album", role: .destructive) { confirmingDelete = true }
                    } label: { Label("Album Actions", systemImage: "ellipsis.circle") }.accessibilityIdentifier("album-actions")
                }
            }
        }
        .sheet(isPresented: $showingEditor) { AlbumEditorView(albumID: album?.id) }
        .sheet(isPresented: $showingTracks) { AddTracksToPlaylistView(albumID: groupID) }
        .confirmationDialog("Delete Album?", isPresented: $confirmingDelete, titleVisibility: .visible) {
            Button("Delete Album", role: .destructive) {
                Task { do { try await library.deleteAlbum(id: groupID, confirmed: true); dismiss() } catch { library.report(error) } }
            }.accessibilityIdentifier("confirm-delete-album")
            Button("Cancel", role: .cancel) { }
        } message: { Text("Songs become unassigned. Audio files, likes, playlists, playback and queue entries are preserved.") }
    }
    private func move(_ id: String, delta: Int) {
        var order = songs.map(\.id)
        guard let index = order.firstIndex(of: id), order.indices.contains(index + delta) else { return }
        order.swapAt(index, index + delta)
        library.perform { try library.reorderAlbum(order, albumID: groupID) }
    }
}

struct AlbumEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var library: MusicLibraryService
    var albumID: String? = nil
    @State private var title = ""
    @State private var artist = ""
    @State private var year = ""
    @State private var description = ""
    @State private var artworkData: Data?
    @State private var removeArtwork = false
    @State private var selectedIDs: [String] = []
    @State private var choosingSongs = false
    @State private var saving = false
    @State private var error: String?
    private var album: StoredAlbum? { library.snapshot.albums.first { $0.id == albumID } }
    var body: some View {
        NavigationStack {
            Form {
                ArtworkDraftPicker(data: $artworkData, existingPath: removeArtwork ? nil : album?.artworkRelativePath, fallbackID: albumID ?? "new-album")
                if album?.artworkRelativePath != nil { Toggle("Remove existing artwork", isOn: $removeArtwork) }
                TextField("Album name", text: $title).accessibilityIdentifier("album-name")
                TextField("Album artist", text: $artist).accessibilityIdentifier("album-artist")
                TextField("Release year (optional)", text: $year).keyboardType(.numbersAndPunctuation).accessibilityIdentifier("album-year")
                TextField("Description", text: $description, axis: .vertical).lineLimit(3...6).accessibilityIdentifier("album-description")
                if albumID == nil {
                    Section("Songs (optional)") {
                        Button("Choose Songs") { choosingSongs = true }.accessibilityIdentifier("album-choose-songs")
                        ForEach(library.tracks(selectedIDs)) { song in
                            HStack { Text(song.title); Spacer(); Button("Remove") { selectedIDs.removeAll { $0 == song.id } }.buttonStyle(.borderless) }
                        }.onMove { selectedIDs.move(fromOffsets: $0, toOffset: $1) }
                    }
                }
                if let error { Text(error).foregroundStyle(AppColors.error).accessibilityIdentifier("editor-error") }
            }.scrollContentBackground(.hidden).screenBackground().navigationTitle(albumID == nil ? "Create Album" : "Edit Album")
                .scrollDismissesKeyboard(.interactively)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() }.disabled(saving) }
                    ToolbarItem(placement: .confirmationAction) { Button(saving ? "Saving…" : "Save") { save() }.disabled(saving).accessibilityIdentifier("album-save") }
                }
        }
        .sheet(isPresented: $choosingSongs) {
            AddTracksToPlaylistView(onSelection: { ids in for id in ids where !selectedIDs.contains(id) { selectedIDs.append(id) } })
        }
        .onAppear {
            if let album { title = album.title; artist = album.artistID == nil ? "" : library.artistName(album.artistID); year = album.releaseYear.map(String.init) ?? ""; description = album.description ?? "" }
        }
    }
    private func save() {
        let trimmed = year.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty || Int(trimmed).map({ (1...9999).contains($0) }) == true else { error = "Enter a release year between 1 and 9999, or leave it empty."; return }
        saving = true
        Task {
            do {
                _ = try await library.saveAlbum(id: albumID, draft: AlbumDraft(title: title, artist: artist, releaseYear: Int(trimmed), description: description), trackIDs: albumID == nil ? selectedIDs : nil, artworkData: artworkData, removeArtwork: removeArtwork)
                saving = false; dismiss()
            } catch { self.error = MusicLibraryService.message(error); saving = false }
        }
    }
}
