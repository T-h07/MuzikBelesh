# Mock data and stores

Phase 1 uses deterministic in-memory fixtures in `MockMusicCatalog`. Stable string IDs identify tracks, albums, artists, playlists, videos, and download jobs. `MockMusicStore` owns catalog mutations, liked IDs, recently played IDs, playlists, and metadata edits. `MockPlaybackStore` owns current track, queue, play state, position, shuffle, and repeat. `MockDownloadStore` owns mock job states and progress. `MockSettingsStore` owns session-only preferences.

All visible Phase 1 interactions use these stores and make no network requests. Mutations are injected through `AppContainer`, so dependent views observe the same state. Stores reset when the app process is relaunched. Future production repositories can replace these stores without changing the design-system components or navigation coordinator.

