# Mock data and stores (historical)

Phase 1 used deterministic in-memory fixtures (`MockMusicCatalog`, `MockMusicStore`,
`MockPlaybackStore`, `MockDownloadStore`, `MockSettingsStore`) before the GRDB library
existed. They were compiled only in DEBUG builds and were no longer used by any screen.

They were removed in the Phase 10.9 final hardening (`Docs/PHASE_10_09_SECURITY_PERFORMANCE.md`),
together with the DEBUG mock rows/cards in `RootView` and `Phase1StoreTests`. UI tests use the
DEBUG-only fixtures in `OFFLINE/YouTube/YouTubeUITestFixtures.swift` and the `--ui-testing`
launch arguments handled in `AppBootstrap`; production data always comes from the database.
