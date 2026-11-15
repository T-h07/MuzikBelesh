# Phase 10.5 — Automatic audio acquisition for imported playlists

Confirm the correct songs → Muzik Belesh queues eligible audio automatically → downloads continue in the background as iOS permits → interrupted work recovers → the playlist becomes playable offline → a local notification reports completion.

Implementation-complete and physical-device acceptance are separate milestones. Nothing in this document claims device acceptance; the checklist at the end is for the owner's iPhone 13 Pro Max (SideStore).

## 1. Architecture

```
Phase 10.4 decision (accepted YouTube candidate, entry `matched`)
        │  committed in GRDB → DatabaseRegionObservation
        ▼
PlaylistAcquisitionCoordinator  (orchestration only, @MainActor)
        │  one link per occurrence ─────────────► migration_acquisitions
        │  one job per recording ─┐
        ▼                         ▼
DownloadManager (existing, single instance) → BackgroundTransfers (background URLSession)
        │  staging → DownloadMedia.validate → StorageCoordinator.importAudio (SHA-256, dedupe, journal)
        ▼
completed job with verified trackID
        │
        ▼
GRDBPlaylistMigrationRepository.associateAcquiredTrack (decode + SHA-256 outside the write
transaction, stale-decision guard inside it) → entry `ready`
```

Nothing replaces existing infrastructure:

| Concern | Owner (reused) |
|---|---|
| Queue, global concurrency, Wi-Fi/cellular policy, resource/thermal policy | `DownloadManager` |
| Background transfers, task reconciliation, staged-file recovery | `BackgroundTransfers` + `DownloadManager` |
| Stream resolution and authorization | `YouTubeDownloadPreparer` / existing resolver, `DownloadMedia.permits` (unchanged) |
| Payload and audio validation | `DownloadMedia.validate`, `AudioFileService` |
| Permanent import, SHA-256, duplicate detection, journaling | `StorageCoordinator.importAudio` |
| Decisions, occurrences, `ready` invariant | `GRDBPlaylistMigrationRepository` |
| Durable association, pause intent, notification state | **new** `PlaylistAcquisitionRepository` (v016 tables) |
| Orchestration | **new** `PlaylistAcquisitionCoordinator` |

`AppContainer` creates exactly one `DownloadManager` and, in production, one coordinator. The Downloads tab shows the same queue, with the playlists each job serves ("For My Spotify Favorites").

### Coordinator responsibilities

Observes committed decisions; creates links; deduplicates by recording identity; creates or reuses the shared job; enforces Pause/Continue with consumer accounting; classifies failures and applies bounded retries; associates verified tracks with stale-decision protection; persists everything; reconciles on launch and foreground; derives per-song and per-playlist presentation; reconciles notifications. A single idempotent `pass()` does all of this. Passes never overlap; a request during a pass causes exactly one rerun. Triggers: launch, foreground return, any commit to `migration_entries`/`migration_candidates`/`playlist_migrations`, a state transition of a linked job, Pause/Continue/Retry, and the retry timer. The coordinator's own tables are deliberately not observed, so passes converge.

## 2. State machine

Occurrences keep the Phase 10.4 status `matched` during acquisition and move to `ready` only through verified association. This is deliberate: 10.4's reject path requires `matched`, and `queued → matched` is not a legal transition, so mirroring transfer states onto entries would break reversibility of decisions. Transfer sub-states come from the shared job.

```
link:   waiting ──(job completed, trackID)──► associating ──(verified, decision unchanged)──► ready
           │  ▲                                    │
           │  └──(bounded automatic retry)──┐      ├─(decision changed)──► link removed (stale)
           ▼                                │      └─(audio invalid)─────► one repair, else failed
        failed (retryable, user Retry) ◄────┘
        unsupported (permanent; Import Audio from Files)
```

Per-song display (derived from link + job): Available offline · Queued · Preparing download · Downloading — 61% (only with a real byte total; otherwise "Downloading") · Waiting for Wi-Fi · Waiting for connection · Waiting for device to cool · Verifying audio · Downloads paused · Paused · Download failed · Unsupported source. Unconfirmed songs keep their 10.4 labels (Needs review, Awaiting local audio…).

## 3. Database changes

