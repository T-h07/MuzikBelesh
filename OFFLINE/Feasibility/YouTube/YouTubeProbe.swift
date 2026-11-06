import Foundation

protocol YouTubeProbe { func resolve(input: String) async throws -> YouTubeProbeResult }
enum YouTubeProbeError: LocalizedError, Equatable {
    case invalidInput, noCompatibleStream
    var errorDescription: String? { switch self { case .invalidInput: "Enter a YouTube URL or 11-character video ID."; case .noCompatibleStream: "No compatible audio-only stream was returned." } }
}
struct YouTubeKitProbe: YouTubeProbe {
    let resolver: any YouTubeAudioResolver
    init(resolver: any YouTubeAudioResolver) { self.resolver = resolver }
    init() {
        let transport = YouTubeURLSessionTransport()
        resolver = YouTubeKitAudioResolver(metadata: YouTubeWebProvider(transport: transport), transport: transport)
    }
    func resolve(input: String) async throws -> YouTubeProbeResult {
        guard let id = YouTubeURLValidator.videoID(from: input) else { throw YouTubeProbeError.invalidInput }
        let result = try await resolver.resolve(video: YouTubeVideo(id: id, title: "YouTube Video"), quality: .high)
        return YouTubeProbeResult(videoID: id, title: result.video.title, audioStreamCount: result.options.count,
                                  selectedFormat: result.selected.container, selectedBitrate: result.selected.bitrate,
                                  hasUsableStreamURL: result.isFresh(at: Date()))
    }
}
