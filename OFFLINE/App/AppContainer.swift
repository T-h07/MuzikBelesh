import SwiftUI
import Combine
@MainActor
final class AppContainer: ObservableObject {
    let resources: ResourceMonitor
    private var subscriptions = Set<AnyCancellable>()
    private var maintenanceTask: Task<Void, Never>?
    private var maintenanceFinished = false
    let configuration: AppConfiguration
    let youtubeProbe: YouTubeProbe
    #if DEBUG
    let music = MockMusicStore()
    let playback = MockPlaybackStore()
    #endif
    let downloads: DownloadManager
    let storage: StorageCoordinator?
    let library: MusicLibraryService
    let playlistImport: PlaylistImportViewModel?
    let playlistMatching: PlaylistMatchingViewModel?
    let youtubeSearch: YouTubeSearchService
    let youtubeMetadata: any YouTubeMetadataProvider
    let youtubeResolver: any YouTubeAudioResolver
    let youtubePreparer: any YouTubeDownloadPreparing
    let youtubeLibrary: any YouTubeLibraryChecking
    let youtubeManualLookup: YouTubeManualLookup
    let youtubePreferences: YouTubePreferences
    let youtubeArtwork = YouTubeArtworkLoader()
    let audioPlayer: AudioPlayerService
    init(configuration: AppConfiguration = .current(), youtubeProbe: YouTubeProbe? = nil, audioTransfer: any AudioTransferring = TransferService(), observeDownloadNetwork: Bool = true, backgroundTransfers: (any SystemDownloading)? = nil, storage: StorageCoordinator? = nil, youtubeSearchProvider: (any YouTubeSearchProvider)? = nil, youtubeMetadataProvider: (any YouTubeMetadataProvider)? = nil, youtubeAudioResolver: (any YouTubeAudioResolver)? = nil, youtubeDefaults: UserDefaults = .standard, resourceMonitor: ResourceMonitor? = nil) {
        self.resources = resourceMonitor ?? ResourceMonitor()
        self.configuration = configuration
        if let storage { self.storage = storage } else { self.storage = try? StorageCoordinator(paths: AppStoragePaths()) }
        let transport = YouTubeURLSessionTransport()
        let web = YouTubeWebProvider(transport: transport)
        let metadata = CachedYouTubeMetadataProvider(provider: youtubeMetadataProvider ?? web)
        let resolver = youtubeAudioResolver ?? YouTubeKitAudioResolver(metadata: metadata, transport: transport)
        self.youtubeSearch = YouTubeSearchService(provider: youtubeSearchProvider ?? web)
        self.youtubeMetadata = metadata
        self.youtubeManualLookup = YouTubeManualLookup(metadata: metadata, transport: transport)
        self.youtubeResolver = resolver
        self.youtubePreparer = YouTubeDownloadPreparer(resolver: resolver)
        self.youtubeLibrary = YouTubeLibraryLookup(database: self.storage?.database.dbQueue, paths: self.storage?.paths)
        self.youtubePreferences = YouTubePreferences(defaults: youtubeDefaults)
        self.downloads = DownloadManager(storage: self.storage, preferences: self.youtubePreferences, preparer: self.youtubePreparer, transfer: audioTransfer, artwork: youtubeArtwork, observeNetwork: observeDownloadNetwork, system: backgroundTransfers)
        self.youtubeProbe = youtubeProbe ?? YouTubeKitProbe(resolver: resolver)
        self.audioPlayer = AudioPlayerService(storage: self.storage)
        self.library = MusicLibraryService(storage: self.storage, player: self.audioPlayer)
        self.playlistImport = self.storage.map { PlaylistImportViewModel(storage: $0) }
        if let storage = self.storage {
            self.playlistMatching = PlaylistMatchingViewModel(service: PlaylistMigrationMatchingService(
                repository: storage.playlistMigrations, providers: [YouTubeSearchProviderAdapter(search: self.youtubeSearch, metadata: self.youtubeMetadata)]), repository: storage.playlistMigrations)
        } else { self.playlistMatching = nil }
        resources.$policy.sink { [weak self] policy in
            guard let self else { return }
            audioPlayer.setResourcePolicy(policy)
            downloads.setResourcePolicy(policy)
            scheduleMaintenance(policy)
        }.store(in: &subscriptions)
    }
    private func scheduleMaintenance(_ policy: ResourcePolicy) {
        guard policy.allowsMaintenance, !maintenanceFinished, maintenanceTask == nil, let storage else { return }
        maintenanceTask = Task(priority: .utility) { [weak self] in
            let completed = try? await storage.repairYouTubeDurations { @MainActor [weak self] in
                self?.resources.policy.allowsMaintenance == true
            }
            guard let self else { return }
            maintenanceTask = nil
            // An I/O failure is retried on the next launch. A pressure deferral
            // is retried when a subsequent policy update permits maintenance.
            maintenanceFinished = completed != false
            if completed == false && resources.policy.allowsMaintenance { scheduleMaintenance(resources.policy) }
        }
    }

}

