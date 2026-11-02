import SwiftUI
@main struct OFFLINEApp: App {
    private let container = AppContainer()
    @StateObject private var coordinator = AppCoordinator()
    var body: some Scene { WindowGroup { RootView(coordinator: coordinator).environmentObject(container) } }
}

