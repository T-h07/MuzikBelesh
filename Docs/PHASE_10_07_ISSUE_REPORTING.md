# Phase 10.7 — Error Reporting, Missing Songs and User Notifications

Branch: `feature/phase-10-07-issue-reporting` (built on the accepted Phase 10.6 merge `f2c448d`).

**Principle.** An error is a persistent, classified state attached to one exact source
occurrence — not a message on screen. The UI reflects authoritative migration state; it
never invents or clears issues on its own.

## 1. Existing architecture audit

| Area | Already functional before 10.7 | Gap closed by 10.7 |
|---|---|---|
| Issue persistence | `migration_issues` (v013), `PlaylistMigrationIssue`, `saveIssue`, `resolveIssue`. Used only for one reusable `matching-attempt` row per occurrence, with free-text messages. | Structured category/stage/provenance, one open record per occurrence **and stage**, supersede/resolve history, coverage of every unresolved occurrence. |
| Matching resolution | Candidate review (`MigrationCandidateInspection`, review queue), manual YouTube link, Retry This Song, Retry failed matching, `confirmLocalRecording`, rejected-candidate history. | Reached from one place (Migration Issues); "Choose Other Recording" for an accepted-but-failed download uses the existing `rejectCandidate` path. |
| Acquisition recovery | Shared jobs, failure classification (`AcquisitionFailureCategory`), Retry / Retry Failed, unsupported handling, `AcquisitionLocalImportView`, `confirmImportedRecording`, batch + Ready notifications. | Bulk retry of only `.failed` links (`retry(entryIDs:)`); precise per-song explanation from the job's typed error text. |
| Coordinator | Lifecycle, retries/cooldowns, pause/resume/cancel, derived progress (`completedWithIssues`). | `retryEntries` for an exact eligible set through the same scheduler. |
| Skip | `.skipped` existed in the entry state machine, but **no write path** used it. | Explicit, durable Skip/Restore transitions. |
| Notifications | `UserNotificationAcquisitionNotifier` (single delegate), ready + batch ledger in `migration_acquisition_controls`. Ready only for playlists that downloaded something. | Aggregate "Needs Attention" and full-ready events per processing cycle; tap routing to Migration Issues. |

Reused without duplication: `GRDBPlaylistMigrationRepository` (decisions, verified
association, imports), `PlaylistMigrationCoordinator` (matching retries, cooldowns, pause,
cancel), `PlaylistAcquisitionCoordinator` + `DownloadManager` (download retries, consumer
accounting, verification), `ResolveMigrationPlaceholderView`, `AcquisitionLocalImportView`,
`MigrationCandidateInspection`, `ManualYouTubeSelectionView`, `MatchingSafeText`,
`MigrationPersistentText`, `CoordinatorDiagnostics`, the notification delegate.

## 2. Files added and modified

Added
- `OFFLINE/PlaylistMigration/Issues/MigrationIssueModels.swift` — categories, stages, provenance, actions, dispositions, filters, report rows.
- `OFFLINE/PlaylistMigration/Issues/MigrationIssueClassifier.swift` — pure classification from persisted facts.
- `OFFLINE/PlaylistMigration/Issues/MigrationCompletionSummary.swift` — outcome + counters.
- `OFFLINE/PlaylistMigration/Issues/MigrationIssueSchema.swift` — `v019_migration_issue_reporting`.
- `OFFLINE/PlaylistMigration/Issues/MigrationIssueRepository.swift` — atomic reconcile, cycles, ledger, Skip/Restore.
- `OFFLINE/PlaylistMigration/Issues/MigrationIssueCoordinator.swift` — observation, delegation, notifications.
- `OFFLINE/PlaylistMigration/Issues/MigrationIssueNotifications.swift` — notifier protocol, content, identifiers.
- `OFFLINE/Features/Library/MigrationIssuesView.swift`, `MigrationIssueDetailView.swift`, `MigrationCompletionSummaryView.swift`.
- Tests: `MigrationIssueClassifierTests`, `MigrationIssuePersistenceTests`, `MigrationIssueRecoveryTests`, `MigrationCompletionSummaryTests`, `MigrationIssueNotificationTests`, `MigrationIssueTestSupport`.

