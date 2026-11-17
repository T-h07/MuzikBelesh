# Phase 10.6 — Persistent Migration Coordinator and Automatic Recovery

Branch: `feature/phase-10-06-coordinator` (base: `develop` @ `4df61bb`, accepted Phase 10.5).
Status: implementation complete; focused native verification is recorded in §14.
**Not merged. Physical-device acceptance on the iPhone 13 Pro Max (§16) is required first.**

---

## 1. Architecture before and after

### Before (Phase 10.5)

| Concern | Owner | Gap |
|---|---|---|
| Matching lifecycle (start, resume, restore) | `PlaylistMatchingViewModel` (UI-layer object, app-scoped through `AppContainer`) | Restored only `jobs.first` by `updatedAt`, only on scene activation; one playlist ran to completion before another could start; no resume on network return; ignored thermal state |
| Provider restrictions (429, verification) | `PlaylistMigrationMatchingService`, per run, in memory | A cooldown was forgotten at the end of each run and at every launch, so a rate-limited provider was hit again immediately |
| Retries of failed searches | none (explicit "Retry failed" only) | No durable attempt count or deadline; restart lost nothing but also retried nothing |
| Cancellation | `cancel()` wrote intent `userCancelled` only | Session never became `cancelled`, so acquisition kept creating work for it |
| Acquisition, downloads, transfers | `PlaylistAcquisitionCoordinator`, `DownloadManager` | Already durable and idempotent (kept unchanged) |

### After (Phase 10.6)

```text
                         AppContainer (application lifetime)
                                       |
        storage ──> library ──> DownloadManager (+ background-transfer reconciliation)
                                       |
                          PlaylistAcquisitionCoordinator ──────────────┐
                                       |                               |
                       PlaylistMigrationCoordinator  (NEW)             |
        decides: what is eligible, which slice, which playlist next,  |
        retry deadlines, cooldowns, network/resource/background waits,|
        Pause/Resume/Cancel, recovery                                  |
                 |                         |                           |
   PlaylistMatchingViewModel        MigrationCoordinatorRepository     |
   (execution + presentation        (v018 tables, aggregate reads,     |
    adapter: one worker, one        atomic user commands)              |
    iOS execution grant)                   |                           |
                 |                         |                           |
   PlaylistMigrationMatchingService ──> GRDBPlaylistMigrationRepository (authoritative)
   (engine; now reads/writes durable provider cooldowns)               |
                                                                       v
                                                            DownloadManager (single owner of jobs/transfers)
```

SQLite is authoritative. Every in-memory structure in the coordinator is a cache or
per-process accounting; a restart is ordinary recovery.

## 2. Ownership model

* **`PlaylistMigrationCoordinator`** (`OFFLINE/PlaylistMigration/Coordination/PlaylistMigrationCoordinator.swift`,
  `@MainActor`, created once by `AppContainer`, destroyed only with it). It alone decides
  what matching work runs and when, and it is the single entry point for user lifecycle
  commands (start, pause, resume, cancel, retry). It never performs matching, downloads or
  association itself.
* **`PlaylistMatchingViewModel`** — execution and presentation adapter. When the coordinator
  is attached (`scheduler`), `restoreIfNeeded()` asks the coordinator for work and the worker
  loop runs consecutive slices (possibly of different playlists) under **one** iOS execution
  grant. Its pause, cancel and expiration semantics are unchanged. Without a scheduler
  (historical tests) it behaves exactly as before.
* **`PlaylistMigrationMatchingService`** — remains the matching engine. Additions only:
  optional durable cooldown store, Retry-After support, `lastClaimed`, `enabledProviderNames()`.
* **`PlaylistAcquisitionCoordinator`** — unchanged; still owns confirmed-recording
  acquisition, shared-job consumer accounting, retries of downloads and verified association.
  The coordinator calls its existing `pause`, `continueDownloads`, `retry`, `retryFailed`,
  `requestReconcile` and `reconcileNow`.
* **`DownloadManager`** — unchanged single owner of download jobs and transfers. It now
  publishes `networkPath` and `reconciling` (read-only) so the coordinator can observe
  connectivity and wait for transfer ownership at launch. No second download scheduler exists.
* **Repositories** — authoritative persistence. `MigrationCoordinatorRepository` writes only
  coordinator tables, plus existing intent/control rows inside the same transaction when a
  user command must change several atomically (Pause Playlist, Cancel).

There is exactly one place that resumes, cancels or retries a migration automatically.

## 3. State machine

