# Phase 10.9 — Integration, stress testing, reliability hardening and v1.1.0 candidate

Status markers used throughout: **PASS**, **FAIL**, **BLOCKED**, **NOT RUN**. Nothing below
is reported as passing unless it actually executed; physical-device rows stay **NOT RUN**
until the user reports results.

## 1. Objectives and scope

Validate Phases 10.0–10.7 (file-based Spotify playlist migration) as one system together
with the released v1.0.0 functionality, fix demonstrated defects, add release-gate tests,
and produce a traceable unsigned v1.1.0 candidate IPA for physical acceptance.

In scope: Exportify CSV, Spotify account-data JSON, ZIP; persistent occurrences; local and
external matching; acquisition, recovery, issue reporting; playlist editing, Change Video,
playlist search; the YouTube Share extension; the canceled Phase 10.8 test-IPA upgrade.

Out of scope (canceled Phase 10.8, not restored): Spotify OAuth/PKCE, client IDs, Web API,
account connection, playlist-URL API imports, tokens, Spotify Share-extension behavior.
`PlaylistMigrationSource.spotifyAPI` remains in the Phase 10.0 schema only for
compatibility. No schema migration is added in Phase 10.9.

Git: all work is on `feature/phase-10-09-release`, based on the Phase 10.7 merge
`c2be900` (+ `6faacb5`, the 10.8 inbox downgrade fix). `develop`, `main` and `release`
are untouched. No merge, tag or GitHub Release was made.

## 2. Architecture audit

| Subsystem | Entry points | Persistence boundary | Main risks | Existing coverage | Phase 10.9 action |
|---|---|---|---|---|---|
| Audio engine | `AudioPlayerService`, `PlaybackQueueManager`, `PlaybackNavigationEngine` | `playback_state`, `playback_queue_entries`, `playback_history` | interruption recovery, queue restore, shuffle history | `PlaybackServiceAuditTests`, `Phase4PlaybackTests`, `PlaybackPreviousPolicyTests`, `ReleaseReliabilityTests` | No change; rerun in final regression |
| Library | `LibraryRepository`, `MusicLibraryService`, `ManagedLibraryFiles`, `ImportExportService` | `tracks` (unique SHA-256), `playlist_tracks`, Music/Artwork dirs | file deletion, reconciliation, duplicate identity | Library suites, `LibraryDeletionTests`, `DuplicateDetectionTests` | Deletion sites audited (below); no change |
| YouTube | `YouTubeWebProvider`, `YouTubeKitAudioResolver`, `DownloadManager`, `TransferService` | `download_jobs`, staging `.m4a`/`.incoming` | stale staging cleanup, retry, Wi-Fi-only | `DownloadTests`, `BackgroundDownloadTests`, YouTube suites | No change; rerun |
| Share extension | `ShareViewController`, `SharedURLHandler`, `SharedLinkInbox` | App Group `PendingYouTubeLinks-v1.json` | 10.8 version-2 inbox | `SharedLinkInboxTests`, `ShareURLValidationTests` | **Defect fixed** (§3); tests added |
| Import | `PlaylistMetadataFileImporter`, `ExportifyCSVParser`, `SpotifyPlaylistJSONParser`, `PlaylistZIPReader`, `PlaylistImportCoordinator` | one IMMEDIATE transaction in `createCommittedPlaylist`, positions verified before commit | ordering, duplicates, partial writes, hostile files | parser/ZIP/integration suites (500/1,000) | Added 2,000/10,000, distinct-identity invariant, corrupt-file integrity, concurrency |
| Migration state | `GRDBPlaylistMigrationRepository`, `CoordinatorRepository`, `PlaylistMigrationCoordinator` | `playlist_migrations`, `migration_entries`, coordinator tables | restart recovery, illegal transitions | persistence/coordinator suites | Rerun |
| Matching | `SongMatchingPolicy`, `PlaylistMigrationMatchingService`, discovery providers | `migration_candidates` | wrong recording accepted | matching suites, `MatchingCorrectionTests` | Thresholds unchanged (no demonstrated defect); rerun |
| Acquisition / replacement | `PlaylistAcquisitionCoordinator`, `ReplacementSchema` | acquisition links, `migration_replacements` | destroying audio before commit, stale callbacks | acquisition/replacement suites | Rerun |
| Issues | `MigrationIssueClassifier/Coordinator/Repository` | `migration_issues` | waiting mislabeled as failed | issue suites | Rerun |
| Playlist UI | `MigrationPlaylistViews`, `PlaylistAdditionViews`, `SongOptionsView`, search | read models | search creating its own queue | `PlaylistSearchTests`, UI tests | Rerun |