Modified (small, additive): `DatabaseManager` (register v019), `AppContainer` (wiring),
`AppCoordinator` (`.migrationIssues` sheet), `RootView` (tap routing, foreground
reconcile), `AcquisitionNotifications` (issues destination on the same delegate),
`PlaylistAcquisitionCoordinator` (`retry(entryIDs:)`), `PlaylistMigrationCoordinator`
(`retryEntries`), `MigrationPlaylistViews` (dashboard entry), `PlaylistAcquisitionViews`
(queue → issues link), workflow `playlist-migration.yml` (`issues_only`), schema-count
assertions (18 → 19).

## 3. Issue model and classification rules

Categories (`MigrationIssueCategory`) are chosen only from structured evidence:

| Evidence (exact persisted value) | Category | Disposition |
|---|---|---|
| checkpoint `noMatch`, status `unavailable` | `noReliableMatch` | failed |
| `needsReview` with ≥2 pending candidates (not `recommended`) | `ambiguousMatches` | needsReview |
| `needsReview` with 1 candidate or `recommended` | `needsConfirmation` (never "incorrect") | needsReview |
| `needsReview`, no pending, rejected exist | `allSuggestionsRejected` | failed |
| `pending` after matching settled (`completed`/`fatal`) | `notSearched` | failed |
| checkpoint `provider` / `discoveryFailed` | `temporaryProviderFailure` | waiting while a retry is scheduled, else failed |
| checkpoint `offline` | `networkUnavailable` | same |
| checkpoint `discoveryDeferred` | `rateLimited` (status only) | waiting |
| checkpoint `storageBusy` | `storageBusy` | same |
| checkpoint `interrupted`/`changedRecords` | `interruptedMatching` | same |
| checkpoint `metadata` | `unsupportedMetadata` (permanent) | failed |
| job error = `YouTubeError.regionRestricted` description | `regionRestricted` | failed |
| `accessRestricted` / `providerRestricted` / `redirectUnavailable` | `providerAccessRestricted` (a 403 is **not** regional) | failed |
| `requestTimeout` | `networkTimeout` | — |
| `rateLimited` | `rateLimited` (distinct from timeout) | — |
| `DownloadFailure.rejected`, `streamExpired` | `expiredStream` ("expired or was rejected") | — |
| `DownloadFailure.connection`/`terminated`, `networkUnavailable` | `interruptedDownload` (never permanent) | — |
| `DownloadFailure.invalid` | `audioValidationFailed` | — |
| `DownloadFailure.disk` with measured free space < job size | `insufficientStorage` | — |
| `DownloadFailure.disk` otherwise | `storageWriteFailed` (no capacity claim) | — |
| `"Audio could not be imported."` | `importFailure` | — |
| `noAudioStreams`/`noCompatibleAudio`/`invalidVideoID` | `unsupportedFormat` | — |
| `videoUnavailable` | `sourceUnavailable` | — |
| link `.failed`/`.unsupported` without a job error | mapped from the link's exact `AcquisitionFailureCategory.message` | — |
| `ready` row whose file is missing, or `unavailable` with an accepted local decision | `missingLocalAudio` | failed |
| migration cancelled with unprocessed songs | `migrationCancelled` | failed |
| anything else | `unknown`: "This song couldn't be processed. The exact cause wasn't recorded." | — |

Waiting conditions (queued, downloading, verifying, cooldown, scheduled retry, Wi-Fi/network
waits, paused by user, matching not started) are shown as status and **never** counted as
failures.

Each report row exposes: occurrence id, migration id, position, original metadata (read
from the immutable occurrence, not copied), category, severity (via disposition), stage,
explanation, retryable, automatic recovery, requires review, actions, retry count, next
retry, last attempt, and the persisted issue id / history count.

## 4. Error provenance mapping

`MigrationIssueProvenance`: `metadataImport` (metadata checkpoint), `localMatching`
(storage busy), `externalDiscovery` (no match, provider/network failures),
`userCandidateSelection` (all suggestions rejected), `downloadResolution` (unsupported,
restricted, expired), `networkTransfer` (interrupted, timeout, cancelled, too large),
`audioValidation`, `storageImport` (write/import/storage), `playlistAssociation` (missing
local audio), `migrationLifecycle` (cancelled). Stored in `migration_issues.provenance`.

## 5. SQLite migration and compatibility