### Migration level (`MigrationLifecycleState`, separate from `PlaylistMigrationStatus`)

| State | Meaning | Automatic recovery |
|---|---|---|
| `pending` | Imported, never scheduled | never (user starts) |
| `matching` | Executing, or queued for the single worker ("Waiting to match") | yes |
| `awaitingReview` | Matching done, suggestions need the user | waits for the user |
| `acquiring` | Confirmed recordings downloading/verifying/associating | yes (acquisition) |
| `waitingForNetwork` | No connectivity, or the engine detected it (60 s backoff) | on network return |
| `coolingDown` | Every usable provider restricted; resumes at the persisted deadline | after the deadline |
| `systemSuspended` | No iOS execution opportunity (background, expired grant, relaunch) | on activation |
| `resourceDeferred` | Thermal state serious/critical | when the policy permits |
| `userPaused` | Explicit Pause | **never** |
| `cancelling` / `cancelled` | Cancellation in progress / persisted | **never** |
| `completed` | Every occurrence has verified, present local audio | never restarts |
| `completedWithIssues` | Eligible work finished; some songs need attention | explicit action |
| `failed` | Storage could not commit safely (`fatal` intent) | explicit Retry only |

The state is derived by a pure function (`PlaylistMigrationCoordinator.derive`) from
authoritative rows plus live conditions, and the derived value is persisted in
`migration_coordinator_state.state` whenever it changes. The durable execution *intent*
remains `migration_matching_jobs.intent` (`running`, `systemPaused`, `userPaused`,
`userCancelled`, `completed`, `fatal`); no existing enum or CHECK constraint changed.

Key transitions: start → `matching`; slice finished → `matching` (more) / pass end →
`coolingDown` | `matching` (bounded extra pass) | settled; engine offline → `waitingForNetwork`;
expiration → `systemSuspended`; Pause → `userPaused`; Resume → re-derived; Cancel →
`cancelling` → `cancelled`.

### Entry level (derived, never duplicated)

| Stage | Source of truth |
|---|---|
| Source metadata imported | `migration_entries` (status `pending`) |
| Local matching pending / in flight | `pending` / `matching` |
| Local matching complete, discovery pending | checkpoint present; `discoveryDeferred` |
| Candidates awaiting review | `needsReview` + `migration_candidates` |
| Candidate explicitly confirmed | `matched` + exactly one `accepted` candidate |
| Download queued / in progress | `migration_acquisitions.waiting` + `download_jobs.state` |
| Verifying / importing | `download_jobs` `verifying`/`importing`, link `associating` |
| Verified track associated / ready offline | `ready` + `localTrackID` + present, verified file |
| Unsupported / permanently failed | link `unsupported`, `unavailable` (no match), retry row `eligible = 0` |
| Skipped / cancelled | `skipped`; session `cancelled` |
| Retry bookkeeping | `migration_entry_retries` |

Matched, confirmed, downloaded, verified and available offline stay distinct. A selected
YouTube candidate is not an offline recording. **No suggestion is ever approved
automatically**; only verified local matches (existing policy) or explicit confirmations
lead to acquisition.

## 4. SQLite schema changes

One additive migration, `v018_persistent_migration_coordinator`
(`OFFLINE/PlaylistMigration/Coordination/CoordinatorSchema.swift`), registered after v017.
No historical migration was edited.

* **`migration_coordinator_state`** (PK `migrationID` → `playlist_migrations` ON DELETE CASCADE):
  `state` (CHECK, frozen literal list), `generation` (execution lease token), `cursorPosition`
  (pass cursor, ≥ −1), `lastScheduledAt` (fairness after restart), `heartbeatAt`,
  `lastCheckpointAt`, `lastRecoveryAt`, `waitUntil` (cooldown/connectivity deadline),
  `interruptedBySystem`, `reason` (≤ 200), `errorCategory` (≤ 60), timestamps.
  Index `(state, lastScheduledAt)`.
* **`migration_entry_retries`** (PK `entryID` → `migration_entries` CASCADE, `migrationID` →
  `playlist_migrations` CASCADE): `failures`, `category`, `eligible`, `lastAttemptAt`,
  `nextRetryAt`. Index `(migrationID, eligible, nextRetryAt)`.
* **`migration_provider_cooldowns`** (PK `provider`): `expiresAt`, `probes`, `reason` (≤ 300).
* Index `migration_matching_checkpoints(outcome, retryable)` for the eligibility pre-filter.

