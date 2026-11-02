import Foundation
@MainActor final class YouTubeProbeViewModel: ObservableObject {
    @Published private(set) var result: YouTubeProbeResult?
    @Published private(set) var isLoading = false
    @Published private(set) var error: String?
    private let probe: YouTubeProbe
    init(probe: YouTubeProbe) { self.probe = probe }
    func run(input: String) async { isLoading = true; error = nil; defer { isLoading = false }; do { result = try await probe.resolve(input: input) } catch { error = error.localizedDescription } }
}

