# Muzik Belesh architecture — v1.2.0

Muzik Belesh is a **native SwiftUI iPhone application** built around a persistent, on-device music library. The application is offline-first: music and personal settings live on the phone, while network providers are used only to discover or acquire recordings when requested.

**Stable release:** [v1.2.0](https://github.com/T-h07/MuzikBelesh/releases/tag/v1.2.0) · **Build 200**. This overview describes the shipped architecture. The phase sections below record the historical evolution of individual subsystems.

## Runtime composition

`OFFLINE/App/OFFLINEApp.swift` provides the app entry point. `AppContainer` creates and owns the production services, while `RootView` / `AppCoordinator` manage the four-tab UI, navigation and presentation. This keeps shared state in established service owners instead of constructing duplicate download, database or playback engines in feature views.

| Responsibility | Current authority |
| --- | --- |
| Audio playback | `AudioPlayerService`, AVPlayer/AVFoundation and MediaPlayer integration |
| Queue, shuffle, repeat and restoration | `PlaybackQueueManager` and the navigation engine |
| Library and managed files | `StorageCoordinator`, GRDB repositories and `MusicLibraryService` |
| Downloads | One `DownloadManager`, managed transfers and persisted jobs |
| Spotify/portable-library acquisition | Existing playlist migration repository/coordinator and candidate matching pipeline |
| Local profile | `LocalProfileService` and managed avatar storage |
| Listening analytics | `ListeningSessionTracker`, analytics repository and stats service |
| Themes | `ThemeService` / `ThemeRoot` and `ThemePalette` |
| Portable exports/imports | `LibrarySharingService` and `OFFLINE/LibrarySharing` |
| Collection artwork | `CollectionArtworkService`, `CollectionArtworkView`, shared image pipeline |
| Share extension | `OFFLINEShareExtension`, validated shared-link App Group inbox |

## Persistence and boundaries

- **SQLite / GRDB** is the authority for song metadata, playlist/album relationships, downloads, migration state, local profile, listening analytics and collection-artwork preferences. Migrations are versioned and additive.
- Managed audio and artwork are stored in app-owned file directories with journaled or guarded operations for import, deletion and repair.
- **Local-only** profile images, listening history, theme preferences and device file paths are deliberately excluded from portable `.mbelesh` exports.
- **One audio engine** is shared by Library, mini-player, Now Playing, Lock Screen, Control Center, AirPods and Bluetooth controls.
- **One download pipeline** serves user-selected YouTube audio and accepted playlist migration acquisitions. Background execution and restoration follow iOS policies.
- **Untrusted data** includes downloaded metadata, YouTube URLs, discovery-provider responses and imported CSV/JSON/ZIP/`.mbelesh` files. Validate size, source and schema before touching persisted data.

The application and Share extension retain their existing identifiers (`com.th07.muzikbelesh`, `com.th07.muzikbelesh.share`) and the shared inbox group (`group.com.th07.muzikbelesh.inbox`) to preserve SideStore update compatibility.

For current behavior, see [README](../README.md), [Phase 11 feature notes](PHASE_11_05_DYNAMIC_ARTWORK.md), [Phase 12 audit](PHASE_12_FINAL_RELEASE_AUDIT.md) and [database migrations](MIGRATIONS.md).

---

## Historical subsystem implementation notes

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

# Phase 6 YouTube integration

AppContainer owns protocol-injected YouTube search, metadata, local extraction,
preferences, thumbnails and download preparation. Search and paste links share one
observable details screen. Diagnostics reuses the same production resolver. The
library's existing track_sources provenance supports downloaded detection without
migration. No YouTube service creates a player or mutates playback/storage.
See [PHASE_06_YOUTUBE.md](PHASE_06_YOUTUBE.md) for provider limitations, concurrency,
cache/URL rules, local-only configuration and the transient Phase 7 contract.

## Phase 7 downloads

AppContainer shares one DownloadManager across Video Details and Downloads. It coordinates the GRDB repository, local resolver, URLSession download delegate and existing managed library import. See PHASE_07_DOWNLOADS.md.

## Migration-managed playlist persistence

`PlaylistMigration/GRDBPlaylistMigrationRepository` owns atomic destination/session/
occurrence creation and persistent lifecycle mutations. `migration_entries` is the
authoritative ordered model for imported playlists; ordinary playlists continue to
use `playlist_tracks`. LibrarySnapshot observes both, and typed MigrationPlaylistRow
values expose placeholders and verified local tracks. PlaybackQueueManager maps
occurrence identities to real track IDs before AudioPlayerService selection, preserving
repetitions through navigation and restart. See [Phase 10.1](PHASE_10_01_PERSISTENCE.md).

## Phase 11.1 local profile

`AppContainer` creates one `LocalProfileService` backed by `LocalProfileRepository`
(single-row `local_user_profile`, migration `v024_local_user_profile`) and reads it
before the first frame. `RootView` routes through a profile gate: onboarding when storage
holds no profile, a recoverable error screen when the profile can't be read, otherwise the
unchanged four-tab interface. App lifecycle forwarding lives in that always-mounted gate.
The profile owns no library data, has no foreign keys and makes no network requests;
avatars live in `Application Support/MuzikBelesh/Profile`. See
[Phase 11.1](PHASE_11_01_LOCAL_PROFILE.md).

## Phase 11.2 listening analytics

`AudioPlayerService` owns a `ListeningSessionTracker` that observes playback (periodic time
observer, transport changes, seeks, pauses, interruptions, end of item) and never controls it.
The tracker credits only progressing audio and writes through `ListeningAnalyticsRepository`
with guarded, synchronous checkpoints; a failure is recorded and never reaches playback.
`AppContainer` creates a `ListeningStatsService` that runs aggregate SQL off the main thread
for the Profile preview and the "Your Listening" dashboard. Everything stays on the device.
See [Phase 11.2](PHASE_11_02_LISTENING_ANALYTICS.md).

## Phase 11.3 themes

`ThemeService` (`OFFLINE/DesignSystem`) is owned by `AppContainer`, created first and
synchronously from a versioned `UserDefaults` entry (`appearance.theme.v1`), so the first frame
already uses the saved accent. `ThemeRoot`, inside the root hosting controller, places the
derived `ThemePalette` in the SwiftUI environment (`\.themePalette`) and sets the root tint.
Views read `palette.accent` / `palette.onAccent`; `AppColors.accentPrimary` no longer exists.
Backgrounds, text and status colours stay fixed. A theme change touches no database, player,
library, download or analytics state. See [Phase 11.3](PHASE_11_03_CUSTOM_THEMES.md).

## Phase 11.4 library sharing

`LibrarySharingService` (`OFFLINE/LibrarySharing`) is owned by `AppContainer` and created after
the migration coordinator. Export builds an allowlisted `.mbelesh` document field by field from
one read snapshot (`PortableLibraryExporter`) and writes it atomically for the share sheet.
Import validates the file (`PortableLibraryCodec`), previews it, commits every selected playlist
in one transaction as migration sessions with source `muzikBelesh`, then
`PortableImportReconciler` reuses local songs (exact recording provenance, then the existing
local matching policy) and, when automatic acquisition was chosen, accepts only shared
recordings the strict policy recommends before handing each playlist to
`PlaylistMigrationCoordinator`. Downloads stay with `PlaylistAcquisitionCoordinator` and
`DownloadManager`. Opened files are staged privately and presented after the profile gate.
See [Phase 11.4](PHASE_11_04_LIBRARY_SHARING.md).

## Phase 11.5 collection artwork

`CollectionArtworkService` (`OFFLINE/Library/Artwork`) is owned by `AppContainer` and injected as
an environment object. It builds a candidate index from library snapshots off the main actor,
observes per-collection modes from `collection_artwork_preferences`, and runs the app's one
30-minute rotation scheduler while in the foreground (`RootView` forwards `scenePhase`).
`CollectionArtworkView` renders custom cover → mosaic → single cover → placeholder through the
shared `ArtworkImagePipeline`. Custom covers are written by `MusicLibraryService.setCollectionCover`
through the existing managed-file journal. See [Phase 11.5](PHASE_11_05_DYNAMIC_ARTWORK.md).

## Phase 12 release hardening (v1.2.0)

No architectural changes. Targeted corrections inside existing owners:

- `ThemeService` treats re-selecting the active theme as a no-op (no publication, no write).
- `BoundedHTTPBody` (in `YouTubeTransport.swift`) is shared by `YouTubeURLSessionTransport`
  and `SearXNGURLSessionTransport`, so response limits are enforced while streaming.
- `PlaylistDetailView` keeps the in-playlist search field at the top while searching.
- Listening ranking rows keep their button trait for VoiceOver.

See [PHASE_12_FINAL_RELEASE_AUDIT.md](PHASE_12_FINAL_RELEASE_AUDIT.md).
