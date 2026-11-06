import SwiftUI
import UniformTypeIdentifiers

struct LibraryView: View {
    @EnvironmentObject private var container: AppContainer
    @EnvironmentObject private var library: MusicLibraryService
    @ObservedObject var coordinator: AppCoordinator
    @FocusState.Binding var searchFocus: LibrarySearchField?
    @State private var showingImporter = false
    @State private var showingPlaylistEditor = false
    @State private var showingAlbumEditor = false
    @State private var importMessage: String?
    @State private var query = ""
    @StateObject private var search = LibrarySearchSession()
    private let filters = ["All", "Songs", "Playlists", "Albums", "Artists", "Liked Songs"]
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
                }.accessibilityIdentifier("library-filters")
                SearchBar(text: $query, placeholder: "Songs, albums, artists or playlists", focus: $searchFocus, field: .library)
                content
            }.padding(.horizontal, AppSpacing.lg).padding(.top, AppSpacing.md).padding(.bottom, 30)
        }
        .navigationBarHidden(true).screenBackground()
        .scrollBounceBehavior(.always)
        .simultaneousGesture(DragGesture().onChanged { _ in searchFocus = nil })
        .onDisappear { searchFocus = nil }
        .onChange(of: coordinator.libraryFilter) { _, _ in searchFocus = nil }
        .sheet(isPresented: $showingPlaylistEditor) { PlaylistEditorView() }
        .sheet(isPresented: $showingAlbumEditor) { AlbumEditorView() }
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
        .task(id: LibrarySearchRequest(query: query, revision: library.revision)) {
            await search.update(query: query, snapshot: library.snapshot)
        }
    }
    private var header: some View {
        HStack {
            Text("Library").font(.largeTitle.bold()).foregroundStyle(AppColors.textPrimary)
            Spacer()
            Button { searchFocus = nil; showingImporter = true } label: { Label("Import", systemImage: "square.and.arrow.down").lineLimit(1) }
                .buttonStyle(.borderedProminent).tint(AppColors.accentPrimary).foregroundStyle(.black).frame(minHeight: 44).accessibilityIdentifier("library-import")
        }
    }
    @ViewBuilder private var content: some View {
        if coordinator.libraryFilter == "Albums" {
            Button { searchFocus = nil; showingAlbumEditor = true } label: { Label("Create Album", systemImage: "plus.circle.fill") }
                .buttonStyle(.borderedProminent).tint(AppColors.accentPrimary).foregroundStyle(.black).accessibilityIdentifier("create-album")
        }
        if coordinator.libraryFilter == "Playlists" {
            Button { searchFocus = nil; showingPlaylistEditor = true } label: { Label("Create Playlist", systemImage: "plus.circle.fill") }
                .buttonStyle(.borderedProminent).tint(AppColors.accentPrimary).foregroundStyle(.black).accessibilityIdentifier("create-playlist")
        }
        if ["All", "Songs", "Liked Songs"].contains(coordinator.libraryFilter) { HStack { Spacer(); LibrarySortMenu() } }
        if let results = search.results {
            LibrarySearchResultsView(results: results, scope: LibrarySearchScope(rawValue: coordinator.libraryFilter) ?? .all, contextKind: query.isEmpty ? "library" : "search", onInteraction: { searchFocus = nil })
        } else { ProgressView("Searching Library").frame(maxWidth: .infinity) }
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
    var albumID: String? = nil
    var onInteraction: () -> Void = { }
    @State private var showingEditor = false
    @State private var showingPlaylists = false
    @State private var confirmingDeletion = false
    @State private var exporting = false
    @State private var exportDocument: PreparedAudioExport?
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
        .sheet(isPresented: $showingEditor) { TrackEditorView(trackID: track.id) }
        .sheet(isPresented: $showingPlaylists) { AddToPlaylistView(trackIDs: [track.id]) }
        .onChange(of: showingEditor) { _, shown in if shown { onInteraction() } }
        .onChange(of: showingPlaylists) { _, shown in if shown { onInteraction() } }
        .onChange(of: confirmingDeletion) { _, shown in if shown { onInteraction() } }
        .confirmationDialog("Delete Song from Library?", isPresented: $confirmingDeletion, titleVisibility: .visible) {
            Button("Delete Song", role: .destructive) {
                Task { do { _ = try await library.deleteTrack(id: track.id, confirmed: true) } catch { rowError = MusicLibraryService.message(error) } }
            }.accessibilityIdentifier("confirm-delete-track")
            Button("Cancel", role: .cancel) { }
        } message: { Text("This removes the local audio file from Muzik Belesh and its playlist, liked-song and queue references. Other songs are preserved.") }
        .sheet(item: $exportDocument) { AudioExportPicker(export: $0) }
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
        if let albumID { Button { library.perform { try library.removeAlbumTrack(track.id, albumID: albumID) } } label: { Label("Remove from Album", systemImage: "minus.circle") } }
        Button(role: .destructive) { confirmingDeletion = true } label: { Label(track.availability == .missing ? "Remove Missing Entry" : "Delete Song", systemImage: "trash") }
    }
    private func play() { onInteraction(); Task { await library.play(track.id, ids: ids, kind: contextKind, sourceID: contextSourceID) } }
    private func export() {
        guard !exporting, exportDocument == nil else { return }
        onInteraction()
        exporting = true
        Task {
            defer { exporting = false }
            do {
                guard let storage = container.storage else { throw LibraryError.operationFailed }
                exportDocument = try await storage.prepareExport(trackID: track.id)
            } catch { rowError = MusicLibraryService.message(error) }
        }
    }
}