Two additive migrations: `v016_playlist_audio_acquisition` and, in the device hotfix, `v017_acquisition_notification_batches` (§20). The first is `v016_playlist_audio_acquisition` (`OFFLINE/PlaylistMigration/Acquisition/AcquisitionSchema.swift`). No shipped migration was edited; schema-count assertions in two persistence tests were updated from 15 to 16.

`migration_acquisitions` — PK `entryID` (cascade with the occurrence), `migrationID` (cascade), `candidateID` (the accepted decision the link was made for), `provider` (`youtube`), `providerIdentity`, `downloadJobID` (→ `download_jobs`, SET NULL), `createdJob`, `state` (CHECK), `trackID` (→ `tracks`, SET NULL), `failure`, `retries`, `nextRetryAt`, timestamps. Indexed by job, identity and playlist.

`migration_acquisition_controls` — PK `migrationID` (cascade), `userPaused`, `readyNotifiedAt`, `partialNotifiedSummary`.

Transfer state, generation, background session, task number, progress, bytes, quality, attempts and error text stay in `download_jobs` (v011/v012), which already has a unique per-video index; nothing is duplicated. The SQL was executed against SQLite during development (CHECK rejection, SET NULL and cascades verified).

## 4. Deduplication

* Before download: provider identity (`youtube` + 11-character video ID). All links with the same identity share one job; `DownloadManager.acquisitionJob(for:)` returns an existing job unchanged (main-actor isolation plus the unique index prevent concurrent duplicates).
* A completed job is **not** restarted (unlike `enqueue`, which treats it as a repair). Its track is verified during association; a repair (`retry(repair: true)`) is requested once only when the managed audio is missing or invalid.
* After download: SHA-256 in `StorageCoordinator` reuses identical content even across different identities.
* Never by title/artist. Different provider IDs are never assumed identical before their bytes prove it.
* Result: three playlists × one recording → one job, one file, three `ready` occurrences. Repeated occurrences in one playlist remain distinct rows sharing a track.

## 5. Background execution (iOS limits)

* Media bytes move through the existing background `URLSession`; they continue while the user is in another app, while locked, and while suspended, under system control.
* The app's own code (stream resolution, verification, import, association, notification) only runs when iOS gives the app execution time. New in this phase: when a background session event wakes the app, `DownloadManager` opens a bounded window (`beginBackgroundTask`) so it can verify staged audio and fill the freed slot before suspending again. The window ends as soon as no app work remains or iOS expires it; expiry only stops new work.
* Tasks created while the app is in the background may be treated as discretionary and delayed by iOS.
* If iOS does not give the app time, remaining work stays queued and continues at the next opportunity (next wake or launch). The UI never shows "Downloading" for work that is only queued.
* No endless polling, no silent audio, no new background modes or entitlements.
* After a **force quit**, iOS cancels the app's background transfers and does not relaunch it. The durable queue, decisions, pause intent and completed audio survive; work resumes on the next manual launch.

## 6. Pause / Continue

* Pause persists `userPaused`; new jobs are never created for that playlist; its jobs are paused only when **no non-paused consumer** needs them and the job was created for playlists (an ordinary download the user started is never paused by a playlist).
* Shared recording: A paused, B active → the job continues for B; A keeps its link and receives the verified result too (no re-download later).
* Pause survives relaunch and is never resumed automatically. Continue clears it, resumes paused jobs and lets the scheduler fill slots under current network/concurrency/resource policy.
* Completed tracks, decisions, occurrences and retry state are untouched by Pause.
* Jobs paused manually on the Downloads tab stay paused (user intent) unless the user continues the playlist.

## 7. Network policy

Enforced only by `DownloadManager`; no migration-specific bypass. Wi-Fi-only → jobs wait as "Waiting for Wi-Fi" and start when Wi-Fi returns. Enabling Wi-Fi-only mid-transfer stops unrestricted transfers (state preserved) and they restart over Wi-Fi. A connection loss preserves queued work. Cellular allowed → transfers proceed under the same quality, concurrency and resource policies.

## 8. Concurrency

The only limit is `YouTubePreferences.simultaneous` through `ResourcePolicy.downloadLimit(_:)`, counted across ordinary and playlist jobs (app workers plus system tasks). Raising it fills slots immediately; lowering it lets running transfers finish and starts nothing above the new limit. No hardcoded value.

## 9. Validation, import and association

