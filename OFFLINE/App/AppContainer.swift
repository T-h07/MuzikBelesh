import SwiftUI
final class AppContainer: ObservableObject {
    let configuration: AppConfiguration
    let youtubeProbe: YouTubeProbe
    let music: MockMusicStore
    let playback: MockPlaybackStore
    let downloads: MockDownloadStore
    let settings: MockSettingsStore
    init(configuration: AppConfiguration = .current(), youtubeProbe: YouTubeProbe = YouTubeKitProbe(), music: MockMusicStore = MockMusicStore(), playback: MockPlaybackStore = MockPlaybackStore(), downloads: MockDownloadStore = MockDownloadStore(), settings: MockSettingsStore = MockSettingsStore()) { self.configuration = configuration; self.youtubeProbe = youtubeProbe; self.music = music; self.playback = playback; self.downloads = downloads; self.settings = settings }
}