**Reused, not duplicated:** `migration_matching_jobs` (intent), `migration_matching_checkpoints`
(matching checkpoint/version), `migration_entries` (positions, stage, verified track),
`migration_candidates` (selected candidate, rejection history), `migration_acquisitions`
(acquisition/download job link, verified track), `migration_acquisition_controls`
(download pause, notification state), `download_jobs` (transfers, generations).
Progress counters are never stored; they are aggregated from these rows.

Schema-count contracts (`Phase2StorageTests`, `Phase4LibraryMigrationTests`,
`HybridPlaylistTests`, `PlaylistImportIntegrationTests`, `PlaylistMigrationPersistenceTests`)
were updated from 17 to 18 migrations; nothing else in them changed.

## 5. Recovery sequence

`AppContainer` startup order: storage/database → library → `DownloadManager` (starts
background-transfer inventory reconciliation) → matching service and view model →
`PlaylistAcquisitionCoordinator.start()` → `PlaylistMigrationCoordinator.start()`:

1. Attach as the matching scheduler; honor a background launch (no new work).
2. Wait (bounded, 10 s) until `DownloadManager.reconciling` is false — recovery never races
   URLSession inventory restoration.
3. Subscribe to `DownloadManager.$networkPath` and `$resourcePolicy`; observe the
   migration/acquisition/job tables for status refreshes.
4. `restoreUnfinishedMigrations()` (idempotent; concurrent calls join one pass):
   * only when no worker exists in this process, `recoverAbandonedWork`: occurrences
     recorded `matching` become `pending`/`needsReview`, sessions recorded `matching` become
     `paused` with a bumped revision (an old lease can never commit), every open generation
     is closed and marked `interruptedBySystem`. OS-owned transfers are not touched.
   * request acquisition reconciliation (which reuses completed downloads and associates
     already imported tracks);
   * refresh status, start the single worker if eligible, schedule the deadline wake-up.

Recovery rules: `running`/`systemPaused` intent → resumes; `waitingForNetwork` → on
connectivity; `coolingDown` → after the persisted deadline; `resourceDeferred` → when the
policy permits; `userPaused`, `userCancelled`, `completed` → never; `awaitingReview` →
decisions preserved, waits; `fatal` → explicit Retry only.

`applicationDidBecomeActive` / `applicationDidEnterBackground` are called from `RootView`
(in addition to the existing `DownloadManager`/acquisition hooks, which are unchanged).

## 6. Concurrency strategy

* **Matching:** one global worker, one external discovery request at a time (unchanged
  engine guarantee, now also across playlists). No parallel searching was introduced.
* **Slices and fairness:** work is handed out in slices of 40 occurrences in source order
  after a durable pass cursor. Between slices the coordinator picks the least recently
  served playlist (monotonic in-process order, then persisted `lastScheduledAt`, then
  import order — never dictionary order). Due retries of a playlist run before its next
  ordinary slice. Healthy transfers are never interrupted for priority.
* **One execution grant:** consecutive slices run inside the worker loop under the same
  `MatchingBackgroundExecution` grant (`BGContinuedProcessingTask` or limited execution).
* **Downloads:** unchanged — the existing `DownloadManager` limit applies to ordinary and
  playlist-driven downloads together, reduced by the resource policy.
* **Bounded resources:** no per-song tasks; one aggregate SQL read per refresh; refreshes
  debounced (500 ms) and published only on change; slice selection and counts are indexed
  queries; no filesystem checks during row rendering (the existing snapshot path is used).

## 7. Retry policy

`MigrationRetryPolicy.standard`: delays 15 s, 60 s, 180 s (cap 600 s), ±10 % bounded jitter,
**3 automatic retries**. The initial attempt does **not** count: after failure *N* the
*N*-th retry is scheduled; after the fourth failure the row becomes `eligible = 0` and the
song needs an explicit Retry (which resets the budget). Attempt counts and `nextRetryAt`
are persisted; a restart never resets them and the original deadline is honored. A retry in
flight is leased (`nextRetryAt = now + 600 s`) so a crash during it is retried, never lost.

Failure categories (`MigrationFailureCategory`): network unavailable, timeout, rate
limited, provider temporary, provider restricted, unsupported recording, invalid metadata,
missing recording, verification failed, storage, user cancelled, background expired,
resource deferred, explicit retry. Temporary search failures (`discoveryFailed`, `provider`,
`storageBusy`, `changedRecords`) retry automatically; `noMatch` (missing recording) and
`metadata` (invalid metadata) never do. Connectivity loss is a *deferral*, not a failure, so
a 500-song migration never becomes 500 failures. Download retries keep the existing
Phase 10.5 acquisition policy.