Staging → HTTP/response validation (`DownloadMedia.validate(response:bytes:)`) → audio validation (`DownloadMedia.validate(_:)`: ftyp, audio-only, AAC/AC-3, decodable) → `StorageCoordinator.importAudio` (SHA-256, duplicate resolution, journal) → `associateAcquiredTrack`: decode + SHA-256 once per track **outside** the write transaction, then one transaction that requires, per occurrence, that the exact accepted YouTube candidate is still accepted and the entry is still `matched` with no local track. Otherwise `.stale` — the audio stays in the library, the occurrence is untouched.

* Download OK but association fails → the track is kept, the link is `associating` and the next pass retries without downloading.
* Verification fails → never imported, entry stays `matched`, decision preserved, one automatic retry, then "Download failed" with Retry.
* A crash between import and association is recovered on launch from the completed job's `trackID`.

## 10. Source eligibility

Matching confidence is not downloadability. `DownloadMedia.permits` is unchanged. Resolver/stream errors are classified: unavailable, region/access restricted, consent/sign-in, no audio-only or no compatible stream, invalid ID → **Unsupported source** (no automatic retry, decision kept, Import Audio from Files offered). No DRM or access-control circumvention, no paid APIs or credentials.

## 11. Failure handling

| Category | Examples | Automatic handling |
|---|---|---|
| Network / waiting for connection | connection lost, timeout | DownloadManager requeues on reconnect/foreground; coordinator up to 3 backoff retries for failed jobs |
| Waiting for Wi-Fi | Wi-Fi-only on cellular | waits; never fails |
| Remote rejected / stream expired | 401/403/410, rate limited, extraction | one fresh resolution (DownloadManager), then up to 3 backoff retries (30 s, 60 s, 120 s) |
| Verification failed | corrupt/truncated payload | 1 retry, then Retry button |
| Insufficient storage / import failed | disk errors | up to 3 retries, then Retry |
| Unsupported / unavailable / restricted / too large | see §10 | none; Import Audio from Files |
| User paused / cancelled | Pause, Downloads-tab Cancel | none; Continue / Retry |

One failure never blocks the queue; the playlist and every occurrence remain intact; the dashboard shows the real breakdown.

## 12. Recovery algorithm (every launch, idempotent)

1. Storage opens; existing recovery runs (import journal, file operations, migration `recover()`).
2. `DownloadManager` loads jobs, resets app-worker states without a system task, enumerates background sessions, keeps matching tasks, promotes completed staged files, requeues the rest.
3. The coordinator starts and runs a pass: loads links, controls and decisions; removes stale links; creates missing links; reuses jobs by identity (never re-acquiring completed audio); restores `associating` links; preserves user pauses; requests scheduling.
4. Notification state is reconciled (below).

Repeated launches create no jobs, files, links or memberships (covered by tests).

## 13. Notifications

`UNUserNotificationCenter`, through `PlaylistAcquisitionNotifying` (mocked in tests). Revised in the device hotfix (§20): two notification types, durable confirmed-download batches, and delivery outcomes that record only real scheduling.

* **Playlist Ready Offline**: only when every imported occurrence of the playlist is associated with present managed audio (`MigrationLocalAudio`), after the association itself decoded and hashed the file. Example: "All 200 songs in “My Spotify Favorites” are available offline."
* **Confirmed Downloads Complete / Finished**: once per confirmed-download batch (§20).
* Only playlists that Phase 10.5 acquired for are considered (no surprise notification after upgrading with an already-complete playlist).
* If the playlist later becomes incomplete (audio removed), the ready state is cleared so a later, legitimate completion notifies again.
* Permission is requested once, when the first playlist job is created, and only while undetermined. Denied permission never affects downloads.
* Tapping a notification opens the playlist.
* A notification can only be posted when iOS runs the app; after a force quit it is reconciled on the next launch, without duplication.

## 14. Manual local-audio fallback

Occurrence inspector and Download Queue → **Import Audio from Files** → Files picker (`.audio` + `.m4a`; supported: MP3, M4A, AAC, WAV, AIFF, CAF) → normal `StorageCoordinator.importAudio` (validation, SHA-256, dedupe) → imported metadata shown next to the Spotify metadata → explicit "Is this the intended recording?" confirmation → `confirmImportedRecording`: verifies the audio, records an accepted `local` candidate, returns the previous accepted YouTube selection to `pending` with `supersededBy=local-file` (evidence kept, never silently rejected), and marks the existing occurrence `ready`. No new occurrence is created. A file imported but not confirmed stays in the library.

