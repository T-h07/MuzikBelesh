# Architecture

`OFFLINEApp` creates an `AppContainer` with environment-aware `AppConfiguration`, the Phase 0 `YouTubeProbe`, and Phase 1 in-memory stores. `RootView` and `AppCoordinator` own tab and presentation state. Feature views receive shared stores through the SwiftUI environment; focused view models can be added without introducing global singletons. `DiagnosticsView` remains available from Settings and is not part of normal music browsing.

Phase 2 adds an optional `StorageCoordinator` to the same container. It owns `AppStoragePaths`, `DatabaseManager`, GRDB repositories, metadata/hash services, and import/export consistency. The database remains private in Application Support, while managed audio and artwork use Documents-relative paths. Existing mock playback/download behavior remains intentionally available until its later production phases.

The YouTubeKit adapter is isolated under `OFFLINE/Feasibility/YouTube`. It validates input, requests metadata and streams locally, filters audio-only streams, and returns sanitized result data. It does not enable YouTubeKit's remote fallback and does not persist or download media.

The Share extension is a separate target with its own bundle identifier and activation metadata. Phase 0 validates received URLs and finishes cleanly; the physical iPhone test confirmed Share-sheet appearance and URL receipt. No unsupported extension-to-app launch or App Group entitlement is assumed. Automatic handoff is deferred to Phase 8.

Phase 2 provides the GRDB repositories and Phase 3 provides the AVFoundation/MediaPlayer playback subsystem. Phase 3 is complete and was accepted through developer-reported iPhone 13 Pro Max validation. Later phases may add the production YouTube integration, download manager, and supported Share handoff. Development infrastructure remains outside runtime code.

# Phase 4 playback responsibilities

`AudioPlayerService` remains the only AVPlayer authority. `PlaybackQueueManager` owns persistent queue occurrences, context ordering, shuffle cycles, and repeat mode; `PlaybackHistoryService` records actual starts; `SleepTimerService` owns a persisted deadline and asks the same service to pause. No feature creates a second player.

The audit adds an injectable `PlaybackPlayer` transport and a suspending FIFO command
gate to the existing service. Queue candidates commit after asset validation and
item selection; queue and playback snapshots are saved in one SQLite transaction.
See [the audit register and acceptance plan](APPLICATION_AUDIT.md).


# Phase 5 authoritative library

AppContainer now supplies MusicLibraryService alongside the existing storage/audio
services. GRDB ValueObservation projects persisted tracks, relationships, custom
playlist order, likes, sort preference and recent listening IDs to all production
library surfaces. Mock models remain fixtures and deferred YouTube/download demos.

See LIBRARY_ARCHITECTURE.md, SAFE_LIBRARY_DELETION.md and ARTWORK_MANAGEMENT.md for
the additive v009 schema, identity rules, file-operation journals and collection
playback snapshots. No second database, queue or audio engine is introduced.
