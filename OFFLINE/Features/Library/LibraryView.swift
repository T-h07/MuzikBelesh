import SwiftUI
import UniformTypeIdentifiers

struct LibraryView: View {
    @EnvironmentObject private var container: AppContainer
    @EnvironmentObject private var library: MusicLibraryService
    @ObservedObject var coordinator: AppCoordinator
    @State private var showingImporter = false
    @State private var showingPlaylistEditor = false
    @State private var importMessage: String?
    @State private var query = ""
    @State private var results: [StoredTrack] = []
    private let filters = ["All", "Songs", "Playlists", "Albums", "Artists", "Liked Songs"]
    private var visible: [StoredTrack] {
        let values = query.isEmpty ? library.snapshot.tracks : results
        return coordinator.libraryFilter == "Liked Songs" ? values.filter { library.snapshot.likedIDs.contains($0.id) } : values
    }
    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: AppSpacing.lg) {
                header
                if let importMessage { Text(importMessage).font(.callout).foregroundStyle(AppColors.textSecondary).accessibilityIdentifier("import-result") }
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: AppSpacing.sm) {
                        ForEach(filters, id: \.self) { filter in
                            FilterChip(title: filter, selected: coordinator.libraryFilter == filter) { coordinator.libraryFilter = filter }
                                .accessibilityIdentifier("library-filter-" + filter.replacingOccurrences(of: " ", with: "-"))
                        }
                    }
                }
                content
            }.padding(.horizontal, AppSpacing.lg).padding(.top, AppSpacing.md).padding(.bottom, 30)
        }
        .navigationBarHidden(true).screenBackground()
        .sheet(isPresented: $showingPlaylistEditor) { PlaylistEditorView() }
        .fileImporter(isPresented: $showingImporter, allowedContentTypes: [.audio, .supportedAudio], allowsMultipleSelection: true) { result in
            Task { @MainActor in
                do {
                    guard let storage = container.storage else { throw LibraryError.operationFailed }
                    let urls = try result.get(); var added = 0; var duplicates = 0; var failed = 0
                    for url in urls {
                        do { let item = try await storage.importAudio(from: url); if item.duplicate { duplicates += 1 } else { added += 1 } }
                        catch { failed += 1; library.report(error) }
                    }
                    importMessage = "Imported \(added) • Already in Library \(duplicates)" + (failed == 0 ? "" : " • Failed \(failed)")
                } catch { library.report(error) }
            }
        }
        .task(id: "\(query)|\(library.revision)") {
            do {
                try await Task.sleep(for: .milliseconds(250))
                let values = try await library.search(query)
                guard !Task.isCancelled else { return }; results = values
            } catch is CancellationError { } catch { if !Task.isCancelled { library.report(error) } }
        }
    }
    private var header: some View {
        HStack {
            Text("Library").font(.largeTitle.bold()).foregroundStyle(AppColors.textPrimary)
            Spacer()
            Button { showingImporter = true } label: { Label("Import", systemImage: "square.and.arrow.down").lineLimit(1) }
                .buttonStyle(.borderedProminent).tint(AppColors.accentPrimary).foregroundStyle(.black).frame(minHeight: 44).accessibilityIdentifier("library-import")
        }
    }
    @ViewBuilder private var content: some View {
        switch coordinator.libraryFilter {
        case "Playlists":
            Button { showingPlaylistEditor = true } label: { Label("Create Playlist", systemImage: "plus.circle.fill") }
                .buttonStyle(.borderedProminent).tint(AppColors.accentPrimary).foregroundStyle(.black).accessibilityIdentifier("create-playlist")
            if library.snapshot.playlists.isEmpty {
                EmptyState(icon: "rectangle.stack", title: "No playlists", message: "Create a playlist and add your local songs.")
            }
            ForEach(library.snapshot.playlists) { playlist in
                NavigationLink { PlaylistDetailView(playlistID: playlist.id) } label: { PlaylistLibraryRow(playlist: playlist) }
                    .accessibilityIdentifier("playlist-" + playlist.id)
            }
        case "Albums":
            if library.albumGroups.isEmpty { EmptyState(icon: "square.stack", title: "No albums", message: "Import music, then edit its album metadata.") }
            ForEach(library.albumGroups) { group in
                NavigationLink { AlbumDetailView(groupID: group.id) } label: { LibraryGroupRow(group: group) }
            }
        case "Artists":
            if library.artistGroups.isEmpty { EmptyState(icon: "person", title: "No artists", message: "Import music, then edit its artist metadata.") }
            ForEach(library.artistGroups) { group in
                NavigationLink { ArtistDetailView(groupID: group.id) } label: { LibraryGroupRow(group: group) }
            }
        default:
            SearchBar(text: $query, placeholder: "Search title, artist or album")
            HStack {
                Text(coordinator.libraryFilter == "Liked Songs" ? "Liked Songs" : "Imported Music").font(.title3.weight(.semibold)).foregroundStyle(AppColors.textPrimary)
                Spacer(); LibrarySortMenu()
            }
            if visible.isEmpty {
                EmptyState(icon: coordinator.libraryFilter == "Liked Songs" ? "heart" : "music.note", title: query.isEmpty ? (coordinator.libraryFilter == "Liked Songs" ? "No liked songs" : "Your library is empty") : "No library matches", message: "Import local music or try another search.", actionTitle: "Import Audio") { showingImporter = true }
            }
            ForEach(visible) { track in
                StoredTrackRow(track: track, contextTrackIDs: visible.map(\.id), contextKind: coordinator.libraryFilter == "Liked Songs" ? "liked" : (query.isEmpty ? "library" : "search"))
            }
        }
    }
}