## 8. Provider cooldown policy

* HTTP 429 and provider-wide restrictions escalate through the existing ladder (30 s, 120 s,
  300 s; then suspended, persisted for 900 s). A valid `retryAfter` on a discovery result is
  honored (bounded to one hour). Current providers do not expose the header, so the bounded
  ladder applies.
* Deadlines are persisted in `migration_provider_cooldowns` and loaded at the start of every
  run, for every migration and after restarts. A provider still restricted is not called;
  its songs finish local matching and are deferred. An independent healthy provider
  continues (T12).
* In durable mode a restriction longer than 30 s is never waited out while holding the
  worker; the migration enters `coolingDown` and resumes at the deadline.
* A successful search clears the cooldown. Verification/consent restrictions are never
  bypassed by repeated requests. Candidate history is untouched.

## 9. Background execution limitations

* Foreground: full scheduling.
* Limited background opportunity: slices continue only under the grant that started in the
  foreground (`BGContinuedProcessingTask` on iOS 26, otherwise `beginBackgroundTask`). No new
  worker is started from the background.
* Expiration: the worker is cancelled cooperatively, committed progress stays, the in-flight
  song becomes unfinished, intent `systemPaused`, state `systemSuspended`; background
  URLSession transfers stay with iOS.
* Suspended/terminated: nothing runs; timers do not fire. Deadlines are wall-clock values in
  SQLite and are evaluated on the next activation.
* Force-quit by the user: iOS does not relaunch the app for matching; work resumes only when
  the user opens the app again, automatically and from the saved state.

## 10. Pause / Resume / Cancel semantics

* **Pause Playlist** (`pauseMigration`): one transaction sets matching intent `userPaused`,
  acquisition `userPaused` and state `userPaused` *before* anything else; the worker stops
  cooperatively if this playlist is active; playlist-created downloads pause only when no
  other consumer needs them (existing consumer accounting). Other playlists continue.
  Survives restarts.
* **Resume Playlist**: clears both pauses, re-derives state, preserves cooldowns and retry
  deadlines, restarts the pass from the beginning (completed songs are skipped by the
  claim; nothing is reprocessed).
* **Cancel Migration** (`cancelMigration`, confirmation dialog): the worker stops; one
  transaction returns in-flight occurrences to unfinished, sets the session `cancelled`,
  intent `userCancelled`, state `cancelled` and removes retry rows. Acquisition then stops
  creating work for it and pauses only orphaned playlist-only jobs. The destination
  playlist, every occurrence, library tracks, audio files and already verified songs are
  preserved; a shared download another playlist needs continues (T22). Never resumes.
  Deleting the playlist remains a separate action.
* Existing "Pause Matching", "Resume Matching", "Pause/Continue Downloads", "Retry This
  Song" and "Retry Songs That Failed" buttons are kept and now route through the coordinator.

## 11. Crash recovery and idempotency guarantees

* Every logical change is one SQLite transaction (engine commits, Pause, Cancel, retry
  bookkeeping, recovery).
* Matching leases (session revision + entry snapshot) reject stale commits; recovery bumps
  the revision. Coordinator generations reject stale completion callbacks (`endRun` checks
  the generation inside the transaction; T26).
* Repeated or overlapping recovery converges: one worker, no duplicate jobs, entries,
  candidates, tracks, tasks or notifications (T02, T32).
* Audio imported before association is found and associated without downloading again
  (T04); completed recordings are reused (T03).
* Cancelled work is never resurrected; pass accounting guarantees no infinite recovery loop
  (each automatic pass must reduce eligible work, or the pass settles).

## 12. Performance considerations

* Overview: one SQL statement with correlated, indexed sub-counts per migration plus one
  state fetch; measured in T18 for 1,000 occurrences (10 refreshes bounded).
* Slice selection: `LIMIT`-bounded indexed query; claim remains the final authority.
* T18: one execution grant, ≤ 26 slices for 1,000 songs, coalesced refreshes, one
  provider request at a time. Large playlists keep the existing virtualized list and
  snapshot rows (no per-row database query or file check).

## 13. Logging and diagnostics

