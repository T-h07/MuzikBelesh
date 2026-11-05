import SwiftUI

enum SearchMode: String, CaseIterable { case youtube = "YouTube", library = "Your Library" }

struct SearchView: View {
    @EnvironmentObject private var container: AppContainer
    @EnvironmentObject private var library: MusicLibraryService
    @StateObject private var search = LibrarySearchSession()
    @ObservedObject var coordinator: AppCoordinator
    @FocusState.Binding var searchFocus: LibrarySearchField?
    @State private var mode: SearchMode = .library
    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: AppSpacing.lg) {
                Text("Search").font(.system(size: 28, weight: .bold)).foregroundStyle(AppColors.textPrimary)
                SearchBar(text: $coordinator.searchQuery, placeholder: mode == .library ? "Songs, albums, artists or playlists" : "Songs, artists or keywords", focus: $searchFocus, field: .search)
                Picker("Search mode", selection: $mode) { ForEach(SearchMode.allCases, id: \.self) { Text($0.rawValue).tag($0) } }.pickerStyle(.segmented).tint(AppColors.accentPrimary)
            }.padding(.horizontal, AppSpacing.xl).padding(.vertical, AppSpacing.lg)
            ScrollView { resultsContent.padding(.horizontal, AppSpacing.xl).padding(.bottom, AppSpacing.lg) }
                .scrollBounceBehavior(.always).accessibilityIdentifier("local-search-results")
                .simultaneousGesture(DragGesture().onChanged { _ in searchFocus = nil })
        }.navigationBarHidden(true).screenBackground()
        .onDisappear { searchFocus = nil }
        .onChange(of: mode) { _, _ in searchFocus = nil }
        .task(id: LibrarySearchRequest(query: coordinator.searchQuery, revision: library.revision)) {
            await search.update(query: coordinator.searchQuery, snapshot: library.snapshot)
        }
    }
    @ViewBuilder private var resultsContent: some View { if mode == .youtube { youtubeResults } else { libraryResults } }
    private var youtubeResults: some View {
        YouTubeSearchResultsView(provider: container.youtubeSearch, query: coordinator.searchQuery,
                                onOpen: { searchFocus = nil }, onPaste: { searchFocus = nil; coordinator.sheet = .importLink })
    }
    @ViewBuilder private var libraryResults: some View {
        VStack(alignment: .leading, spacing: AppSpacing.md) {
            LibrarySortMenu()
            if let results = search.results {
                LibrarySearchResultsView(results: results, onInteraction: { searchFocus = nil })
            } else { ProgressView("Searching Library").frame(maxWidth: .infinity) }
        }.padding(.top, AppSpacing.md)
    }
}