## 15. UI

Imported playlist dashboard: **Offline Downloads** section with headline, progress bar (available offline / total), live breakdown (downloading, queued, waiting for Wi-Fi, verifying, paused; failed, unsupported, awaiting a confirmed match), outlined lime **Pause Downloads / Continue Downloads**, **View Queue**, **Retry Failed**. Per-row status in the playlist list. Download Queue screen grouped into Downloading / Waiting / Needs Attention / Available Offline with per-song progress, Retry and Import Audio from Files. Pure-black background and existing outlined button styles; no navigation or mini-player changes.

## 16. Tests

New deterministic suites (fake transfer gate, fake resolver, recording notifier, fake background execution, simulated relaunch over the same SQLite store; no live YouTube):

* `PlaylistAcquisitionTests` — auto-enqueue of confirmed songs, unconfirmed never resolved, order/identity/metadata preserved, duplicate occurrences and playlists share one job/file, idempotent reconciliation and relaunch, active and completed job reuse without restart, failure isolation (unsupported + recoverable with bounded retry), decision preserved on failure, orphaned download stopped and stale completion rejected.
* `PlaylistAcquisitionSchedulingTests` — global limit across ordinary + playlist downloads at 1/2/3, dynamic increase and decrease, durable Pause across relaunch and Continue, shared download continues for an active playlist and pauses when no consumer remains, Wi-Fi-only/cellular/stricter-policy/network loss, background session event fills a freed slot within a bounded window.
* `PlaylistAcquisitionRecoveryTests` — interrupted process reconciled, repeated launches idempotent, imported-but-unassociated track recovered without download, corrupt audio never ready with bounded retry then explicit Retry, SHA-256 dedupe across identities, one accurate ready notification, partial notification, no duplicates after relaunch, denied permission, Files import completes the playlist and triggers its notification.

They run in `playlist-migration.yml` (new step; `acquisition_only` dispatch input for a fast focused run) and in the complete `ci.yml` unit shard. They cannot run on Windows; results come only from GitHub Actions macOS runners.

Coverage map to the requested list: 1–7 → `PlaylistAcquisitionTests`; 8–13, 25, 34–38 → scheduling suite; 14–20, 28–33, 39–43 → recovery suite and `PlaylistAcquisitionTests`; 21–24, 26–27 → `PlaylistAcquisitionTests`. Not covered by automation: real background URLSession behaviour on a device, lock screen, force quit, real notification banners — these are physical acceptance items.

UI tests: automatic acquisition is **off** in UI-test launches unless `--automatic-acquisition` is passed, so historical XCUITest suites keep their exact download-free behaviour.

## 17. Physical acceptance checklist (iPhone 13 Pro Max, SideStore)

Use an unsigned IPA from **Build unsigned IPA** on this branch. Mark each PASS/FAIL.

| # | Procedure | Pass condition | Result |
|---|---|---|---|
| P0 | Install over the previous build, launch | App opens; library, playlists and playback state intact | |
| P1 | Confirm several songs in Review Songs | They appear as Queued/Downloading without pressing Download | |
| P2 | Settings: 3 simultaneous, confirm ≥ 5 songs | Never more than 3 "Downloading" (Downloads tab) | |
| P3 | Change to 1 while downloading | Running ones finish; then one at a time | |
| P4 | Start downloads, switch to Safari for a few minutes | Bytes advanced / songs finished on return | |
| P5 | Lock the phone for a few minutes | Same as P4 | |
| P6 | Pause Downloads | Active transfers stop; no new ones start | |
| P7 | Continue Downloads | Acquisition resumes | |
| P8 | Swipe to home, reopen normally | Outstanding work restored, no duplicates | |
| P9 | Force quit mid-download, reopen manually | Queue recovers and resumes (iOS will not continue while force-quit) | |
| P10 | Wi-Fi-only on, Wi-Fi off, cellular on | "Waiting for Wi-Fi"; no cellular data used | |
| P11 | Wi-Fi-only off on cellular | Downloads proceed | |
| P12 | Two playlists with the same confirmed song | One Downloads row ("For A, B"); one library file | |
| P13 | Airplane mode | Newly downloaded songs play, seek, finish | |
| P14 | Compare with Spotify order | All positions unchanged, duplicates kept | |
| P15 | A failing/unsupported song | Others continue; it shows the real reason | |
| P16 | Import Audio from Files for it (MP3/M4A) | Confirm dialog; song becomes available in place | |
| P17 | Complete a playlist with notifications allowed | One "Playlist Ready Offline" notification; tap opens playlist; not repeated after relaunch | |
| P18 | Playback regression | Play, shuffle, repeat, seek, Bluetooth and lock-screen controls | |
| P19 | Ordinary download from Search | Still downloads and plays | |