`v019_migration_issue_reporting` (additive; `migration_issues` is **not** rebuilt):
- `ALTER TABLE migration_issues ADD COLUMN` category, stage, provenance, recoverable, lastObservedAt, closeReason (all nullable, CHECK-constrained).
- `migration_issues_open_report`: partial **unique** index `(entryID, code) WHERE resolution='open' AND code IN ('report.matching','report.acquisition','report.association')` — duplicates are impossible at the database level; legacy codes are unaffected.
- `migration_issues_code (migrationID, code, resolution)` for indexed per-playlist reads.
- `migration_report_state` (cycle counter, settled flag, outcome, observed batch, presented cycle).
- `migration_report_events` (notification ledger: `(migrationID, cycle)` PK, kind, revision, delivery, attempts, timestamps).

Existing open/resolved/dismissed rows keep their values (new columns NULL). Foreign keys
cascade with the migration. Schema-count tests updated to 19. Attempt counts and retry
deadlines remain only in `migration_entry_retries`, `migration_acquisitions` and `download_jobs`.

## 6. Issue lifecycle and deduplication

Identity = occurrence + stage (`report.matching` / `report.acquisition` / `report.association`).
Per reconciliation, inside **one write transaction** that also reads the facts:
- playable → open records closed `conditionCleared`;
- skipped → closed `skipped`;
- waiting → no record is created; an existing record stays open while its stage is retried; a record of an earlier stage is closed (`conditionCleared` for matching, `superseded` otherwise);
- needs review / failed → same stage + same category: kept (only updated if text/flags changed); different category: old closed `superseded`, new opened; other stages closed.

Records are never deleted. Closing a screen, a popup or the summary never touches them.
Because facts and writes share the transaction, a late callback from an older attempt
cannot reopen or resolve a newer outcome (T17). A run over unchanged state writes nothing (T12, T39).

## 7. Automatic reconciliation

`MigrationIssueCoordinator` observes `migration_entries`, `migration_candidates`,
`migration_matching_checkpoints`, `migration_entry_retries`, `migration_acquisitions`,
`migration_acquisition_controls`, `migration_matching_jobs`, `playlist_migrations` and
`download_jobs(state, errorMessage, trackID)` — never its own tables — debounced (750 ms),
plus launch, foreground return and after every user command. One indexed read per
migration; file checks once per distinct track. Coverage is derived from entry state, so
an unresolved song lacking an older issue row is still reported and persisted (T16).

## 8. Individual retry

`retry(occurrence)`: a download failure (`.failed` link) goes to
`PlaylistAcquisitionCoordinator.retry(entryID:)` (DownloadManager owns the job); a matching
failure goes to `PlaylistMigrationCoordinator.retryEntry` (explicit retry through the
Phase 10.6 scheduler). The reply says the retry was **queued**. A busy set blocks duplicate
submissions per occurrence. Pause is respected (the message says it starts on resume).

## 9. Bulk retry

`retryAllEligible(migrationID:)` re-reconciles, then queues only `failed` occurrences
offering Search Again or Retry Download: matching IDs via `retryEntries` (markRetryable →
explicit retry records → bounded slices, cooldowns, single worker) and download IDs via
`retry(entryIDs:)` (only `.failed`, never `.unsupported`). Rejected candidates stay
rejected; completed songs are untouched; cancelled migrations refuse. Result counts come
from the operations: "12 songs queued for retry. 6 still require manual review."

## 10. Manual candidate resolution

The detail screen embeds the existing `MigrationCandidateInspection` (confirm, "Not This
One", manual YouTube link). For an accepted recording whose download failed, "Choose Other
Recording" calls the existing `rejectCandidate` (accepted → rejected, occurrence back to
review); a new choice is then explicit, and acquisition's stale-link rules supersede the old
job safely. Nothing downloads before confirmation.

## 11. Local audio association and import

"Use Song From Library" opens `ResolveMigrationPlaceholderView` (→ `confirmLocalRecording`,
decode + SHA-256 verification, explicit confirmation). "Import Local Audio" opens
`AcquisitionLocalImportView` (Files picker → `importAudio` validation → side-by-side
metadata → explicit confirm → `confirmImportedRecording`). Positions and identities are
preserved; no manual playlist item is appended. For missing audio,
`releaseMissingLocalAudio` first returns the occurrence to review (refusing if the audio is
actually valid) so these existing paths accept it.

## 12. Skip behavior

