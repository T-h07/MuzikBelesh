import Foundation
struct YouTubeProbeResult: Equatable {
    let videoID: String
    let title: String?
    let audioStreamCount: Int
    let selectedFormat: String?
    let selectedBitrate: Int?
    let hasUsableStreamURL: Bool
    var summary: String { "ID: \(videoID)\nTitle: \(title ?? "Unavailable")\nAudio-only streams: \(audioStreamCount)\nSelected: \(selectedFormat ?? "None")\nUsable URL: \(hasUsableStreamURL ? "Yes" : "No")" }
}