## 18. Known limitations

* Background progress depends on iOS scheduling; transfers created while backgrounded may be deferred; app-side work (verification, association, next slot) waits for an execution opportunity.
* Force quit stops transfers until the next manual launch.
* Partial transfers restart from zero on retry or after relaunch (no resume data is persisted, by Phase 7.1 design — resume blobs can carry expiring credentials).
* The YouTube resolver is the only acquisition provider; Invidious/SearXNG results are matching evidence and acquire through the same YouTube identity only.
* "Ready" relies on the verification performed at association (decode + SHA-256) plus presence/size checks afterwards; later silent corruption is detected by the existing library reconciliation, not continuously.
* A song whose library track was deliberately deleted becomes "Local audio unavailable" and is not re-downloaded automatically.
* Automatic retries are timer-based only while the app runs; pending retries resume on the next launch or wake.

## 19. Changed-file manifest

New:
* `OFFLINE/PlaylistMigration/Acquisition/AcquisitionSchema.swift` — v016 migration.
* `OFFLINE/PlaylistMigration/Acquisition/AcquisitionModels.swift` — records, states, failure classification, display/summary models.
* `OFFLINE/PlaylistMigration/Acquisition/PlaylistAcquisitionRepository.swift` — plan read, link/control persistence.
* `OFFLINE/PlaylistMigration/Acquisition/PlaylistAcquisitionCoordinator.swift` — orchestration.
* `OFFLINE/PlaylistMigration/Acquisition/AcquisitionNotifications.swift` — notifier protocol + `UNUserNotificationCenter` implementation, bounded background execution.
* `OFFLINE/Features/Library/PlaylistAcquisitionViews.swift` — dashboard controls, queue, per-song status, Files import, notification destination.
* `Tests/Unit/PlaylistMigration/PlaylistAcquisitionSupport.swift`, `Tests/Unit/PlaylistMigration/PlaylistAcquisitionTests.swift`.
* `Docs/PHASE_10_05_AUDIO_INTEGRATION.md`.

Modified:
* `OFFLINE/Storage/DatabaseManager.swift` — registers v016.
* `OFFLINE/PlaylistMigration/GRDBPlaylistMigrationRepository.swift` — appended `associateAcquiredTrack` and `confirmImportedRecording` (existing methods unchanged).
* `OFFLINE/Downloads/DownloadManager.swift` — `acquisitionJob(for:quality:)`, bounded background opportunity, `continueInBackgroundIfPossible()`.
* `OFFLINE/App/AppContainer.swift`, `AppBootstrap.swift`, `AppCoordinator.swift`, `OFFLINE/Features/Root/RootView.swift` — lifecycle wiring, notification routing.
* `OFFLINE/Features/Library/MigrationPlaylistViews.swift`, `OFFLINE/Features/Downloads/DownloadsView.swift` — status, controls, playlist context.
* `Tests/Unit/PlaylistMigration/PlaylistMigrationPersistenceTests.swift`, `HybridPlaylistTests.swift` — schema count 15 → 16.
* `.github/workflows/playlist-migration.yml` — acquisition step and `acquisition_only` input.

## 20. Device acceptance hotfix (iPhone 13 Pro Max, build `b549926`)

Three defects were reported from physical testing. Each root cause below was established by tracing the code, and each fix has a deterministic test that reproduces the failing sequence. Behaviour that depends on iOS scheduling is listed separately; simulator tests cannot prove it.

### Issue 1: force-quit recovery order and delayed offline availability

**Proven root cause A (ordering).** After a force quit, iOS cancels the app's background transfers. On relaunch it reports them through `urlSession(_:task:didCompleteWithError:)` with `NSURLErrorCancelled` and `NSURLErrorBackgroundTaskCancelledReasonKey`. The delegate mapped every error to `.connection`, so `backgroundEnded` marked those jobs (songs 2–4) `.interrupted`. Interrupted jobs are not scheduled again until the network returns or the app comes to the foreground. Meanwhile the same callback called `schedule()`, which gave the freed slots to songs 5–7. That is why newer songs started first and the interrupted ones only resumed later.

