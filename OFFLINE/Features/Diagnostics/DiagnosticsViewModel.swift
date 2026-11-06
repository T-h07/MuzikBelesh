import Foundation
@MainActor final class DiagnosticsViewModel: ObservableObject {
    enum State: Equatable { case idle, loading, success(YouTubeProbeResult), failure(String) }
    @Published var input = "https://www.youtube.com/watch?v=9bZkp7q19f0"
    @Published private(set) var state: State = .idle
    let container: AppContainer
    init(container: AppContainer) { self.container = container }
    var youtubeStatus: String { "Integrated (manual probe)" }
    var shareStatus: String {
        do {
            _ = try SharedLinkInbox.installed().first()
            return "App Group inbox readable"
        } catch SharedLinkInbox.Failure.unavailable { return "App Group unavailable" }
        catch { return "App Group inbox read failed" }
    }
    func runProbe() async {
        state = .loading
        do { state = .success(try await container.youtubeProbe.resolve(input: input)) }
        catch is CancellationError { state = .idle }
        catch { state = .failure(Self.sanitized(error)) }
    }
    private static func sanitized(_ error: Error) -> String { String(describing: error).replacingOccurrences(of: #"https?://\S+"#, with: "[redacted URL]", options: .regularExpression) }
}

