#if DEBUG
import Foundation
import AVFoundation

// Constructed only by AppBootstrap's explicitly isolated UI-test launch.
struct YouTubeUITestFixtures: YouTubeSearchProvider, YouTubeMetadataProvider, YouTubeAudioResolver {
    static let video = YouTubeVideo(id: "9bZkp7q19f0", title: "YouTube Fixture Song", channel: "Fixture Channel", duration: 253, availability: .available)
    func search(query: String, continuationToken: String?) async throws -> YouTubeSearchPage {
        try Task.checkCancellation()
        if query == "long page", continuationToken == nil {
            let videos = (1...16).map { index in
                YouTubeVideo(id: String(format: "fixture%04d", index), title: "Fixture result \(index)", channel: "Fixture Channel", duration: 210, availability: .available)
            }
            return YouTubeSearchPage(videos: videos, continuationToken: "fixture-next")
        }
        let video = continuationToken == nil ? Self.video : YouTubeVideo(id: "dQw4w9WgXcQ", title: "Second Fixture Song", channel: "Fixture Channel", duration: 210, availability: .available)
        return YouTubeSearchPage(videos: [video], continuationToken: continuationToken == nil ? "fixture-next" : nil)
    }
    func metadata(videoID: String) async throws -> YouTubeVideo {
        guard YouTubeURLValidator.isValidID(videoID) else { throw YouTubeError.invalidVideoID }
        return YouTubeVideo(id: videoID, title: "Resolved Fixture Song", channel: "Fixture Channel", duration: 253, availability: .available)
    }
    func resolve(video: YouTubeVideo, quality: AudioQuality) async throws -> ResolvedAudioStream {
        try Task.checkCancellation()
        let option = AudioStreamOption(id: 140, container: "m4a", codec: "mp4a.40.2", bitrate: 128_000, isAudioOnly: true, isNativelyPlayable: true)
        guard let url = URL(string: "https://fixture.invalid/never-transferred") else { throw YouTubeError.extractionFailed }
        return ResolvedAudioStream(video: video, options: [option], selected: option, url: url, resolvedAt: Date(), expiresAt: Date().addingTimeInterval(600))
    }
}

actor FixtureAudioTransfer: AudioTransferring {
    private var failOnce: Bool
    init(failOnce: Bool = false) { self.failOnce = failOnce }
    func download(_ url: URL, to destination: URL, wifiOnly: Bool,
                  progress: @escaping @Sendable (Int64, Int64) -> Void) async throws {
        if failOnce {
            failOnce = false
            throw DownloadFailure.invalid
        }
        let temp = destination.deletingLastPathComponent().appendingPathComponent(UUID().uuidString + ".m4a")
        defer { try? FileManager.default.removeItem(at: temp) }
        do {
            let settings: [String: Any] = [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 44100,
                                           AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: 64000]
            let file = try AVAudioFile(forWriting: temp, settings: settings)
            guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 44100),
                  let samples = buffer.floatChannelData?[0] else { throw DownloadFailure.invalid }
            buffer.frameLength = 44100
            for n in 0..<44100 { samples[n] = Float(sin(Double(n) * 0.04) * 0.1) }
            for _ in 0..<15 { try file.write(from: buffer) }
        }
        let total = try temp.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        let partial = temp.appendingPathExtension("part")
        defer { try? FileManager.default.removeItem(at: partial) }
        FileManager.default.createFile(atPath: partial.path, contents: nil)
        let input = try FileHandle(forReadingFrom: temp)
        let output = try FileHandle(forWritingTo: partial)
        defer { try? input.close(); try? output.close() }
        var received: Int64 = 0
        while let chunk = try input.read(upToCount: 16384), !chunk.isEmpty {
            try Task.checkCancellation()
            try output.write(contentsOf: chunk)
            received += Int64(chunk.count)
            progress(received, Int64(total))
            try await Task.sleep(for: .milliseconds(150))
        }
        try FileManager.default.moveItem(at: partial, to: destination)
    }
}
#endif