OSLog subsystem `com.th07.muzikbelesh`, category **`PlaylistMigrationCoordinator`**:
`migrationScheduled`, `migrationRestored`, `matchingJobClaimed`, `matchingJobCompleted`,
`retryScheduled`, `providerCooldownActivated`, `providerCooldownCleared`,
`networkWaitEntered`, `networkWaitCleared`, `resourceDeferralEntered`,
`resourceDeferralCleared`, `backgroundExecutionExpired`, `migrationPaused`,
`migrationResumed`, `migrationCancelled`, `acquisitionReconciliationRequested`,
`migrationCompleted`, and `recoveryConflict=staleCompletion`. Only identifiers, counts,
states and categories are logged; SQLite errors log result codes only. No credentials,
tokens, cookies, response bodies or URLs. Existing `PlaylistMatching`,
`PlaylistMatchingBackground`, `PlaylistAcquisition` and `DownloadScheduler` categories are
unchanged. A real deadlock shows `matchingJobClaimed` without `matchingJobCompleted` while
in the foreground; legitimate suspension shows `backgroundExecutionExpired` or
`systemSuspended`.

## 14. Test coverage and verification results

Suite: `Tests/Unit/PlaylistMigration/PlaylistMigrationCoordinatorTests.swift` (32 tests,
T01–T32) with `PlaylistMigrationCoordinatorSupport.swift` (controlled clock, scripted
providers with concurrency accounting, expirable execution grant, restart harness built on
the Phase 10.5 `AcquisitionHarness`). Workflow: `playlist-migration.yml`, new
`coordinator_only` input and the always-on "Phase 10.6 persistent migration coordinator"
step.

| Group | Tests |
|---|---|
| A. Persistence and recovery | T01 500-song restart · T02 overlapping recovery · T03 reuse · T04 association crash · T05 decisions |
| B. Networking and retries | T06 Wi-Fi loss · T07 restoration · T08 backoff · T09 retry persistence · T10 permanent · T11 429 · T12 multiple providers |
| C. Concurrency and resources | T13 matching limit · T14 download limit · T15 fairness · T16 Low Power · T17 thermal · T18 1,000 entries |
| D. User controls | T19 pause persistence · T20 isolation · T21 cancellation · T22 shared download · T23 resume |
| E. Background lifecycle | T24 expiration · T25 force quit · T26 stale callback · T27 deferred transfer · T28 no Pause/Continue |
| F. Library regressions | T29 library playback · T30 duplicates · T31 completion semantics · T32 repeated launches |

Verification results: see "Verification log" at the end of this document.

## 15. Known limitations

**iOS restrictions (not app defects):** no unlimited background execution; nothing runs
while suspended; force-quit stops all app-owned work until the next launch; background
URLSession transfers may be deferred by iOS (handled by Phase 10.5 recovery);
`BGContinuedProcessingTask` admission is at the system's discretion.

**Implementation limits:**
* New matching loops start only in the foreground; network return while suspended is
  handled on the next activation.
* Explicit retries do not run while a playlist's matching is user-paused (they run after
  Resume).
* Current discovery transports do not surface `Retry-After`; the bounded ladder is used.
* A pass that cannot progress automatically (e.g. every discovery source disabled) settles
  with songs remaining; the user resumes once a source is available.
* Matching continues serially in Low Power Mode (already the minimum); only downloads are
  reduced. Thermal *serious/critical* defers both.

## 16. Physical-device acceptance checklist (iPhone 13 Pro Max, SideStore, unsigned IPA)

| # | Test | Pass criteria |
|---|---|---|
| P01 | Import a real 500-song Exportify/Spotify playlist | 500 rows, original order, duplicates kept |
| P02 | Start matching, let ~50 finish, close and reopen | Progress resumes from ~50, not zero |
| P03 | Force-close during matching, reopen | Resumes automatically, no "Find Matching Songs" needed |
| P04 | Lock the phone during matching for a few minutes | On return, state is accurate; matching continues; no data lost |
| P05 | Confirm several songs, download, play offline, restart | Songs still offline and playable; no re-download |
| P06 | Disable Wi-Fi during matching/downloading, then enable | "Waiting for connection"; resumes by itself; Wi-Fi-only respected |
| P07 | Pause one playlist while another matches | Paused stays paused (also after restart); the other continues |
| P08 | Cancel a migration | Downloaded songs remain in the library and play; playlist kept; never resumes |
| P09 | Several downloads; background/foreground near the last one or two | Queue finishes without Pause → Continue |
| P10 | Restart repeatedly at different stages | No missing rows, duplicated jobs or changed selections |
| P11 | Enable Low Power Mode | One download at a time; status explains it |
| P12 | Final | No double downloads; offline audio stays; no paused playlist restarts; UI responsive; ordinary downloads unaffected |