`MigrationIssueRepository.skip` (confirmation dialog in the UI): validates the transition
(not `ready`, not in-flight `matching`), demotes an accepted decision to `pending` with
`supersededBy=skip` (kept as evidence), deletes only that occurrence's retry record, closes
its open records `skipped`, writes a durable `user.skip` audit record. Acquisition consumer
accounting then drops the link and pauses a job only when no other playlist needs it;
library tracks and files are never deleted (T24). `restore` (Undo) returns it to review or
unfinished matching with a `user.restore` audit record.

## 13. Completion-summary rules

`MigrationCompletionSummary` (original occurrences only — manual additions excluded):
`playable + unresolved + skipped == total`; unresolved = needsReview + failed + waiting.
Outcomes: `notStarted`, `inProgress`, `paused`, `cancelled`, `finishedWithIssues`
("Processing Finished — Needs Attention"), `fullyReady` ("Playlist Ready Offline").
`fullyReady` requires every occurrence present-and-verified, zero unresolved, zero skipped,
no remaining work; a `ready` row with a missing file is not playable (T29). A paused or
retry-pending migration is never "finished" (T28). Phase 10.6 `MigrationLifecycleState`
transitions are not altered. The dashboard shows the summary (highlighted once per cycle,
dismissal persisted in `presentedCycle` and never touching issues, retry state or lifecycle).

## 14. Notification types and deduplication

- `Playlist Ready Offline` — "All 500 songs in “X” are available offline." Sent by 10.7 only
  for playlists Phase 10.5 never downloaded for (otherwise 10.5's identical notification is
  the event and 10.7 records `coalesced`). Identifier `playlist-ready-<migration>` (shared).
- `Playlist Needs Attention` — "420 of 500 songs in “X” are available offline. 65 still
  need your review. 15 were skipped." Identifier `migration-attention-<migration>-<cycle>`.

A **processing cycle** ends when a migration goes from unsettled to settled (or from
settled-with-issues to fully ready). The first observation of an already-settled migration
(e.g. after upgrading) is a baseline: no notification. One ledger row per
`(migration, cycle)`; handled events are never replayed after restarts, foreground changes,
report views or duplicate observer callbacks; older undelivered events become `superseded`.
Batch overlap: if Phase 10.5's final confirmed-batch notification was delivered while this
cycle settled, the attention event is `coalesced`; while that batch is still pending it
waits up to 120 s. Transient failures retry with 30 s backoff, at most 3 attempts, then
`abandoned`; denied permission → `notPermitted` once, no loop.

## 15. Deep-link navigation

The same `UserNotificationAcquisitionNotifier` delegate adds `destination=issues` to the
userInfo of attention notifications; `didReceive` calls `onOpenIssues` (installed in
`MigrationIssueCoordinator.init`, during app initialization, so cold-launch taps work).
`RootView` presents `.migrationIssues(playlistID)` after waiting (bounded) for the library
snapshot; a deleted playlist is ignored. Ready notifications keep opening the playlist.

## 16. iOS notification limitations

`.delivered` means `UNUserNotificationCenter.add` accepted the request — not that the user
saw it. If the app dies after iOS accepted a request but before the ledger write, the next
launch re-adds the same identifier; iOS replaces it rather than stacking a second entry
(it may alert again). Authorization is requested once by acquisition when undetermined;
10.7 never prompts. Notifications are optional: reporting works without permission (T35).

## 17. Test results

Focused suites (workflow `playlist-migration.yml`, `issues_only=true`): see the
verification log below for exact counts and run URLs.

## 18. Physical-device acceptance checklist (iPhone 13 Pro Max, SideStore, unsigned IPA)

- P01 Install over the existing app: playlists, downloads, issue history and library audio intact.
- P02 Unmatchable songs appear in Migration Issues with "No reliable match".
- P03 Ambiguous song → Review → confirm → matching issue resolves; download starts.
- P04 Failed/unsupported download shows the real reason and only valid actions.
- P05 Retry one failed song; others unaffected.
- P06 Retry All Eligible Failures; rate limits, Pause and download limit respected.
- P07 Use Song From Library for an unresolved song; plays offline.
- P08 Import Local Audio from Files; source position unchanged.
- P09 Skip a song; it stays listed as skipped; Restore works.
- P10 Open/close Issues, force-quit, reopen: records and resolutions unchanged.
- P11 Mixed playlist: counts add up; not marked fully successful.
- P12 Let processing finish: one aggregate notification, no per-song spam.
- P13 Tap the attention notification: Migration Issues for that playlist opens.
- P14 500+ song playlist: Issues list stays responsive; actions work.
- P15 Playback, downloads, background recovery and matching still work.

