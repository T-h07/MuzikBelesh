# Phase 9 release audit

Baseline is the accepted Phase 8 merge b9386122a56ddf1550b360c4ce9401ff100ceeb3. Both origin/develop and origin/feature/phase-09-release matched this commit on inspection. The existing feature branch is used. The working tree was clean.

| Area and owner | Finding / failure risk | Existing coverage and missing evidence | Initial priority / correction |
|---|---|---|---|
| AppBootstrap, AppContainer, RootView | Single app container owns playback, library and downloads. Foreground triggers recovery. Launch still creates Phase 1 mock stores. | UI isolation and launch tests. Release binary mock exclusion needs verification. | P2 remove Release mock dependencies |
| AudioPlayerService clock | Every 0.5-second tick queries current track twice, artist/album, updates remote commands and republishes artwork. Background uses the same cadence. | PlaybackServiceAuditTests and previous/seek/EOF suites. Add clock SQL/publication measurement before correction. | P1 sustained unnecessary work |
| NowPlayingInfoCoordinator | Constructs UIImage and MPMediaItemArtwork on every clock publication. | No dedicated reuse test. | P2 cache artwork and publish at transport/metadata transitions |
| PlaybackQueueManager, GRDBPlaybackRepository | Each five-second checkpoint serializes the context and rewrites the entire explicit queue. | Atomic state/queue restoration tests. Add write count with populated queue. | P2 separate position checkpoint from structural snapshot |
| PlaybackNavigationEngine | setContext deduplicates using growing-array contains, quadratic for thousands of songs. History can grow indefinitely during extended listening. | Shuffle/history policy suites. Add 100–10,000 track measurements and bounded-history stress. | P2 linear deduplication and bounded navigation history |
| Audio session and routes | Disconnect pauses only reported playing state, permitting a waiting player to start later. No media-services reset recovery observer. | Interruption and transport mocks. Bluetooth requires hardware. | P1 route intent protection, reset recovery |
| SleepTimerService | Uses one deadline task, reconciles lifecycle, persists. UI uses TimelineView for countdown. | Deterministic deadline/cancel/restore tests. Locked device pending. | Review visible UI cadence |
| BackgroundTransfers, DownloadManager | Native tasks own transfers. Delegate progress already sampled at 0.5s and DB checkpoints separately throttled. No thermal or Low Power scheduling policy. | BackgroundDownloadTests cover identity, restored tasks, completion, network and cancellation. | P2 event-driven resource policy for newly scheduled work |
| StorageCoordinator and AudioFileService | Streaming copy and hash, journaled import, mutation gate. Existing export interface materializes complete audio Data. | Phase2/3 storage, duplicate, import integrity suites. Fault injection needed for full storage. | P2 file-based export, disk failure coverage |
| DatabaseManager, LibraryMigration | Twelve ordered additive migrations, foreign keys, managed file operations. No Phase 9 schema need identified. | Historical migration tests and deletion rollback/recovery suites. Device in-place upgrade pending. | Retain schema; run full regression |
| MusicLibraryService, LibrarySearch | Snapshot observation, stable identities, background search with debounce/stale-result protection. Search builds groups per request. | Universal search tests. Need large fixture latency/memory evidence. | Measure before further changes |
| ManagedLibraryFiles, artwork views | Bounded image input/downsampling, journaled replacement/deletion. Review async ownership and caches. | Artwork and deletion recovery tests. Physical memory trend pending. | P2 only if profiling shows excessive work |
| YouTube providers and views | Strict URL validation, bounded HTTP response, cached metadata, stale-query guard, user-driven download. | Parser/provider/search/details and fixture UI suites. Live availability deliberately opt-in. | Retain security and integration |
| Sharing and extension | Bounded validated inbox, coordinated atomic writes, separate user app opening. | Nine deterministic tests and end-to-end fixture. Phase 8 physical acceptance reported. Repeat post-upgrade. | Retain supported handoff |
| Diagnostics and logging | Bounded playback events and pseudonymous IDs. Current diagnostic title still identifies Phase 0. | Diagnostics tests. Thermal/power state absent. | P2 event-driven resource diagnostics; update presentation |
| CI, package and identity | Matched app/appex versions and arm64, ad-hoc group metadata read back, manifest SHA. Version hardcoded 0.1.0 in package assertion. | Existing packaging verification. | P2 prepare 1.0.0 candidate and keep provenance gates |

No confirmed P0 data-loss defect was found in this initial inspection. Hardware-dependent correctness, energy, thermal, interruption and signing claims remain subject to Phase 9 device acceptance. This register records source findings, with final evidence added as verification completes.

A profile-only dispatch in the existing CI workflow runs repeatable isolated playback work-count and large-library timing tests. It provides a simulator baseline, without implying device CPU percentage, battery consumption or temperature. No live media network requests are needed.

## Candidate corrections and residual evidence

The 16 reviewed areas above produced 10 grouped actionable findings: two P1
(clock overhead; route/reset recovery), seven P2 (Release mocks, artwork churn,
queue checkpoint rewrites, quadratic/unbounded navigation, resource scheduling,
export allocation/failure cleanup, candidate packaging), and one P3 (stale
Diagnostics presentation). No confirmed P0 was identified. The initial register
used provisional P2 for Diagnostics; final severity is cosmetic P3. All ten have
candidate corrections; their execution evidence is supplied by the integration
PR's focused/full runs. No pending run is represented as passed here.

Clock checkpoints now update only position; metadata is event-driven and artwork
reused. Set-based context setup and bulk availability reads remove quadratic and
per-track query costs. Navigation memory is bounded independently of listening
history. Waiting playback pauses on route loss. Media reset rebuilds the native
player/item paused, preserving identity/position and awaiting explicit Play.
Resource notifications reduce display cadence and new transfer concurrency,
defer new work at serious/critical pressure, and suspend nonessential per-file
duration maintenance without modifying user preferences. Export uses a verified
streaming copy; failed writes remove partial output and retain the source. Release
excludes legacy mocks, exposes current system diagnostics and verifies the 1.0.0
app/extension metadata before packaging.

Regression additions: ReleasePerformanceTests (clock work counts, scaling and
XCTest CPU/memory), ReleaseReliabilityTests (SQLite capacity rollback, streaming
write failure, export lifetime/hash, 10k records, bounded history, artwork reuse,
200 repeated track changes/deallocation), PlaybackServiceAuditTests (waiting route
and reset), BackgroundDownloadTests (thermal queue/recovery) and YouTubeUITests
(large text/repeated player presentation). Historical migrations, safe deletion,
import/duplicate, duration/EOF, URL/redirect, inbox and restoration suites remain
part of the complete verification. No new database migration or audio-byte
normalization is introduced.

Residual risks are empirical: real radio switching, locked audio/sleep,
interruption behavior, extended memory/energy/thermal trends, live YouTube,
VoiceOver and build 189 in-place signing/data continuity. They are NOT RUN for
this candidate, not waived. See PHASE_09_FEATURE_MATRIX.md,
PHASE_09_PERFORMANCE.md and PHASE_09_DEVICE_TESTING.md. Any new failing test or
physical defect reopens its severity and release gate before integration.