Useful Console filter: subsystem `com.th07.muzikbelesh`, categories
`PlaylistMigrationCoordinator`, `PlaylistMatching`, `PlaylistAcquisition`, `DownloadScheduler`.

## 17. Changed-file manifest

New:
* `OFFLINE/PlaylistMigration/Coordination/PlaylistMigrationCoordinator.swift`
* `OFFLINE/PlaylistMigration/Coordination/CoordinatorRepository.swift`
* `OFFLINE/PlaylistMigration/Coordination/CoordinatorModels.swift`
* `OFFLINE/PlaylistMigration/Coordination/CoordinatorSchema.swift`
* `OFFLINE/Features/Library/MigrationCoordinatorViews.swift`
* `Tests/Unit/PlaylistMigration/PlaylistMigrationCoordinatorTests.swift`
* `Tests/Unit/PlaylistMigration/PlaylistMigrationCoordinatorSupport.swift`
* `Docs/PHASE_10_06_PERSISTENT_COORDINATOR.md`

Modified:
* `OFFLINE/PlaylistMigration/Matching/PlaylistMigrationMatchingService.swift` — durable cooldowns, Retry-After, `lastClaimed`, `enabledProviderNames()`
* `OFFLINE/PlaylistMigration/Matching/MatchingDiscovery.swift` — `retryAfter`, `inlineWaitLimit`, `suspendedCooldown`, `.durable`
* `OFFLINE/Features/Library/PlaylistMatchingViewModel.swift` — scheduler hook, multi-slice worker loop, `abandon()`; controls route through the coordinator
* `OFFLINE/Features/Library/MigrationPlaylistViews.swift`, `MigrationResolutionViews.swift` — coordinator status row and command routing
* `OFFLINE/Downloads/DownloadManager.swift` — published `networkPath`, `reconciling`
* `OFFLINE/App/AppContainer.swift` — coordinator construction and startup order
* `OFFLINE/Features/Root/RootView.swift` — lifecycle hooks
* `OFFLINE/Storage/DatabaseManager.swift` — registers v018
* `.github/workflows/playlist-migration.yml` — coordinator step and `coordinator_only`
* Schema-count tests: `Phase2StorageTests`, `Phase4LibraryMigrationTests`, `HybridPlaylistTests`, `PlaylistImportIntegrationTests`, `PlaylistMigrationPersistenceTests`

---

## Verification log

| Run | Commit | Scope | Result |
|---|---|---|---|
| [43770154710](https://github.com/T-h07/MuzikBelesh/actions/runs/43770154710) | `e68f437` | `coordinator_only` | Build passed. 166 tests: 164 passed, 2 failed (T01, T02 assertion errors, see below) |
| [43771744443](https://github.com/T-h07/MuzikBelesh/actions/runs/43771744443) | `ecf4596` | `coordinator_only` | **166 tests, 0 failures, 0 skipped** (`PlaylistMigrationCoordinatorTests` 32/32 in 128.7 s) |

Suites in the passing run: `PlaylistMigrationCoordinatorTests` plus `MatchingLifecycleTests`,
`MatchingPauseResumeTests`, `MatchingReliabilityTests`, `FinalDiscoveryReliabilityTests`,
`YouTubeDiscoveryReliabilityTests`, `MatchingIndependentSearchTests`, `PlaylistMatchingIntegrationTests`,
all six `PlaylistAcquisition*` suites, `BackgroundDownloadTests`, `DownloadTests`,
`PlaylistMigrationPersistenceTests`, `HybridPlaylistTests`, `Phase2StorageTests`,
`Phase4LibraryMigrationTests`, `PlaylistImportIntegrationTests`.

First-run failures were wrong test expectations, not coordinator defects. Songs searched after
confirmed downloads correctly also receive local-library suggestions (local-first matching), so
"exactly 2 suggestions" (T02) and "70 no-match songs" (T01) were invalid. The assertions now check
the actual invariants: no recording stored twice per occurrence, exactly 2 YouTube suggestions, and
empty searches never gaining a YouTube suggestion or a selection. No assertion about coordinator
behavior was weakened.

Not yet verified natively: the migration UI suites (`PlaylistMigrationUITests`, `ReviewQueueUITests`,
`PlaylistFileImportUITests`) and the remaining Phase 10.4 matching/import suites that only the
default focused run executes; the unsigned IPA build; physical-device acceptance.
