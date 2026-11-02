import SwiftUI
@main struct OFFLINEApp: App {
    private let container = AppContainer()
    var body: some Scene { WindowGroup { DiagnosticsView(viewModel: DiagnosticsViewModel(container: container)) } }
}

