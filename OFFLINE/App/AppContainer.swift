import SwiftUI
@MainActor
final class AppContainer: ObservableObject {
    let configuration: AppConfiguration
    let youtubeProbe: YouTubeProbe
    let music: MockMusicStore
    let playback: MockPlaybackStore
    let downloads: MockDownloadStore
    let settings: MockSettingsStore
    let storage: StorageCoordinator?
    let audioPlayer: AudioPlayerService
    init(configuration: AppConfiguration = .current(), youtubeProbe: YouTubeProbe = YouTubeKitProbe(), music: MockMusicStore = MockMusicStore(), playback: MockPlaybackStore = MockPlaybackStore(), downloads: MockDownloadStore = MockDownloadStore(), settings: MockSettingsStore = MockSettingsStore(), storage: StorageCoordinator? = nil) {
        self.configuration = configuration; self.youtubeProbe = youtubeProbe; self.music = music; self.playback = playback; self.downloads = downloads; self.settings = settings
        if let storage { self.storage = storage } else { self.storage = try? StorageCoordinator(paths: AppStoragePaths()) }
        self.audioPlayer = AudioPlayerService(storage: self.storage)
    }
}