*Fix:* `DownloadFailure.background(_:)` classifies a system cancellation that carries a background-cancel reason as `.terminated`. `backgroundEnded(.terminated)` clears the system task and requeues the job at its original queue position. `schedule()` iterates in position order (the user's queue order), so songs 2–4 restart before 5–7. App-initiated cancels (Pause, Wi-Fi-only enforcement) carry no reason key and belong to an already-cleared generation, so they are unaffected. Late callbacks from superseded generations are still ignored (`SystemDownload.belongs`).

**Proven root cause B (delayed availability).** A finished background transfer is staged, then an app worker verifies and imports it. That worker counted as a transfer slot, and staged jobs competed in position order with ordinary pending jobs. With songs 2–4 requeued ahead of them and the limit at 3, the freed slots went to 2–4's transfers. Songs 5–7, already downloaded, waited unverified until those transfers finished, so all six appeared at once.

*Fix:* verifying staged audio uses no network, so it now has its own capacity (`DownloadManager.verificationLimit = 2`) separate from transfer slots. `transferSlotsInUse` counts only workers that are resolving or transferring, plus system transfers without a worker, and each job counts once. A completed recording is now verified, imported and associated immediately while other songs keep transferring. Nothing is marked ready before verification: association still decodes and SHA-256-hashes the audio outside the write transaction.

The coordinator also stopped evaluating notifications for every playlist on every pass. Only playlists whose links changed are evaluated, so a full scan of unrelated playlists can no longer delay the next association.

Traced transitions: `downloading → (terminated) queued at original position → resolving → downloading → staged → verifying (own capacity) → importing → completed → associating → ready → GRDB observation → MusicLibraryService snapshot`. The stall was at `staged → verifying`.

### Issue 2: uneven concurrency

**Proven root cause.** `YouTubeKitAudioResolver` serializes every resolution through one task chain. This is deliberate, because YouTubeKit shares a process-wide JS cache. But the serialized section also contained the anonymous metadata authorization check and the HEAD readiness probe, which can include two 2-second back-offs. Three eligible songs therefore started transferring one full resolution apart: one starts, the other two follow seconds later.

*Fix:* only the YouTubeKit calls remain serialized. The authorization check runs before the serialized section and the readiness probe after it, each with its own 45-second bound. The extraction's bound now starts when it runs, not while it waits in the queue. Error mapping is unchanged.

**Legitimate limiter (not a defect).** `ResourcePolicy.downloadLimit` caps transfers at 1 in Low Power Mode or when the thermal state is above nominal. This Phase 9 policy is unchanged and covered by `ReleaseReliabilityTests`. The playlist screen now says "Low Power Mode or device temperature limits downloads to one at a time" when it applies.

**Diagnostics.** The scheduler logs one line per distinct decision under subsystem `com.th07.muzikbelesh`, category `DownloadScheduler`. Each line records:

* configured and effective limits;
* Low Power and resource-limited flags;
* app transfer workers, verifying workers and background transfers;
* eligible pending jobs;
* why the first job did not start: `waiting for Wi-Fi`, `no network`, `no free transfer slot`, `verification capacity`, `reconciling background transfers`, `suspended, waiting for iOS execution` or `resource policy defers new work`.

The UI distinguishes these per-song states:

* preparing (stream resolution);
* waiting for Wi-Fi or for a connection;
* queued (no free slot);
* waiting for iOS to start the transfer (a background task with no bytes yet);
* downloading (bytes arriving);
* verifying;
* paused;
* waiting for the device to cool.

### Issue 3: notification after all confirmed recordings finish

**Proven defect.** `reconcileNotifications()` ignored the result of `deliver(...)` and always persisted `readyNotifiedAt`, so a denied or failed notification was recorded as handled. Separately, only full-playlist completion produced a notification, so 16 confirmed songs in a 200-song playlist never produced one.

**Design (v017, additive).**

* **Schema.** New columns: `migration_acquisitions.batch`, and on `migration_acquisition_controls`: `currentBatch`, `batchUpdatedAt`, `resolvedBatch`, `batchOutcome`, `readyOutcome`. Existing rows join batch 0. An existing `readyNotifiedAt` becomes `readyOutcome = delivered`.
* **Batches.** A batch is the set of occurrences confirmed (or retried) while the playlist's current batch is unresolved. Confirmations made during downloads, or shortly after the last download finished, join it. Once a batch's completion is handled, the next confirmation starts batch N+1.
* **Completion.** A batch completes when every member is ready, failed or unsupported; none is downloading, verifying or associating; the playlist is not paused; and no confirmation has joined it for the quiet period (30 s in the app). It is reported once:
  * **Confirmed Downloads Complete**: "All 16 confirmed songs in “X” are available offline. 184 songs still need attention."
  * **Confirmed Downloads Finished** (some failed): "14 of 16 confirmed songs in “X” are available offline. 2 could not be downloaded. 186 songs still need attention."

  Neither message claims the whole playlist is offline.
* **Playlist Ready Offline** still requires every occurrence. Sending it also concludes the current batch, so no second notification follows.
* **Delivery outcomes.**
  * `delivered`: only after `UNUserNotificationCenter.add` succeeds. Only then is `readyNotifiedAt` set.
  * `notPermitted`: the user denied notifications. Recorded as handled, never retried, never marked delivered.
  * `failed`: a scheduling error, or permission not yet decided. Re-evaluated after the quiet period, at most 3 attempts per launch.
* State survives relaunch and nothing is sent twice. A shared recording counts once per occurrence in each playlist's batch.

### Tests added (deterministic, no live YouTube)

`PlaylistAcquisitionDeviceRecoveryTests` uses background-URLSession mode with a gated session inventory:

* a force-quit cancellation is classified as termination; app-initiated cancels are not;
* three interrupted songs restart before newer ones, within the limit;
* a stale-generation callback is ignored, and no stale reservation holds a slot;
* every song becomes available offline as it completes, in any order;
* repeated relaunches create no jobs, files or transfers;
* a completed transfer is verified and associated without waiting for a transfer slot, and availability is checked in the database;
* out-of-order completions associate independently while other transfers continue;
* limits 1, 2 and 3 are filled promptly, each transfer is counted once, and a freed slot is refilled.

`PlaylistAcquisitionNotificationTests`:

* 16 confirmed songs in a 200-song playlist give exactly one confirmed-downloads notification, not repeated after relaunch;
* confirmations during a batch join it, and a later confirmation sends exactly one more;
* 200 verified occurrences send only Playlist Ready Offline;
* denied permission records no delivered marker and is not retried;
* transient failures get bounded retries, then deliver;
* failed recordings produce an accurate partial report;
* a Files import that completes the playlist sends the ready notification once.

Schema-count assertions are updated for v017 (17 migrations). The superseded partial-notification test was replaced by the batch tests; its Files-import assertions are kept in `testFilesImportCompletesThePlaylistAndSendsTheReadyNotification`.

### Still dependent on iOS (not provable in the simulator)

* Whether and when iOS delivers the force-quit cancellation callbacks, and whether a relaunched session enumerates tasks. Both orders are handled (callback before or after reconciliation).
* Transfers created while the app is in the background may be treated as discretionary and delayed. The UI shows "Waiting for iOS to start the transfer" until bytes arrive.
* After a force quit nothing runs until the user opens the app. Notifications for work finished before the quit are reconciled at that launch.
* Low Power Mode and thermal state legitimately reduce concurrency to one.
* YouTubeKit extraction remains serialized, and its duration depends on YouTube's responses.
* Batch notifications wait for the 30-second quiet period and need app execution time. If iOS suspends the app first, the notification is sent at the next opportunity.

### Hotfix file manifest

* `OFFLINE/Downloads/`: `DownloadManager.swift`, `TransferService.swift`, `BackgroundTransfers.swift`
* `OFFLINE/YouTube/YouTubeKitAudioResolver.swift`
* `OFFLINE/PlaylistMigration/Acquisition/`: `AcquisitionSchema.swift` (v017), `AcquisitionModels.swift`, `AcquisitionNotifications.swift`, `PlaylistAcquisitionCoordinator.swift`, `PlaylistAcquisitionRepository.swift`
* `OFFLINE/Features/Library/PlaylistAcquisitionViews.swift`
* Tests: `PlaylistAcquisitionDeviceTests.swift` (new), `PlaylistAcquisitionSupport.swift`, `PlaylistAcquisitionTests.swift`, and the schema-count suites
* `.github/workflows/playlist-migration.yml`
