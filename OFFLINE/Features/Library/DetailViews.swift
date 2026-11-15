import SwiftUI
import PhotosUI

struct PlaylistDetailView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var library: MusicLibraryService
    let playlistID: String
    @State private var showingEditor = false
    @State private var showingTracks = false
    @State private var confirmingDelete = false
    @State private var editMode: EditMode = .inactive
    private var playlist: StoredPlaylist? { library.snapshot.playlists.first { $0.id == playlistID } }
    private var songs: [StoredTrack] { library.playlistTracks(playlistID) }
    private var migrationManaged: Bool { library.isMigrationPlaylist(playlistID) }
    var body: some View {
        List {
            if let playlist {
                Section {
                    VStack(alignment: .leading, spacing: AppSpacing.md) {
                        ManagedArtworkView(path: playlist.artworkRelativePath ?? songs.compactMap(\.artworkRelativePath).first, fallbackID: playlist.id, size: 220).frame(maxWidth: .infinity)
                        Text(playlist.name).font(.title.bold()).foregroundStyle(AppColors.textPrimary).accessibilityIdentifier("playlist-detail-name")
                        if let description = playlist.description, !description.isEmpty { Text(description).foregroundStyle(AppColors.textSecondary) }
                        if migrationManaged {
                            MigrationPlaylistPlaybackHeader(playlistID: playlistID)
                            Button { showingTracks = true } label: { Label("Add Songs", systemImage: "plus.circle") }.accessibilityIdentifier("playlist-add-songs")
                        } else {
                            Text("\(songs.count) songs • \(formatDuration(songs))").font(.caption).foregroundStyle(AppColors.textSecondary)
                            CollectionPlaybackButtons(tracks: songs, kind: "playlist", sourceID: playlist.id)
                            Button { showingTracks = true } label: { Label("Add Songs", systemImage: "plus.circle") }.accessibilityIdentifier("playlist-add-songs")
                        }
                    }.padding(.vertical, AppSpacing.md)
                }.listRowBackground(AppColors.backgroundPrimary)
                if migrationManaged { MigrationPlaylistDashboard(playlistID: playlistID) }
                Section {
                    if migrationManaged {
                        ForEach(library.migrationRows(playlistID)) { row in
                            MigrationPlaylistOccurrenceRow(row: row, playlistID: playlistID)
                                .listRowBackground(AppColors.backgroundPrimary)
                        }
                        ForEach(library.manualRows(playlistID)) { row in
                            HStack {
                                StoredArtworkView(track: row.track, size: 44)
                                VStack(alignment: .leading) {
                                    Text(row.track.title)
                                    Text("Manually added • " + library.artistName(row.track.artistID)).font(.caption)
                                }
                                Spacer()
                                Button { Task { await library.playMigration(playlistID: playlistID, occurrenceID: row.occurrence.playbackID) } } label: {
                                    Image(systemName: "play.circle.fill").frame(width: 44, height: 44)
                                }.buttonStyle(.borderless).disabled(!row.available).accessibilityLabel("Play " + row.track.title)
                            }.listRowBackground(AppColors.backgroundPrimary)
                                .swipeActions { Button("Remove Added Song", role: .destructive) {
                                    library.perform { try library.removeManualOccurrence(row.id, playlistID: playlistID) }
                                } }
                        }
                    } else {
                    if songs.isEmpty { Text("This playlist is empty. Add songs from your Library.").foregroundStyle(AppColors.textSecondary) }
                    ForEach(songs) { track in
                        Group {
                            if editMode == .active {
                                HStack {
                                    Text(track.title).lineLimit(1); Spacer()
                                    Button { move(track.id, delta: -1) } label: { Image(systemName: "arrow.up").frame(width: 44, height: 44) }.buttonStyle(.borderless).accessibilityLabel("Move up \(track.title)").accessibilityIdentifier("move-up-" + track.id)
                                    Button { move(track.id, delta: 1) } label: { Image(systemName: "arrow.down").frame(width: 44, height: 44) }.buttonStyle(.borderless).accessibilityLabel("Move down \(track.title)").accessibilityIdentifier("move-down-" + track.id)
                                }
                            } else {
                                StoredTrackRow(track: track, contextTrackIDs: songs.map(\.id), contextKind: "playlist", contextSourceID: playlistID, playlistID: playlistID)
                                    .swipeActions { Button("Remove from Playlist", role: .destructive) { library.perform { try library.removeTrack(track.id, playlistID: playlistID) } } }
                            }
                        }.listRowBackground(AppColors.backgroundPrimary)
                    }.onMove { source, destination in
                        var order = songs.map(\.id); order.move(fromOffsets: source, toOffset: destination)
                        library.perform { try library.reorder(order, playlistID: playlistID) }
                    }
                    }
                }
            } else { Text("This playlist was removed.").foregroundStyle(AppColors.textSecondary) }
        }
        .environment(\.editMode, $editMode)
        .scrollContentBackground(.hidden).screenBackground().navigationTitle("Playlist").navigationBarTitleDisplayMode(.inline).toolbar(.visible, for: .navigationBar)
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                if !migrationManaged {
                    Button(editMode == .active ? "Done" : "Reorder") { editMode = editMode == .active ? .inactive : .active }.accessibilityIdentifier("playlist-reorder")
                }
                Menu {
                    Button("Edit Playlist") { showingEditor = true }
                    Button("Delete Playlist", role: .destructive) { confirmingDelete = true }
                } label: { Label("Playlist Actions", systemImage: "ellipsis.circle") }
                    .accessibilityIdentifier("playlist-actions")
            }
        }
        .sheet(isPresented: $showingEditor) { PlaylistEditorView(playlistID: playlistID) }
        .sheet(isPresented: $showingTracks) { AddTracksToPlaylistView(playlistID: playlistID) }
        .confirmationDialog("Delete Playlist?", isPresented: $confirmingDelete, titleVisibility: .visible) {
            Button("Delete Playlist", role: .destructive) { Task { do { try await library.deletePlaylist(id: playlistID, confirmed: true); dismiss() } catch { library.report(error) } } }.accessibilityIdentifier("confirm-delete-playlist")
            Button("Cancel", role: .cancel) { }
        } message: { Text("This removes the playlist and its organization. Your music files, liked songs and other playlists are preserved.") }
    }
    private func move(_ id: String, delta: Int) {
        var order = songs.map(\.id)
        guard let current = order.firstIndex(of: id), order.indices.contains(current + delta) else { return }
        order.swapAt(current, current + delta)
        library.perform { try library.reorder(order, playlistID: playlistID) }
    }
}

