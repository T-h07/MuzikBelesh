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

Run [44077441555](https://github.com/T-h07/MuzikBelesh/actions/runs/44077441555) (`ci.yml`, `complete`) on the frozen
candidate `3c18885`: **FAIL — every failure is a pre-existing baseline or a timing flake;
no Phase 10.9 regression.** Comparison with the same suite on `develop` at the accepted
Phase 10.7 merge `c2be900` (run [43975347911](https://github.com/T-h07/MuzikBelesh/actions/runs/43975347911)):

| Shard | `develop` `c2be900` | Candidate `3c18885` |
|---|---|---|
| Units (+ accessibility) | 582 run, 2 failed | 598 run, **597 passed, 1 failed** (+16 Phase 10.9 tests, search fixture fixed) |
| Library UI (iPhone 16 Pro Max) | 16/16 | **16/16 PASS** |
| Compact (iPhone SE) | 5/5 | 4/5 |
| Other UI | 25 run, 6 failed | 25 run, 19 passed, **the same 6 failed** |

| Failing test | Classification | Evidence |
|---|---|---|
| `PlaylistMigrationCoordinatorTests.testT18ThousandEntryMigrationUsesBoundedWorkersQueriesAndUpdates` | Baseline timing: exceeds the shard's 60 s default allowance | Same on `develop` `c2be900` and `f2c448d`; passes in Stage B (120 s allowance) |
| `PlaylistFileImportUITests.testMultipleSelectionRenamePreviewAndInvalidCandidate` | Baseline UI failure | Fails in every complete run on `develop` since `f655286` (15 Nov) |
| `PlaylistFileImportUITests.testThousandEntryScrollDashboardInspectionAndRestartSmoke` | Baseline UI failure | Same history |
| `ReviewQueueUITests.testLastAndFirstCandidatesConfirmAndAdvance` | Baseline UI failure | Same history |
| `ReviewQueueUITests.testMiddleCandidateConfirmsAdvancesAndPersistsAcrossRelaunch` | Baseline UI timeout | Same history |
| `ReviewQueueUITests.testNavigationResetsScrollAndNeverSelects` | Baseline UI failure/timeout | Same history |
| `PlaylistMigrationUITests.testPlaylistSearchFiltersAndClearRestoresAllSongs` | Baseline UI failure (search field not found within 5 s) | Fails on `develop` since the 10.7 merge |
| `LibraryManagementUITests.testEmptyAlbumCreationAndSearchPersistAfterRelaunch` (compact) | Timing flake | Passed in the Library UI shard of the same run; LibraryManagement timeouts rotate between tests across runs (`f2c448d`, `4df61bb`, `49f3fa5`) |

Phase 10.9 changed no UI code. The six migration/review UI failures are **unresolved
baseline test failures**, not confirmed product defects; they are not disabled or skipped.
Their flows are covered on the device by P09, P14 and P16. Investigating them needs
interactive UI debugging and is recommended as follow-up work.

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

No product defect is open from Phase 10.9 verification. Open test items, all pre-existing
on `develop` (§5): six migration/review-queue UI tests failing and the T18 coordinator test
exceeding the complete-regression 60 s allowance. Physical acceptance may add items.

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

`3c188856bd7f38b4a66c1c7effbadc6224091534` on `feature/phase-10-09-release` — the commit
the IPA was built from and Stage C ran on. Later commits on the branch change only `Docs/`
(this file's results); if any source changes after acceptance, Stage B, the IPA and the
affected device rows must be repeated for the new candidate.

## 13. IPA artifact

| Field | Value |
|---|---|
| Workflow run | [44083978843](https://github.com/T-h07/MuzikBelesh/actions/runs/44083978843) (`build-ipa.yml`, run #98) |
| Artifact | `OFFLINE-unsigned-IPA` (id 14328752269, expires 2027-02-15) |
| File | `OFFLINE-unsigned.ipa`, 6,340,217 bytes |
| SHA-256 | `1dd6f93ba8ab82d182fe67bf2f64b7f8bebf275bbcdd5a3cfc74bbb4ce6c0414` (manifest and independent re-hash agree) |
| Version / build | 1.1.0 / 98 (installed 10.8 test IPA: build 97) |
| Embedded commit | `3c18885` = source SHA |
| Main app | `com.th07.muzikbelesh`, arm64, `UIBackgroundModes` = audio, processing |
| Share extension | `com.th07.muzikbelesh.share`, 1.1.0 / 98, `com.apple.share-services`, present in `PlugIns/` |
| App Group requested by both executables | `group.com.th07.muzikbelesh.inbox` |
| Signing | Unsigned; ad-hoc entitlement metadata only; no `_CodeSignature` or provisioning profile |
| Canceled 10.8 content | No Spotify client ID keys, no `accounts.spotify.com`/`api.spotify.com`, no `spotify_pending_imports` in either binary; inbox downgrade code present |

Verified independently after download (ZIP integrity, both bundles, Info.plists, strings).

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

**READY FOR PHYSICAL ACCEPTANCE** — not ready for release.

| Gate | Status |
|---|---|
| G01 Phase 10 components integrated | PASS (automated) |
| G02 New automated tests pass | PASS (Stage B, Stage C units) |
| G03 v1.0.0 functionality verified | Automated: Library UI 16/16, playback/library/download/YouTube units pass; device: NOT RUN (P22–P25) |
| G04 1,000-entry ordering/occurrence integrity | PASS (automated); device P07 NOT RUN |
| G05 No incorrect audio associations | Automated suites pass; device P09/P21 NOT RUN |
| G06 Retry/recovery tests pass | PASS (automated); device P11/P13 NOT RUN |
| G07 Share inbox downgrade compatibility | PASS (automated); device P04 NOT RUN |
| G08 In-place upgrade preserves data | Automated PASS (10.8 state, v012); device P01–P03 NOT RUN |
| G09 Physical acceptance recorded | NOT RUN |
| G10 No unresolved P0/P1 defects | None known; 6 baseline UI test failures unresolved (§5) — to be confirmed or cleared by device rows |
| G11 IPA provenance and checksum | PASS (§13) |
| G12 User approves release | NOT GIVEN |

Nothing has been merged into `develop`, `main` or `release`; no `v1.1.0` tag or GitHub
Release exists.

## 16. Final hardening pass and replacement candidate (build 99)

The final security/performance/cleanup pass is documented in
`Docs/PHASE_10_09_SECURITY_PERFORMANCE.md`. It **supersedes §12, §13 and §15**: build 98
(`3c18885`) is replaced by build 99 because production source changed.

### Source

| Commit | Change |
|---|---|
| `e0633e9` | CI: `prebuilt_run_id` passed through a validated env var (script-injection fix) |
| `77e4cd8` | Import: bound untrusted audio metadata (an artist/album tag over 300 characters failed the whole import); balanced security-scoped access; `ReleaseHardeningTests` |
| `a66de73` | Remove dead code and the DEBUG-only Phase 1 mock layer (212 lines, 13 files) |
| `d5551d5` | Ordinary playlist rows share one playback-context array per render (was O(n) per row) |
| `a146c34`, `e9430c8`, this commit | Docs; test-only fix (synchronous GRDB reads in an async test) |

**Release-candidate source: `d5551d54198a75af6dafac7af109dbc2e5b31e29`.** `e9430c8` differs from
it only in `Tests/` and `Docs/` (`git diff d5551d5 e9430c8 -- OFFLINE OFFLINEShareExtension Sharing project.yml`
is empty), so the IPA built from `d5551d5` is the tested product.

### Automated results

| Stage | Run | Source | Result |
|---|---|---|---|
| A — static | local | `e9430c8` | **PASS** — hygiene 86 classes / 3 workflows / 0 problems; `git diff --check` clean |
| B — focused (`release_only`) | [44093023206](https://github.com/T-h07/MuzikBelesh/actions/runs/44093023206) | `d5551d5` | **FAIL — test target did not compile** (`ReleaseHardeningTests`: GRDB async `read` overload in an async test). No test executed. Fixed in `e9430c8` (test-only) |
| B — focused (`release_only`) | [44096490155](https://github.com/T-h07/MuzikBelesh/actions/runs/44096490155) | `e9430c8` | **PASS — 261 executed, 0 failed** (includes `ReleaseHardeningTests` 3/3, all Phase 10.9 release suites, import/persistence/acquisition/recovery/download/playback suites, T18 within its 120 s allowance) |
| C — complete | [44093028800](https://github.com/T-h07/MuzikBelesh/actions/runs/44093028800) | `d5551d5` | **FAIL — same compile error**; no test executed |
| C — complete | [44096495656](https://github.com/T-h07/MuzikBelesh/actions/runs/44096495656) | `e9430c8` | **FAIL — baseline failures only** (below) |

Stage C shard comparison with the build-98 candidate (§5):

| Shard | `3c18885` (build 98) | `e9430c8` (build 99 source + test fix) |
|---|---|---|
| Units (+ accessibility) | 598 run, 597 passed, 1 failed | **595 run, 594 passed, 1 failed** (−6 removed `Phase1StoreTests`, +3 `ReleaseHardeningTests`; opt-in `YouTubeLiveTests` not selected, as before) |
| Library UI (iPhone 16 Pro Max) | 16/16 | **16/16 PASS** |
| Compact (iPhone SE) | 4/5 (timing flake) | **5/5 PASS** |
| Other UI | 25 run, 6 failed | 24 run, 18 passed, **the same 6 failed** |

Failures, all pre-existing and unchanged:

| Test | Classification |
|---|---|
| `PlaylistMigrationCoordinatorTests.testT18ThousandEntryMigrationUsesBoundedWorkersQueriesAndUpdates` | Baseline timing (exceeds the shard's 60 s allowance; passes in Stage B with 120 s) |
| `PlaylistFileImportUITests.testMultipleSelectionRenamePreviewAndInvalidCandidate` | Baseline UI failure (§5) |
| `PlaylistFileImportUITests.testThousandEntryScrollDashboardInspectionAndRestartSmoke` | Baseline UI failure (§5) |
| `PlaylistMigrationUITests.testPlaylistSearchFiltersAndClearRestoresAllSongs` | Baseline UI failure (§5) |
| `ReviewQueueUITests.testLastAndFirstCandidatesConfirmAndAdvance` | Baseline UI failure (§5) |
| `ReviewQueueUITests.testMiddleCandidateConfirmsAdvancesAndPersistsAcrossRelaunch` | Baseline UI timeout (§5) |
| `ReviewQueueUITests.testNavigationResetsScrollAndNeverSelects` | Baseline UI failure (§5) |

The hardening pass changed no migration-import, review-queue or migration-playlist UI code
(the only view change is the ordinary-playlist row branch of `PlaylistDetailView`, covered by
the passing Library UI shard). These six UI tests and T18 remain **unresolved baseline test
failures**, not disabled and not reported as passing.

Stress observations from Stage B (CI simulator, wall clock, stage+parse / commit): CSV 100 →
16/16 ms, 500 → 73/59 ms, 1,000 → 95/98 ms, 2,000 → 224/224 ms, 10,000 → 1,228/905 ms; JSON
2,000 → 238/217 ms. Same order as build 98 (§6); import code was not changed.

### IPA (build 99)

| Field | Value |
|---|---|
| Workflow run | [44093034975](https://github.com/T-h07/MuzikBelesh/actions/runs/44093034975) (`build-ipa.yml`, `build_number=99`) |
| Artifact | `OFFLINE-unsigned-IPA` (id 14332838313, expires 2027-02-15) |
| File | `OFFLINE-unsigned.ipa`, 6,339,852 bytes |
| SHA-256 | `2358a7bdd6da6dafa3d309501464c4fc53163c99f46e732bd64b90c6b530984f` (manifest and independent re-hash agree) |
| Version / build | 1.1.0 / 99, app and extension |
| Embedded commit | `d5551d5` = source SHA |
| Main app | `com.th07.muzikbelesh`; `UIBackgroundModes` audio, processing; BGTask `com.th07.muzikbelesh.matching.*`; ATS arbitrary loads off, local networking on |
| Share extension | `com.th07.muzikbelesh.share`, `com.apple.share-services`, in `PlugIns/` |
| App Group requested by both executables | `group.com.th07.muzikbelesh.inbox` |
| Signing | Unsigned; no `_CodeSignature` or provisioning profile |
| Release binary content | No `accounts.spotify.com`/`api.spotify.com`/`spotify_pending_imports`; no mock-store, `--ui-testing`, `--reset-ui-library` or UI-test fixture strings |
| Archive | ZIP integrity OK; no absolute or `..` entries |

### Physical retest (targeted)

Reused acceptance: P01–P08 (upgrade and CSV import paths unchanged). Required on build 99:

| ID | Why |
|---|---|
| P01 (quick) | Install build 99 over build 98 with the same SideStore identity; library intact |
| P10, P12 | Every download ends in the changed import step |
| P15, P16, P18 | Ordinary/imported playlist rows and playback context |
| P22 | Local audio import (changed metadata handling) and offline playback |
| P24 | Share extension smoke (no source change; one share confirms the build) |

Other rows keep their earlier status; any still NOT RUN remain required as listed in §11.

### Release-readiness decision (build 99)

**READY FOR TARGETED DEVICE ACCEPTANCE** — not released. No Critical/High security issue,
no known data-loss, corruption, traversal, download-integrity or association defect. Open
items: the seven baseline test failures above, and device rows. G12 (user approval) NOT
GIVEN. Nothing merged into `develop`, `main` or `release`; no `v1.1.0` tag or GitHub Release.

## 17. Developer acceptance and release authorization (2026-11-17)

**This section supersedes the earlier candidate-only status and NOT RUN markers where device results were subsequently supplied.** It does not retrospectively turn unexecuted tests into passes.

### Device-reported results

- **Build 98:** The developer installed the IPA in place, confirmed all existing data survived, and reported **P01–P08 PASS**. These covered existing library/playlist integrity, a YouTube share after the canceled-10.8 inbox downgrade, and 100/500/1,000-entry CSV import and re-import behavior.
- **Build 99:** After installing the final hardening IPA, the developer explicitly reported **all requested targeted tests passed**, covering **P01, P10, P12, P15, P16, P18, P22 and P24**. These are developer-reported results, not independently recorded iPhone logs.
- **Not rerun on build 99:** Other P09–P26 checks were previously accepted during Phases 10.0–10.7 or are supported by the unchanged implementation and automated suites; they must not be represented as newly executed 10.9 tests.

### Final evidence and disposition

- Final production candidate: `d5551d54198a75af6dafac7af109dbc2e5b31e29`, v1.1.0 **build 99**, IPA SHA-256 `2358a7bdd6da6dafa3d309501464c4fc53163c99f46e732bd64b90c6b530984f`.
- Later changes before merge: test-only compile correction, documentation and release metadata; no new production code changes.
- Focused Stage B: **261/261 PASS** on `e9430c8`. Complete Stage C: library and compact UI passed, but **seven pre-existing test failures** remain documented and are not waived as passing.
- Security audit reported no confirmed Critical/High finding; measured on-device performance improvements were not claimed.
- **User authorization:** The developer expressly approved publishing Muzik Belesh **v1.1.0** after reporting that all requested final build-99 device tests passed.

**Disposition: OWNER-APPROVED FOR v1.1.0 RELEASE PROMOTION WITH DOCUMENTED BASELINE CI FAILURES.** Merge Phase 10.9 into `develop` first, then promote that integrated state into `release` and `main`, and publish the tag, unsigned IPA and manifest. Never replace the verified build-99 IPA with an untested rebuilt binary solely because merge commits or README text changed.