**Deletion-site audit (P0 risk: user library deletion).** Every `removeItem`/row deletion in
production code was inspected. Audio is deleted only for: interrupted local imports whose
file no row references (`reconcileMissingFiles`), unreferenced owned artwork
(`cleanupArtwork` counts references inside the write transaction), staging files of
non-retained download jobs, and the import staging directory. Missing library files are
marked `missing`, never deleted. UI-test reset is `#if DEBUG` and confined to a validated
temporary root. No path resets or recreates the database.

**Database open on a 10.8 phone.** GRDB 7.11.1 `DatabaseMigrator.migrate` intersects
applied identifiers with registered ones and has no "superseded" failure; the app does not
use `eraseDatabaseOnSchemaChange`. The recorded `v023_spotify_pending_imports` and its table
are therefore ignored, not removed. Now covered by `CanceledPhase108UpgradeTests` (§4).

**Residual risk noted, not changed.** Launch recovery (`GRDBPlaylistMigrationRepository.recover`)
verifies every session's positions and throws on corruption, which fails storage start-up
closed rather than continuing with an inconsistent playlist. No test or device report shows
this state arising; it is documented here rather than changed without evidence.

## 3. Source changes

| Commit | Change |
|---|---|
| `6faacb5` (pre-existing) | Convert the canceled 10.8 version-2 share inbox once; keep YouTube shares, drop Spotify shares, back up the original |
| `7981b02` | **Defect fix:** the conversion was written only if the requested change succeeded. A refused first change (e.g. saving into a full 16-entry queue) left the v2 file in place, and each later attempt converted it again and wrote another backup. The converted queue is now committed before the change, and an identical existing backup is reused. |
| `03fa34c` | Release-integrity test suites and the `release_only` Stage B workflow selector |
| `8001931` | Version 1.1.0 (app and extension); IPA packaging check/manifest require v1.1.0 |
| `4a18f5d` | Fix the never-executed Phase 10.7 search test fixture (§5) |

Files: `Sharing/SharedLinkInbox.swift`, `Tests/Unit/SharedLinkInboxTests.swift`,
`Tests/Unit/PlaylistMigration/{ReleaseIntegritySupport,ReleaseImportStressTests,ReleaseCorruptImportTests,CanceledPhase108UpgradeTests}.swift`,
`.github/workflows/playlist-migration.yml`, `project.yml`, `Scripts/package-ipa.sh`, this
document and `Docs/RELEASE_NOTES_v1.1.0.md`.

## 4. Test inventory (added in Phase 10.9)

`ReleaseIntegritySnapshot` — row count and digest of every user-data table plus SHA-256 of
every Music/Artwork file; equality proves an operation changed nothing it should not.

| Suite / test | Gate |
|---|---|
| `ReleaseImportStressTests.testCSVImportsPreserveEveryDistinctOccurrenceInOrderFromTenToTwoThousandEntries` | 10/100/500/1,000/2,000 CSV: source *i* → occurrence *i*, positions {0…n−1}, distinct identities, 12/19/44 duplicates stay 3 occurrences, relaunch identical, rest of library unchanged (G04) |
| `…testTwoThousandEntryJSONExportKeepsTheSameInvariant` | 2,000-entry account-data JSON |
| `…testTenThousandEntryLimitIsAcceptedWholeAndOneMoreIsRejectedWithoutWrites` | 10,000 accepted whole; 10,001 rejected with no write |
| `…testConcurrentFiveHundredEntryImportsSharingRecordingsStayCompleteAndIsolated` | 3×500 concurrent on separate connections + a cancelled 4th |
| `…testRepeatedImportOfTheSameExportReusesItAndKeepsLocalEdits` | 3 re-imports: no duplicate, rename and removal kept |
| `…testSourceFileChangedAfterReviewDoesNotAlterTheCommittedPlaylist` | content changing during import; staging removed |
| `ReleaseCorruptImportTests` (3 tests) | 20 invalid documents + 9 whole-file rejections + mixed ZIP; integrity snapshot unchanged |
| `CanceledPhase108UpgradeTests` (3 tests) | exact 10.8 v023 state opens unchanged; delete referenced playlist; normal import afterwards (G07/G08 automated part) |
| `SharedLinkInboxTests` (+2 tests) | full 10.8 queue converted once despite failed first change; concurrent first access converts once (G07) |

## 5. Automated results

### Stage A — static (local and CI)

| Check | Result |
|---|---|
| `Scripts/check-test-hygiene.py` (selectors resolve, migration suites registered) — 86 classes, 3 workflows, 0 problems | PASS |
| `git diff --check` | PASS |

Static checks do not prove Swift compiles or runs.

### Stage B — focused native (`playlist-migration.yml`, `release_only=true`, Xcode 26.2, iOS 26.2 simulator)