## 19. Known limitations

- Free-space proof uses the volume's "important usage" capacity versus the job's known size;
  when the size is unknown, a disk write failure is reported without claiming the device is full.
- `DownloadFailure.rejected` covers both expired and rejected media links; the text says so.
- Choose Other Recording is offered for acquisition failures; for matching issues the
  candidate list already provides the alternatives.
- The legacy "All Songs by Status" and Download Queue screens remain; both link into the same
  data and Migration Issues is the single place with every recovery action.
- Historical `PlaylistFileImportUITests`/`ReviewQueueUITests` failures are not claimed fixed.

## 19a. Change Video for verified occurrences (staged replacement)

Before: "Change Video" on a song that was already `ready` called `rejectYouTubeSelection`,
which only accepts `matched` occurrences, so it always failed with `staleAttempt`.

Now (`v020_recording_replacements`, additive):
- `migration_replacements` holds one durable request per occurrence: the accepted decision
  and verified track being replaced, the staged candidate (decision `pending`, never
  accepted early), the video, the shared job link, state (`waiting`/`failed`), failure and
  bounded retries.
- `stageReplacement` (repository) requires the caller's current snapshot, a `ready`
  occurrence with present verified audio and a different video; staging again supersedes
  the earlier request (kept as evidence).
- `PlaylistAcquisitionCoordinator` acquires the replacement through the shared
  `DownloadManager` job for that video (reusing a completed or in-flight job), applies the
  acquisition retry policy, pauses with the playlist, and pauses a job created only for a
  cancelled/superseded request unless another consumer needs it.
- `commitReplacement` verifies the new audio (decode + SHA-256) outside the transaction,
  then in one transaction re-checks that the request, the occurrence (`ready`, original
  track) and the original decision are unchanged before switching: new track, new
  candidate accepted, previous candidate rejected with `replacedBy`, acquisition link
  updated, request deleted. Anything else is `stale` (request discarded, nothing switched).
- Failure or Cancel leaves the original recording associated and playable. Retry restarts
  the bounded budget. No track or file is deleted, so duplicates and other playlists that
  share the old recording keep it. The occurrence ID (playback identity), position and
  source metadata never change.
- Restarts: the request is SQLite state; DownloadManager restores the job and the next
  acquisition pass completes the switch once (Phase 10.6 recovery unchanged).
- Known limitation: a request cancelled while the app was not running does not pause a
  job it created on the next launch; that job may finish and its track stays in the library.

Tests: `RecordingReplacementTests` (success with the original playable throughout,
failure + cancel rollback, verification failure + explicit retry, restart, duplicate and
shared recordings, superseded/cancelled/stale completions).

## 19b. Ready songs behave like library songs; Remove from Playlist

Root cause: `MigrationPlaylistOccurrenceRow` wrapped every imported row in a
`NavigationLink` to the migration inspector (`MigrationOccurrenceDetailView`), whose
candidate section is always shown — regardless of whether the occurrence was already
ready with verified audio. Playback was only reachable through a small separate button.

Now the row's interaction follows the occurrence's real state (`row.playableTrack`, i.e.
`ready` + present, verified managed audio):
- Ready: tapping the row plays the occurrence; `•••` opens `SongOptionsView` (large
  artwork, title, artist, album · duration, Play/Pause, Play Next, Add to Queue, Add to
  Playlist, Change Video, Remove from Playlist, Delete Download, Delete from Library).
  Candidates are never shown; Change Video opens the existing staged-replacement flow
  (`RecordingReplacementControls`), so the original keeps playing until the new recording
  is verified.
- Unresolved / failed: tapping still opens the matching inspector (candidates, manual
  link, retry, Files import, recovery). A failed song is never playable.
- The same `SongOptionsView` is reachable from ordinary library rows ("Song Details") and
  from songs added manually to imported playlists.

Remove from Playlist always targets the occurrence:
- Ordinary playlists (set semantics): the membership; Undo reinserts at the old index.
- Songs added manually to imported playlists: that `playlist_local_occurrences` row;
  Undo restores the same identity and position.
