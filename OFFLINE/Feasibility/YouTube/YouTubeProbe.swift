import Foundation
import YouTubeKit

protocol YouTubeProbe { func resolve(input: String) async throws -> YouTubeProbeResult }
enum YouTubeProbeError: LocalizedError, Equatable {
    case invalidInput, noCompatibleStream
    var errorDescription: String? { switch self { case .invalidInput: "Enter a YouTube URL or 11-character video ID."; case .noCompatibleStream: "No compatible audio-only stream was returned." } }
}
struct YouTubeURLValidator {
    static func videoID(from input: String) -> String? {
        let value = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.range(of: #"^[A-Za-z0-9_-]{11}$"#, options: .regularExpression) != nil { return value }
        guard let components = URLComponents(string: value), components.scheme?.lowercased() == "https", let host = components.host?.lowercased() else { return nil }
        if host == "youtu.be" { return components.path.split(separator: "/").first.map(String.init).flatMap(validID) }
        guard host == "youtube.com" || host.hasSuffix(".youtube.com") else { return nil }
        if let id = components.queryItems?.first(where: { $0.name == "v" })?.value { return validID(id) }
        let parts = components.path.split(separator: "/")
        if let index = parts.firstIndex(where: { $0 == "shorts" || $0 == "embed" }), parts.indices.contains(index + 1) { return validID(String(parts[index + 1])) }
        return nil
    }
    private static func validID(_ value: String) -> String? { value.range(of: #"^[A-Za-z0-9_-]{11}$"#, options: .regularExpression) == nil ? nil : value }
}
struct YouTubeKitProbe: YouTubeProbe {
    func resolve(input: String) async throws -> YouTubeProbeResult {
        guard let videoID = YouTubeURLValidator.videoID(from: input) else { throw YouTubeProbeError.invalidInput }
        let video = YouTube(videoID: videoID, methods: [.local])
        async let metadata = video.metadata
        let streams = try await video.streams
        let audio = streams.filterAudioOnly()
        let selected = audio.filter { $0.fileExtension == .m4a && $0.isNativelyPlayable }.highestAudioBitrateStream() ?? audio.filter { $0.fileExtension == .m4a }.highestAudioBitrateStream()
        guard let chosen = selected else { throw YouTubeProbeError.noCompatibleStream }
        let title = try? await metadata?.title
        return YouTubeProbeResult(videoID: videoID, title: title ?? nil, audioStreamCount: audio.count, selectedFormat: String(describing: chosen.fileExtension), selectedBitrate: chosen.bitrate, hasUsableStreamURL: !chosen.url.absoluteString.isEmpty)
    }
}

