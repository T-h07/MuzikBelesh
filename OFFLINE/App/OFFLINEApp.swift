import SwiftUI
@main struct OFFLINEApp: App {
    @UIApplicationDelegateAdaptor(BackgroundDownloadAppDelegate.self) private var delegate
    private let container = AppBootstrap.container()
    @StateObject private var coordinator = AppCoordinator()
    var body: some Scene { WindowGroup { RootView(coordinator: coordinator).environmentObject(container).environmentObject(container.audioPlayer).environmentObject(container.library) } }
}