struct LibrarySortMenu: View {
    @EnvironmentObject private var library: MusicLibraryService
    var body: some View {
        Menu {
            ForEach(LibrarySort.allCases) { sort in
                Button { library.perform { try library.setSort(sort) } } label: {
                    if library.snapshot.sort == sort { Label(sort.title, systemImage: "checkmark") } else { Text(sort.title) }
                }
            }
        } label: { Label("Sort", systemImage: "arrow.up.arrow.down").frame(minHeight: 44) }
            .foregroundStyle(AppColors.accentPrimary).accessibilityIdentifier("library-sort")
    }
}

struct PlaylistLibraryRow: View {
    @EnvironmentObject private var library: MusicLibraryService
    let playlist: StoredPlaylist
    var body: some View {
        HStack(spacing: AppSpacing.md) {
            ManagedArtworkView(path: playlist.artworkRelativePath, fallbackID: playlist.id, size: 60)
            VStack(alignment: .leading, spacing: 4) {
                Text(playlist.name).font(.headline).foregroundStyle(AppColors.textPrimary).lineLimit(1)
                Text("\(library.playlistTracks(playlist.id).count) songs").font(.caption).foregroundStyle(AppColors.textSecondary)
                if let description = playlist.description, !description.isEmpty { Text(description).font(.caption).foregroundStyle(AppColors.textSecondary).lineLimit(1) }
            }
            Spacer(); Image(systemName: "chevron.right").foregroundStyle(AppColors.textTertiary)
        }.padding(.vertical, 6)
    }
}

struct LibraryGroupRow: View {
    let group: LibraryGroup
    var body: some View {
        HStack(spacing: AppSpacing.md) {
            ManagedArtworkView(path: group.artworkRelativePath, fallbackID: group.id, size: 60)
            VStack(alignment: .leading, spacing: 4) {
                Text(group.title).font(.headline).foregroundStyle(AppColors.textPrimary).lineLimit(1)
                Text("\(group.subtitle) • \(group.count) songs").font(.caption).foregroundStyle(AppColors.textSecondary).lineLimit(1)
            }; Spacer(); Image(systemName: "chevron.right").foregroundStyle(AppColors.textTertiary)
        }.padding(.vertical, 6)
    }
}