struct ArtistDetailView: View {
    @EnvironmentObject private var library: MusicLibraryService
    let groupID: String
    private var group: LibraryGroup? { library.artistGroups.first { $0.id == groupID } }
    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: AppSpacing.lg) {
                if let group {
                    ManagedArtworkView(path: group.artworkRelativePath, fallbackID: group.id, size: 180).frame(maxWidth: .infinity)
                    Text(group.title).font(.title.bold()).foregroundStyle(AppColors.textPrimary)
                    Text("\(group.count) songs").foregroundStyle(AppColors.textSecondary)
                    CollectionPlaybackButtons(tracks: library.tracks(group.trackIDs), kind: "artist", sourceID: groupID)
                    ForEach(library.albumGroups.filter { album in
                        !Set(album.trackIDs).isDisjoint(with: group.trackIDs) || library.snapshot.albums.contains { $0.id == album.id && $0.artistID == groupID }
                    }) { album in
                        NavigationLink { AlbumDetailView(groupID: album.id) } label: { LibraryGroupRow(group: album) }
                    }
                    ForEach(library.tracks(group.trackIDs)) { StoredTrackRow(track: $0, contextTrackIDs: group.trackIDs, contextKind: "artist", contextSourceID: groupID) }
                } else { EmptyState(icon: "person", title: "No songs for this artist", message: "Its songs may have been edited or removed.") }
            }.padding(AppSpacing.lg)
        }.navigationTitle("Artist").navigationBarTitleDisplayMode(.inline).toolbar(.visible, for: .navigationBar).screenBackground()
    }
}

struct CollectionPlaybackButtons: View {
    @EnvironmentObject private var library: MusicLibraryService
    let tracks: [StoredTrack]
    let kind: String
    var sourceID: String? = nil
    private var playable: [StoredTrack] { tracks.filter { $0.availability == .available } }
    var body: some View {
        HStack(spacing: AppSpacing.md) {
            Button { start(shuffle: false) } label: { Label("Play", systemImage: "play.fill").frame(maxWidth: .infinity, minHeight: 36) }
                .buttonStyle(.borderedProminent).tint(AppColors.accentPrimary).foregroundStyle(.black).accessibilityIdentifier("collection-play")
            Button { start(shuffle: true) } label: { Label("Shuffle", systemImage: "shuffle").frame(maxWidth: .infinity, minHeight: 36) }
                .buttonStyle(.bordered).tint(AppColors.accentPrimary).accessibilityIdentifier("collection-shuffle")
        }.disabled(playable.isEmpty)
    }
    private func start(shuffle: Bool) {
        guard let first = shuffle ? playable.randomElement() : playable.first else { return }
        Task { await library.play(first.id, ids: tracks.map(\.id), kind: kind, sourceID: sourceID, shuffle: shuffle) }
    }
}

