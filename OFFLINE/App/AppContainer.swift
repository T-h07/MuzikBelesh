import SwiftUI
@MainActor
final class AppContainer: ObservableObject {
    let configuration: AppConfiguration
    let youtubeProbe: YouTubeProbe
    let music: MockMusicStore
    let playback: MockPlaybackStore
    let downloads: DownloadManager
    let settings: MockSettingsStore
    let storage: StorageCoordinator?
    let library: MusicLibraryService
    let youtubeSearch: YouTubeSearchService
    let youtubeMetadata: any YouTubeMetadataProvider
    let youtubeResolver: any YouTubeAudioResolver
    let youtubePreparer: any YouTubeDownloadPreparing
    let youtubeLibrary: any YouTubeLibraryChecking
    let youtubePreferences: YouTubePreferences
    let youtubeArtwork = YouTubeArtworkLoader()
    let audioPlayer: AudioPlayerService
    init(configuration: AppConfiguration = .current(), youtubeProbe: YouTubeProbe? = nil, music: MockMusicStore = MockMusicStore(), playback: MockPlaybackStore = MockPlaybackStore(), audioTransfer: any AudioTransferring = TransferService(), observeDownloadNetwork: Bool = true, settings: MockSettingsStore = MockSettingsStore(), storage: StorageCoordinator? = nil, youtubeSearchProvider: (any YouTubeSearchProvider)? = nil, youtubeMetadataProvider: (any YouTubeMetadataProvider)? = nil, youtubeAudioResolver: (any YouTubeAudioResolver)? = nil, youtubeDefaults: UserDefaults = .standard) {
        self.configuration = configuration; self.music = music; self.playback = playback; self.settings = settings
        if let storage { self.storage = storage } else { self.storage = try? StorageCoordinator(paths: AppStoragePaths()) }
        let transport = YouTubeURLSessionTransport()
        let web = YouTubeWebProvider(transport: transport)
        let metadata = CachedYouTubeMetadataProvider(provider: youtubeMetadataProvider ?? web)
        let resolver = youtubeAudioResolver ?? YouTubeKitAudioResolver(metadata: metadata, transport: transport)
        self.youtubeSearch = YouTubeSearchService(provider: youtubeSearchProvider ?? web)
        self.youtubeMetadata = metadata
        self.youtubeResolver = resolver
        self.youtubePreparer = YouTubeDownloadPreparer(resolver: resolver)
        self.youtubeLibrary = YouTubeLibraryLookup(database: self.storage?.database.dbQueue, paths: self.storage?.paths)
        self.youtubePreferences = YouTubePreferences(defaults: youtubeDefaults)
        self.downloads = DownloadManager(storage: self.storage, preferences: self.youtubePreferences, preparer: self.youtubePreparer, transfer: audioTransfer, artwork: youtubeArtwork, observeNetwork: observeDownloadNetwork)
        self.youtubeProbe = youtubeProbe ?? YouTubeKitProbe(resolver: resolver)
        self.audioPlayer = AudioPlayerService(storage: self.storage)
        self.library = MusicLibraryService(storage: self.storage, player: self.audioPlayer)
        if let storage = self.storage {
            Task(priority: .utility) { try? await storage.repairYouTubeDurations() }
        }
    }
}