struct StoredTrackRow: View {
    @EnvironmentObject private var library: MusicLibraryService
    @EnvironmentObject private var container: AppContainer
    let track: StoredTrack
    var contextTrackIDs: [String]? = nil
    var contextKind: String = "library"
    var contextSourceID: String? = nil
    var playlistID: String? = nil
    @State private var showingEditor = false
    @State private var showingPlaylists = false
    @State private var confirmingDeletion = false
    @State private var showingExporter = false
    @State private var exportDocument: AudioExportDocument?
    @State private var rowError: String?
    private var ids: [String] { contextTrackIDs ?? library.snapshot.tracks.map(\.id) }
    var body: some View {
        HStack(spacing: AppSpacing.md) {
            Button { play() } label: { rowLabel }.buttonStyle(.plain).disabled(track.availability != .available)
            if library.snapshot.likedIDs.contains(track.id) { Image(systemName: "heart.fill").foregroundStyle(AppColors.accentPrimary).font(.caption).accessibilityLabel("Liked") }
            Menu { actions } label: { Image(systemName: "ellipsis").foregroundStyle(AppColors.textSecondary).frame(width: 44, height: 44) }
                .accessibilityLabel("Actions for \(track.title)").accessibilityIdentifier("track-actions-" + track.id)
        }
        .padding(.vertical, AppSpacing.xs).contextMenu { actions }
        .accessibilityIdentifier("stored-track-row-" + track.id)
        .sheet(isPresented: $showingEditor) { TrackEditorView(trackID: track.id) }
        .sheet(isPresented: $showingPlaylists) { AddToPlaylistView(trackIDs: [track.id]) }
        .confirmationDialog("Delete Song from Library?", isPresented: $confirmingDeletion, titleVisibility: .visible) {
            Button("Delete Song", role: .destructive) {
                Task { do { _ = try await library.deleteTrack(id: track.id, confirmed: true) } catch { rowError = MusicLibraryService.message(error) } }
            }.accessibilityIdentifier("confirm-delete-track")
            Button("Cancel", role: .cancel) { }
        } message: { Text("This removes the local audio file from Muzik Belesh and its playlist, liked-song and queue references. Other songs are preserved.") }
        .fileExporter(isPresented: $showingExporter, document: exportDocument, contentType: .audio, defaultFilename: track.originalFilename ?? "\(track.title).\(track.fileExtension)") { result in
            if case .failure(let error) = result { rowError = MusicLibraryService.message(error) }
        }
    }
    private var rowLabel: some View {
        HStack(spacing: AppSpacing.md) {
            StoredArtworkView(track: track, size: 54)
            VStack(alignment: .leading, spacing: 4) {
                Text(track.title).font(.subheadline.weight(.semibold)).foregroundStyle(AppColors.textPrimary).lineLimit(1)
                Text(library.artistName(track.artistID)).font(.caption).foregroundStyle(AppColors.textSecondary).lineLimit(1)
                if track.availability != .available { Text(track.availability == .missing ? "File missing" : "File changed").font(.caption2).foregroundStyle(AppColors.warning) }
                if let rowError { Text(rowError).font(.caption2).foregroundStyle(AppColors.error).lineLimit(2) }
            }.frame(maxWidth: .infinity, alignment: .leading)
            if let ms = track.durationMs { Text(String(format: "%d:%02d", ms / 60000, (ms / 1000) % 60)).font(.caption2).foregroundStyle(AppColors.textTertiary) }
        }.frame(maxWidth: .infinity, minHeight: 54, alignment: .leading).contentShape(Rectangle())
    }
    @ViewBuilder private var actions: some View {
        Button { play() } label: { Label("Play Now", systemImage: "play.fill") }.disabled(track.availability != .available)
        Button { container.audioPlayer.queue.playNext(trackID: track.id) } label: { Label("Play Next", systemImage: "text.insert") }.disabled(track.availability != .available)
        Button { container.audioPlayer.queue.addToQueue(trackID: track.id) } label: { Label("Add to Queue", systemImage: "text.badge.plus") }.disabled(track.availability != .available)
        Button { showingPlaylists = true } label: { Label("Add to Playlist", systemImage: "rectangle.stack.badge.plus") }
        Button { library.perform { try library.setLiked(!library.snapshot.likedIDs.contains(track.id), trackID: track.id) } } label: { Label(library.snapshot.likedIDs.contains(track.id) ? "Unlike Song" : "Like Song", systemImage: "heart") }
        Button { showingEditor = true } label: { Label("Edit Metadata", systemImage: "pencil") }
        Button { export() } label: { Label("Export Audio", systemImage: "square.and.arrow.up") }.disabled(track.availability != .available)
        if let playlistID { Button { library.perform { try library.removeTrack(track.id, playlistID: playlistID) } } label: { Label("Remove from Playlist", systemImage: "minus.circle") } }
        Button(role: .destructive) { confirmingDeletion = true } label: { Label(track.availability == .available ? "Delete Song" : "Remove Missing Entry", systemImage: "trash") }
    }
    private func play() { Task { await library.play(track.id, ids: ids, kind: contextKind, sourceID: contextSourceID) } }
    private func export() {
        Task {
            do {
                guard let storage = container.storage else { throw LibraryError.operationFailed }
                let url = try storage.paths.musicURL(relativePath: track.fileRelativePath)
                let data = try await Task.detached { try Data(contentsOf: url) }.value
                exportDocument = AudioExportDocument(data: data); showingExporter = true
            } catch { rowError = MusicLibraryService.message(error) }
        }
    }
}
