import SwiftUI

enum RootTab: Hashable { case home, search, library, downloads }
enum AppSheet: Identifiable {
    case settings, importLink, sleepTimer
    /// Phase 11.1 local profile page, opened from the Home header avatar.
    case profile
    case sharedLink(PendingShare)
    /// Opened from a playlist-ready notification.
    case playlist(String)
    /// Opened from a migration attention notification (Phase 10.7).
    case migrationIssues(String)
    var id: String {
        switch self {
        case .settings: return "settings"
        case .importLink: return "importLink"
        case .sleepTimer: return "sleepTimer"
        case .profile: return "profile"
        case .sharedLink(let share): return share.id.uuidString
        case .playlist(let id): return "playlist-" + id
        case .migrationIssues(let id): return "migration-issues-" + id
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

