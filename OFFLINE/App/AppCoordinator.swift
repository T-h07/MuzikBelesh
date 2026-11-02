import SwiftUI

enum RootTab: Hashable { case home, search, library, downloads }
enum AppSheet: Identifiable { case settings, importLink, sleepTimer; var id: String { String(describing: self) } }

final class AppCoordinator: ObservableObject {
    @Published var selectedTab: RootTab = .home
    @Published var sheet: AppSheet?
    @Published var showingNowPlaying = false
    @Published var searchQuery = ""
    @Published var libraryFilter = "All"
}