- Imported occurrences (`v021_playlist_occurrence_removal`, additive columns on
  `migration_entries`, no new table): the row is kept (source positions, import history
  and diagnostics stay intact) but marked `removedAt`, its previous status/track are
  remembered for Undo, it becomes `skipped` without a local track, its retry bookkeeping
  and any staged replacement are dropped and its open issues are closed (`userAction`).
  Because every matching, acquisition, association and replacement guard already refuses
  `skipped` occurrences, retries, resumes, restarts and late callbacks cannot restore it;
  `entries()` hides removed rows, so rows, playback order, counts, progress, coordinator
  totals and issue summaries follow the new membership. Shared jobs keep running while
  another playlist needs them.
- No audio file, library track, other occurrence or other playlist is touched.

Delete Download vs Delete from Library: both use the existing journaled track deletion.
Delete Download is offered only for a downloaded (YouTube) recording that no ordinary
playlist or manual occurrence uses, so no playlist entry disappears; imported occurrences
stay as placeholders, reported as "Audio file missing" with **Download Again** (back to
`matched`, re-acquired through the shared queue). Delete from Library states exactly which
playlists and imported songs are affected before confirming.

## 19c. Clean playlist screen, Add Songs (library or YouTube links)

- The playlist screen shows artwork, title, "N songs", Play, Shuffle, Add Songs and the
  songs. Imported/manual/offline counters, the dashboard, Migration Issues, the completion
  banner and Cancel Migration moved to **Migration Details** (playlist `•••`, only for
  playlists with migration history). Everything there works as before; the migration runs
  regardless of whether the sheet is open. Per-song status lines remain on the rows.
- **Add Songs** offers *From Your Library* (existing multi-select; same audio, no
  download) and *From YouTube Links*: paste any number of links (multiline, Paste, Add
  Another, per-link remove), each parsed with `YouTubeURLValidator` (watch, youtu.be,
  music.youtube.com — newly accepted host —, Shorts, tracking parameters ignored), with
  invalid links explained and duplicates flagged (imported playlists can add a repeat as a
  separate occurrence; ordinary playlists keep one membership per song and report it).
- `v022_playlist_link_downloads` (additive table): one row per accepted link with its
  submitted order and slot. Rows are playlist entries immediately (counted, listed after
  the songs with status, Retry and Remove). `PlaylistAcquisitionCoordinator` acquires each
  through the shared `DownloadManager` job for that video (reused if it exists or already
  completed; global concurrency, Wi-Fi-only, background transfers and launch recovery
  unchanged). When the verified track exists, `completeLink` turns the row into an
  ordinary membership (ordinary playlists, at the submitted position) or a manual
  occurrence (imported playlists, at the reserved position) in one transaction; removed
  rows and repeated callbacks are no-ops. One failure never blocks the batch; failed rows
  keep their reason with Retry (bounded automatic retries first). Removing a pending row
  pauses a job only it needed. Spotify source entries are never inflated by additions.

## 19d. Playlist search (a filtered view, never a new queue)

- Every playlist shows a search field below the header and playback controls. It filters
  that playlist only (imported entries, songs added from the library, YouTube-link
  entries), by title and artist, case-, accent- and width-insensitive, immediately while
  typing, keeping the playlist's order and each row's occurrence identity. A clear button
  restores everything; an empty state appears when nothing matches. It never calls global
  search, YouTube or any remote service, and never changes membership or order (drag
  reordering of manual playlists is off while a filter is active).
- Playback is unchanged by search: a tapped result plays through the same full-playlist
  path as before — imported/hybrid playlists by exact occurrence ID over all playable
  occurrences, ordinary playlists with the full playlist as context — so playback continues
  with the rest of the original playlist; shuffle draws from the full playlist.
- Fixed while wiring this: selecting a song in an imported playlist used to switch shuffle
  off (`playMigration(… shuffle: false)` was the default). Selecting a song now leaves the
  shuffle setting alone (`shuffle: nil`); the Play and Shuffle buttons still set it.
- Tests: `PlaylistSearchTests` (S01–S13) and a UI test for filtering, empty state and clear.

## 20. Changed-file manifest

See section 2; `git diff --stat f2c448d..HEAD` on the feature branch is authoritative.

## Verification log

(Filled in after the focused CI run and IPA build.)