struct AddTracksToPlaylistView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var library: MusicLibraryService
    var playlistID: String? = nil
    var albumID: String? = nil
    var onSelection: (([String]) -> Void)? = nil
    @State private var query = ""
    @State private var results: [StoredTrack] = []
    @State private var selected: Set<String> = []
    @State private var error: String?
    private var existing: Set<String> {
        if let playlistID { return library.isMigrationPlaylist(playlistID) ? [] : Set(library.playlistTracks(playlistID).map(\.id)) }
        if let albumID { return Set(library.albumGroups.first { $0.id == albumID }?.trackIDs ?? []) }
        return []
    }
    var body: some View {
        NavigationStack {
            List {
                TextField("Search title, artist or album", text: $query).accessibilityIdentifier("playlist-track-search")
                if let playlistID, library.isMigrationPlaylist(playlistID) {
                    Text("Add independent local occurrences after the imported entries. Adding a song again creates another occurrence; it does not resolve a Spotify placeholder.").font(.caption)
                }
                if albumID != nil || onSelection != nil { Text("Songs can have one primary album. Adding a song moves it from its previous album; playlists and audio files stay intact.").font(.caption).foregroundStyle(AppColors.textSecondary) }
                if let error { Text(error).foregroundStyle(AppColors.error) }
                ForEach(query.isEmpty ? library.snapshot.tracks : results) { track in
                    Button {
                        if selected.contains(track.id) { selected.remove(track.id) } else { selected.insert(track.id) }
                    } label: {
                        HStack {
                            StoredArtworkView(track: track, size: 44)
                            VStack(alignment: .leading) { Text(track.title).lineLimit(1); Text(library.artistName(track.artistID)).font(.caption).foregroundStyle(AppColors.textSecondary) }
                            Spacer(); Image(systemName: existing.contains(track.id) || selected.contains(track.id) ? "checkmark.circle.fill" : "circle").foregroundStyle(AppColors.accentPrimary)
                        }
                    }.disabled(existing.contains(track.id)).accessibilityIdentifier("select-track-" + track.id)
                }
            }.scrollContentBackground(.hidden).screenBackground().navigationTitle("Add Songs")
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                    ToolbarItem(placement: .confirmationAction) { Button("Add") {
                        do {
                            let ids = library.snapshot.tracks.map(\.id).filter { selected.contains($0) }
                            if let onSelection { onSelection(ids) }
                            else if let albumID { try library.addAlbumTracks(ids, albumID: albumID) }
                            else if let playlistID { try library.addTracks(ids, playlistID: playlistID) }
                            dismiss()
                        }
                        catch { self.error = MusicLibraryService.message(error) }
                    }.disabled(selected.isEmpty).accessibilityIdentifier(albumID != nil || onSelection != nil ? "album-confirm-add" : "playlist-confirm-add") }
                }
                .task(id: "\(query)|\(library.revision)") {
                    do { try await Task.sleep(for: .milliseconds(250)); let value = try await library.search(query); if !Task.isCancelled { results = value } }
                    catch is CancellationError { } catch { self.error = MusicLibraryService.message(error) }
                }
        }
    }
}

struct AddToPlaylistView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var library: MusicLibraryService
    let trackIDs: [String]
    @State private var creating = false
    @State private var error: String?
    var body: some View {
        NavigationStack {
            List {
                Button("Create Playlist") { creating = true }
                if let error { Text(error).foregroundStyle(AppColors.error) }
                ForEach(library.snapshot.playlists) { playlist in
                    Button { add(playlist.id) } label: { PlaylistLibraryRow(playlist: playlist) }
                }
                if library.snapshot.playlists.isEmpty { Text("Create a playlist to add these songs.").foregroundStyle(AppColors.textSecondary) }
            }.scrollContentBackground(.hidden).screenBackground().navigationTitle("Add to Playlist")
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
                .sheet(isPresented: $creating) { PlaylistEditorView(onSaved: { add($0) }) }
        }
    }
    private func add(_ id: String) { do { try library.addTracks(trackIDs, playlistID: id); dismiss() } catch { self.error = MusicLibraryService.message(error) } }
}

