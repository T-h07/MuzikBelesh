import SwiftUI

enum RootTab: Hashable { case home, search, library, downloads }
enum AppSheet: Identifiable {
    case settings, importLink, sleepTimer
    case sharedLink(PendingShare)
    var id: String {
        switch self {
        case .settings: return "settings"
        case .importLink: return "importLink"
        case .sleepTimer: return "sleepTimer"
        case .sharedLink(let share): return share.id.uuidString
        }
    }
}

final class AppCoordinator: ObservableObject {
    let shareHandoff = ShareHandoff()
    @Published var selectedTab: RootTab = .home
    @Published var sheet: AppSheet?
    @Published var showingNowPlaying = false
    @Published var searchQuery = ""
    @Published var libraryFilter = "All"
}