| Run | Source | Result |
|---|---|---|
| [44071991673](https://github.com/T-h07/MuzikBelesh/actions/runs/44071991673) | `8001931` | **FAIL** — 258 executed, 255 passed, 3 assertions failed in one test (below). All Phase 10.9 suites passed. |
| [44074854232](https://github.com/T-h07/MuzikBelesh/actions/runs/44074854232) | `4a18f5d` | **PASS** — 258 executed, 0 failed, 0 skipped (29 suites) |

Failure analysis: `PlaylistSearchTests.testDuplicateOccurrencesResolveToTheTappedPosition`
was added in Phase 10.7 (`434aac3`, `[skip ci]`) and had **never executed natively**: every
earlier run of this workflow on the 10.7 branch was cancelled or failed before reaching it.
Search matches substrings of title and artist; the query `song a` requires the term `a`, and
every fixture artist (`Artist N`) contains it, so all seven occurrences matched instead of
positions 0 and 5 (the other two assertions followed from that). This is a baseline test
defect present on `develop`, not a Phase 10.9 regression and not a product defect. Fixed in
the fixture only (`4a18f5d`); search behavior is unchanged.

Phase 10.9 suites in the passing run: `ReleaseImportStressTests` 6/6,
`ReleaseCorruptImportTests` 3/3, `CanceledPhase108UpgradeTests` 3/3, `SharedLinkInboxTests`
8/8 (6 existing + 2 new), `ShareURLValidationTests`. Also executed: import parser/ZIP/
integration, persistence, foundation, coordinator, acquisition (+recovery, queue stall),
issue persistence/recovery, recording replacement, occurrence removal, link downloads,
playlist search, matching correction/policy/pause-resume, downloads, background downloads,
storage, library migration, playback, hybrid playlists.

### Stage C — complete regression

FINAL_PENDING

## 6. Stress-test results

From the passing-suite logs of run 44071991673 (CI simulator, wall clock; observations, not
gates). Every row also passed the occurrence invariant, relaunch read-back and
library-unchanged checks.

| Dataset | Bytes | Stage + parse | Commit (one transaction) | Result |
|---|---:|---:|---:|---|
| CSV 10 | 797 | 7 ms | 7 ms | PASS |
| CSV 100 | 7,447 | 15 ms | 13 ms | PASS |
| CSV 500 | 36,973 | 53 ms | 46 ms | PASS |
| CSV 1,000 (mandatory; repeats at 12/19/44) | 73,887 | 96 ms | 120 ms | PASS |
| CSV 2,000 | 147,707 | 210 ms | 199 ms | PASS |
| JSON 2,000 | 383,398 | 260 ms | 216 ms | PASS |
| CSV 10,000 (limit) | 738,266 | 830 ms | 1,066 ms | PASS; 10,001 rejected, no write |
| 3 × 500 concurrent, separate connections | — | — | 161 ms total | PASS; 1,500 occurrences, cancelled 4th wrote nothing |
| Repeated import ×3 | — | — | — | PASS; same session, rename and removal kept, snapshot identical |
| Corrupt/hostile files (20 documents, 9 whole-file) | — | — | — | PASS; integrity snapshot identical, no staging left |
| 10.8 leftover database | — | — | — | PASS; opens unchanged, `integrity_check` ok |

Not run in Phase 10.9 (covered by earlier phase suites rerun in Stage B, not re-measured):
interruption at each persistence boundary with a real process kill, real network failure,
real storage exhaustion. Simulated equivalents exist in the coordinator, acquisition,
recovery and `ReleaseReliabilityTests` suites.

## 7. Performance observations

Only wall-clock times printed by the stress suites on the CI simulator are reported (§6).
Peak memory, main-thread blocking, query counts and on-device throughput were **NOT RUN**
in Phase 10.9; simulator numbers are not device, battery or thermal measurements. Earlier
baselines: `Docs/PHASE_09_PERFORMANCE.md`, `ReleasePerformanceTests` (rerun in the final
regression).

## 8. Database integrity

- Fresh schema: 22 registered migrations (`v001`…`v022`); Phase 10.9 adds none.
- 10.8 phones: 23 applied identifiers including `v023_spotify_pending_imports`; the
  leftover table and rows are kept (not deleted to "clean" the schema).
- v1.0.0 (`v012`) → current: `PlaylistMigrationPersistenceTests.testUpgradeFromReleasedV012PreservesLibraryQueueHistoryAndState`.
- Every new suite checks `PRAGMA foreign_key_check` = 0; the upgrade test also checks
  `PRAGMA integrity_check` = `ok`.
- Repeatable comparison: `ReleaseIntegritySnapshot` (tables + files) before/after.

## 9. Known limitations

| Item | Severity | Notes / workaround |
|---|---|---|
| iOS controls background execution; force-quit stops matching and transfers until the app is reopened | Platform | Work resumes from saved state on next launch |
| YouTube availability and extraction can change externally | Provider | Failures are reported per song with retry |
| Matching may route correct songs to Review when evidence is weak | Low | By design: no unrelated recording is accepted silently |
| Canceled 10.8 leftovers stay on upgraded phones: `spotify_pending_imports` table, `v023` record, `PendingSharedLinks-v2-backup-*.json` (and any `PendingSharedLinks-unreadable-*` files) in the App Group | Cosmetic | Unused and harmless; never reuse that migration identifier or table name |
| Share extension cannot open the app | Platform | Open Muzik Belesh manually (unchanged from v1.0.0) |
| Unsigned IPA | Distribution | Requires SideStore signing with the same identity for in-place upgrade |
| Launch recovery fails closed on a corrupt migration session | Residual risk | §2; no evidence it occurs |

All v1.0.0 limitations in `Docs/KNOWN_LIMITATIONS.md` still apply.

## 10. Outstanding defects

None open from Phase 10.9 automated verification (see §5). Physical acceptance may add
items.

## 11. Physical iPhone acceptance matrix (iPhone 13 Pro Max, SideStore)

All rows **NOT RUN** until the user reports results. Back up the device (or at least export
music) before P01.

| ID | Test | Expected | Result |
|---|---|---|---|
| P01 | In-place install over the current app, same SideStore identity | Existing data available | NOT RUN |
| P02 | Existing library: tracks, playlists, artwork, downloads | Nothing disappears | NOT RUN |
| P03 | Open existing imported playlists | No corruption/crash/missing occurrences | NOT RUN |
| P04 | Phone previously running the 10.8 test IPA: launch, share a YouTube link | No inbox error; share saved | NOT RUN |
| P05 | Import 100-song CSV | All entries, original order | NOT RUN |
| P06 | Import 500-song CSV | Counts, order, responsive | NOT RUN |
| P07 | Import 1,000-entry playlist (with repeats) | Every position kept; repeats distinct | NOT RUN |
| P08 | Import the same file again | "Already imported"; no duplicate/overwrite | NOT RUN |
| P09 | Matching | Library songs matched; ambiguous → Review | NOT RUN |
| P10 | Download queue | Several songs download without blocking | NOT RUN |
| P11 | Interrupt downloads (airplane mode / Wi-Fi off) | Recovers; verified music kept | NOT RUN |
| P12 | Background downloading and playback | Stable | NOT RUN |
| P13 | Force-quit during migration, relaunch | State correct; resumes only after reopening | NOT RUN |
| P14 | Migration Issues | Useful reasons and actions | NOT RUN |
| P15 | Tap a ready song | Plays immediately | NOT RUN |
| P16 | Playlist search, tap result | Filters view; continues through whole playlist | NOT RUN |
| P17 | Shuffle and repeat | Correct progression | NOT RUN |
| P18 | Add Songs from library | Added | NOT RUN |
| P19 | Bulk YouTube URLs | All valid links queued | NOT RUN |
| P20 | Remove from Playlist (incl. a repeated song) | Only that entry removed | NOT RUN |
| P21 | Change Video | Replaced safely; other playlists unaffected | NOT RUN |
| P22 | Local audio offline playback | Plays | NOT RUN |
| P23 | Lock screen / Control Center / AirPods | Controls work | NOT RUN |
| P24 | YouTube Search and Share extension (YouTube app and Safari) | Work | NOT RUN |
| P25 | Restart persistence (playlists, queue, downloads) | Persist | NOT RUN |
| P26 | Extended normal use | No crash, data loss, wrong association or stuck migration | NOT RUN |

Upgrade coverage: the phone's current build is the canceled 10.8 test IPA (build 97), so
P01–P04 prove the 10.8 → 1.1.0 path. The v1.0.0 → 1.1.0 path is covered by the automated
`v012` upgrade test only; a device check would need a separate test device or a restored
backup — never the user's real library.

## 12. Release-candidate source commit

CANDIDATE_PENDING

## 13. IPA artifact

IPA_PENDING

## 14. Rollback and recovery

- Before installing: keep the current IPA (10.8 test build 97, or v1.0.0) and, if possible,
  an iPhone backup. Export important music with the app's Export function.
- Do **not** delete the app to "fix" a problem: that deletes the library.
- The candidate adds no schema migration, so reinstalling the previous Phase 10.7-based
  build over it with the same identity opens the same database. Reinstalling v1.0.0 over a
  database that already contains Phase 10 migrations is untested and not recommended.
- If the share inbox was converted, the original 10.8 file is in the App Group as
  `PendingSharedLinks-v2-backup-<uuid>.json`.
- The branch `feature/phase-10-09-release` and the 10.7 merge `c2be900` remain available.

## 15. Release-readiness decision

DECISION_PENDING