struct PlaylistEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var library: MusicLibraryService
    var playlistID: String? = nil
    var onSaved: (String) -> Void = { _ in }
    @State private var name = ""
    @State private var description = ""
    @State private var artworkData: Data?
    @State private var error: String?
    @State private var saving = false
    var body: some View {
        NavigationStack {
            Form {
                ArtworkDraftPicker(data: $artworkData, existingPath: playlistID.flatMap { id in library.snapshot.playlists.first { $0.id == id }?.artworkRelativePath }, fallbackID: playlistID ?? "new-playlist")
                TextField("Playlist name", text: $name).accessibilityIdentifier("playlist-name")
                TextField("Description", text: $description, axis: .vertical).lineLimit(3...6).accessibilityIdentifier("playlist-description")
                if let error { Text(error).foregroundStyle(AppColors.error).accessibilityIdentifier("editor-error") }
            }.scrollContentBackground(.hidden).screenBackground().navigationTitle(playlistID == nil ? "Create Playlist" : "Edit Playlist")
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() }.disabled(saving) }
                    ToolbarItem(placement: .confirmationAction) { Button(saving ? "Saving…" : "Save") { save() }.disabled(saving).accessibilityIdentifier("playlist-save") }
                }
        }.onAppear {
            if let playlistID, let record = library.snapshot.playlists.first(where: { $0.id == playlistID }) { name = record.name; description = record.description ?? "" }
        }
    }
    private func save() {
        saving = true
        Task {
            do { let id = try await library.savePlaylist(id: playlistID, name: name, description: description, artworkData: artworkData); saving = false; onSaved(id); dismiss() }
            catch { self.error = MusicLibraryService.message(error); saving = false }
        }
    }
}

struct TrackEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var library: MusicLibraryService
    let trackID: String
    @State private var title = ""
    @State private var artist = ""
    @State private var album = ""
    @State private var albumArtist = ""
    @State private var artworkData: Data?
    @State private var removeArtwork = false
    @State private var saving = false
    @State private var error: String?
    var body: some View {
        NavigationStack {
            Form {
                ArtworkDraftPicker(data: $artworkData, existingPath: removeArtwork ? nil : library.track(trackID)?.artworkRelativePath, fallbackID: trackID)
                if library.track(trackID)?.artworkRelativePath != nil { Toggle("Remove existing artwork", isOn: $removeArtwork) }
                TextField("Title", text: $title).accessibilityIdentifier("metadata-title")
                TextField("Artist", text: $artist).accessibilityIdentifier("metadata-artist")
                TextField("Album", text: $album).accessibilityIdentifier("metadata-album")
                TextField("Album Artist (optional)", text: $albumArtist).accessibilityIdentifier("metadata-album-artist")
                Text("Edits are stored in Muzik Belesh. The original audio file and embedded tags remain unchanged.").font(.caption).foregroundStyle(AppColors.textSecondary)
                if let error { Text(error).foregroundStyle(AppColors.error).accessibilityIdentifier("editor-error") }
            }.scrollContentBackground(.hidden).screenBackground().navigationTitle("Edit Metadata")
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() }.disabled(saving) }
                    ToolbarItem(placement: .confirmationAction) { Button(saving ? "Saving…" : "Save") { save() }.disabled(saving).accessibilityIdentifier("metadata-save") }
                }
        }.onAppear {
            if let track = library.track(trackID) {
                title = track.title; artist = track.artistID == nil ? "" : library.artistName(track.artistID)
                album = track.albumID == nil ? "" : library.albumTitle(track.albumID); albumArtist = track.albumArtist ?? ""
            }
        }
    }
    private func save() {
        saving = true
        Task {
            do { try await library.saveMetadata(trackID: trackID, draft: TrackMetadataDraft(title: title, artist: artist, album: album, albumArtist: albumArtist), artworkData: artworkData, removeArtwork: removeArtwork); saving = false; dismiss() }
            catch { self.error = MusicLibraryService.message(error); saving = false }
        }
    }
}

struct ArtworkDraftPicker: View {
    @Binding var data: Data?
    let existingPath: String?
    let fallbackID: String
    @State private var selection: PhotosPickerItem?
    @State private var error: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let data, let image = UIImage(data: data) { Image(uiImage: image).resizable().scaledToFit().frame(height: 150) }
            else { ManagedArtworkView(path: existingPath, fallbackID: fallbackID, size: 150) }
            PhotosPicker(selection: $selection, matching: .images) { Label("Change Artwork", systemImage: "photo") }.accessibilityIdentifier("change-artwork")
            if let error { Text(error).font(.caption).foregroundStyle(AppColors.error) }
        }.task(id: selection) {
            guard let selection else { return }
            do {
                guard let value = try await selection.loadTransferable(type: Data.self) else { throw LibraryError.invalidImage }
                let processed = try await Task.detached { try ManagedLibraryFiles.imageData(value, pixels: 1024) }.value
                guard !Task.isCancelled else { return }; data = processed; error = nil
            } catch is CancellationError { } catch { self.error = MusicLibraryService.message(error) }
        }
    }
}

func formatDuration(_ tracks: [StoredTrack]) -> String {
    let seconds = tracks.compactMap(\.durationMs).reduce(Int64(0), +) / 1000
    return "\(seconds / 60) min \(seconds % 60) sec"
}
