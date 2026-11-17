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
    let downloads: DownloadManager
    let storage: StorageCoordinator?
    let library: MusicLibraryService
    let playlistImport: PlaylistImportViewModel?
    let playlistMatching: PlaylistMatchingViewModel?
    /// Phase 10.5 automatic acquisition. Nil when storage is unavailable or disabled.
    let playlistAcquisition: PlaylistAcquisitionCoordinator?
    /// Phase 10.6: the single owner of migration lifecycle decisions. Nil without storage.
    let migrationCoordinator: PlaylistMigrationCoordinator?
    /// Phase 10.7: persistent issue reporting, completion summaries and aggregate
    /// notifications. Observes the coordinators above; owns no scheduling.
    let migrationIssues: MigrationIssueCoordinator?
    let youtubeSearch: YouTubeSearchService
    let youtubeMetadata: any YouTubeMetadataProvider
    let youtubeResolver: any YouTubeAudioResolver
    let youtubePreparer: any YouTubeDownloadPreparing
    let youtubeLibrary: any YouTubeLibraryChecking
    let youtubeManualLookup: YouTubeManualLookup
    let discoverySources: DiscoverySourceSettings
    /// Short-timeout, cookie-free, no-redirect HTTPS transport for third-party search APIs.
    let searxTransport = SearXNGURLSessionTransport()
    let invidiousPool: InvidiousInstancePool
    let youtubePreferences: YouTubePreferences
    let youtubeArtwork = YouTubeArtworkLoader()
    let audioPlayer: AudioPlayerService
    /// Phase 11.1 device-local profile. Owns no library data and no network access.
    let profile: LocalProfileService
    init(configuration: AppConfiguration = .current(), youtubeProbe: YouTubeProbe? = nil, audioTransfer: any AudioTransferring = TransferService(), observeDownloadNetwork: Bool = true, backgroundTransfers: (any SystemDownloading)? = nil, storage: StorageCoordinator? = nil, youtubeSearchProvider: (any YouTubeSearchProvider)? = nil, youtubeMetadataProvider: (any YouTubeMetadataProvider)? = nil, youtubeAudioResolver: (any YouTubeAudioResolver)? = nil, youtubeDefaults: UserDefaults = .standard, resourceMonitor: ResourceMonitor? = nil, automaticAcquisition: Bool = false, acquisitionNotifier: (any PlaylistAcquisitionNotifying)? = nil, backgroundExecution: (any BackgroundExecutionGranting)? = nil, profileStore: (any LocalProfileStoring)? = nil) {
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
        self.discoverySources = DiscoverySourceSettings(defaults: youtubeDefaults)
        self.invidiousPool = InvidiousInstancePool(transport: searxTransport)
        self.youtubeResolver = resolver
        self.youtubePreparer = YouTubeDownloadPreparer(resolver: resolver)
        self.youtubeLibrary = YouTubeLibraryLookup(database: self.storage?.database.dbQueue, paths: self.storage?.paths)
        self.youtubePreferences = YouTubePreferences(defaults: youtubeDefaults)
        // Exactly one DownloadManager owns every job, ordinary and playlist-driven.
        self.downloads = DownloadManager(storage: self.storage, preferences: self.youtubePreferences, preparer: self.youtubePreparer, transfer: audioTransfer, artwork: youtubeArtwork, observeNetwork: observeDownloadNetwork, system: backgroundTransfers, execution: backgroundExecution)
        self.youtubeProbe = youtubeProbe ?? YouTubeKitProbe(resolver: resolver)
        // A single-row read, so the launch destination is known before the first frame and the
        // tab interface never flashes ahead of onboarding. Storage failure stays a failure.
        self.profile = LocalProfileService(store: profileStore ?? self.storage.map { LocalProfileRepository(db: $0.database.dbQueue, paths: $0.paths) })
        self.profile.load()
        self.audioPlayer = AudioPlayerService(storage: self.storage)
        self.library = MusicLibraryService(storage: self.storage, player: self.audioPlayer)
        self.playlistImport = self.storage.map { PlaylistImportViewModel(storage: $0) }
        var matchingService: PlaylistMigrationMatchingService?
        let coordinatorStore = self.storage.map { MigrationCoordinatorRepository(db: $0.database.dbQueue) }
        if let storage = self.storage {
            // Order: public Invidious, optional SearXNG, direct YouTube fallback. Injected
            // fixture search (UI tests) keeps matching offline and deterministic.
            var sources: [any ExternalCandidateDiscovery] = []
            if youtubeSearchProvider == nil {
                sources.append(PublicInvidiousDiscovery(settings: discoverySources, pool: invidiousPool))
                sources.append(ConfiguredSearXNGDiscovery(settings: discoverySources, transport: searxTransport))
            }
            let settings = discoverySources
            sources.append(GatedDiscovery(base: YouTubeSearchProviderAdapter(search: self.youtubeSearch, metadata: self.youtubeMetadata),
                                          enabled: { settings.useDirectYouTube }))
            // Durable provider cooldowns are shared by every migration and survive launches.
            let service = PlaylistMigrationMatchingService(repository: storage.playlistMigrations, providers: sources,
                                                           restriction: .durable, cooldowns: coordinatorStore)
            matchingService = service
            self.playlistMatching = PlaylistMatchingViewModel(service: service, repository: storage.playlistMigrations)
        } else { self.playlistMatching = nil }
        // Startup order: storage/database, library snapshot, DownloadManager (which begins
        // background-transfer reconciliation), then acquisition reconciliation.
        if automaticAcquisition, let storage = self.storage {
            let coordinator = PlaylistAcquisitionCoordinator(storage: storage, downloads: downloads, preferences: youtubePreferences,
                notifier: acquisitionNotifier ?? SilentAcquisitionNotifier(), execution: backgroundExecution)
            self.playlistAcquisition = coordinator
            coordinator.start()
        } else { self.playlistAcquisition = nil }
        // Last in the startup order: it waits for transfer reconciliation, then restores
        // persisted migration intent and schedules eligible work.
        if let storage = self.storage, let coordinatorStore, let matchingService, let matching = self.playlistMatching {
            let foreground = backgroundTransfers == nil || UIApplication.shared.applicationState != .background
            let migrationCoordinator = PlaylistMigrationCoordinator(repository: coordinatorStore, migrations: storage.playlistMigrations,
                matching: matching, service: matchingService, acquisition: playlistAcquisition, downloads: downloads, foreground: foreground)
            self.migrationCoordinator = migrationCoordinator
            Task { await migrationCoordinator.start() }
        } else { self.migrationCoordinator = nil }
        if let storage = self.storage {
            // The same notification delegate as acquisition; never a competing one.
            let notifier: any MigrationIssueNotifying = (acquisitionNotifier as? MigrationIssueNotifying) ?? SilentAcquisitionNotifier()
            let issues = MigrationIssueCoordinator(repository: MigrationIssueRepository(db: storage.database.dbQueue, paths: storage.paths),
                migrations: storage.playlistMigrations, coordinator: migrationCoordinator, acquisition: playlistAcquisition, notifier: notifier)
            self.migrationIssues = issues
            Task { await issues.start() }
        } else { self.migrationIssues = nil }
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

