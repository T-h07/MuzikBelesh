import SwiftUI
struct DiagnosticsView: View {
    @StateObject var viewModel: DiagnosticsViewModel
    var body: some View { ScrollView { VStack(alignment: .leading, spacing: 18) {
        Text("Muzik Belesh").font(.system(size: 38, weight: .bold)).foregroundStyle(.white)
        Text("Phase 0 — Foundation & Feasibility").foregroundStyle(Color.lime)
        Divider().overlay(.gray)
        status("Launch", "Successful"); status("Version", "\(viewModel.container.configuration.version) (\(viewModel.container.configuration.build))")
        status("iOS", ProcessInfo.processInfo.operatingSystemVersionString); status("Bundle", viewModel.container.configuration.bundleIdentifier)
        status("Configuration", viewModel.container.configuration.buildConfiguration); status("YouTubeKit", viewModel.youtubeStatus); status("Share extension", viewModel.shareStatus)
        Text("Optional YouTubeKit probe").font(.headline).foregroundStyle(.white)
        TextField("YouTube URL or video ID", text: $viewModel.input).textFieldStyle(.roundedBorder)
        Button("Resolve metadata and audio stream") { Task { await viewModel.runProbe() } }.buttonStyle(.borderedProminent).tint(Color.lime)
        result
    }.padding(24) }.background(Color.black.ignoresSafeArea()) }
    private func status(_ title: String, _ value: String) -> some View { HStack { Text(title).foregroundStyle(.gray); Spacer(); Text(value).foregroundStyle(.white).multilineTextAlignment(.trailing) } }
    @ViewBuilder private var result: some View { switch viewModel.state {
        case .idle: EmptyView(); case .loading: ProgressView("Resolving…").tint(.white).foregroundStyle(.white)
        case .failure(let message): Text("Probe failed: \(message)").foregroundStyle(.orange)
        case .success(let result): Text("Result\n\(result.summary)").foregroundStyle(.white)
    } }
}
private extension Color { static let lime = Color(red: 0.68, green: 0.95, blue: 0.18) }

