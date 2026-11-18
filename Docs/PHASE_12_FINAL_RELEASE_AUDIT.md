# Phase 12 — final release audit (v1.2.0)

| Field | Value |
| --- | --- |
| Release | Muzik Belesh **1.2.0**, build **200** |
| Starting point | `develop` 78c5c62 (Phase 11.5 merged) |
| Branch | `feature/phase-12-final-release` |
| Stable baseline | `main` a10dae6 = tag `v1.1.0` (build 99); `release` a67aefd |
| Identities (unchanged) | `com.th07.muzikbelesh`, `com.th07.muzikbelesh.share`, `group.com.th07.muzikbelesh.inbox`, iOS 17.0 |

Companion documents: [security audit](PHASE_12_SECURITY_AUDIT.md) ·
[performance report](PHASE_12_PERFORMANCE_REPORT.md) ·
[release checklist and gates](PHASE_12_RELEASE_CHECKLIST.md) ·
[device acceptance](PHASE_12_DEVICE_ACCEPTANCE.md) ·
[release notes](RELEASE_NOTES_v1.2.0.md)

## 1. Starting state

Phase 11.1–11.5 were accepted on a physical iPhone while parts of CI stayed red:
Phase 11.4 CI #294 and Phase 11.5 CI #298 (run 44290264115) both failed. Phase 12
treated every failure as a defect to root-cause, not as noise. Evidence was taken from
the failing runs' logs and from the decoded `xcresult` bundles (accessibility hierarchies
and failure screenshots), not from re-running until green.

No timeout was raised, no test was skipped or deleted, and no coverage was reduced.

## 2. Findings register

Severity: **P0** data loss / crash on launch · **P1** core feature broken · **P2**
user-visible defect, security or release-integrity gap · **P3** test, tooling or
hardening issue with no user-visible effect.

### P12-01 — In-playlist search results hidden under the keyboard (P2)

- **Component:** `OFFLINE/Features/Library/DetailViews.swift` (`PlaylistDetailView`).
- **Observed:** `PlaylistMigrationUITests.testPlaylistSearchFiltersAndClearRestoresAllSongs`
  failed: filtered rows did not exist in the hierarchy.
- **Root cause:** the decoded hierarchy showed the List shrunk to 520 pt with the search
  field at y = 498; the field sits below the header, so with the keyboard up the filtered
  rows were laid out beneath the keyboard and never materialised. A real user sees an
  apparently empty result.
- **Reproduction:** open a long playlist, scroll to the search row, type a query.
- **Risk:** search looks broken on smaller iPhones.
- **Correction:** when search becomes active, scroll the search row to the top
  (`ScrollViewReader`, stable row ID), so results appear directly under the field.
- **Tests:** the existing UI test, unchanged.
- **Expected improvement:** results visible above the keyboard.
- **Actual result:** see G05 in the release checklist.

### P12-02 — VoiceOver loses the button trait on Your Listening rankings (P2)

- **Component:** `OFFLINE/Features/Profile/ListeningComponents.swift`.
- **Observed:** `ListeningAnalyticsUITests.testTopSongPlaysAndTopPlaylistOpens` (and the
  other analytics UI tests) could not find the top-song/top-playlist buttons; failing
  since Phase 11.2.
- **Root cause:** `.accessibilityElement(children: .ignore)` on a `Button` label replaces
  the element and drops its `.isButton` trait, so VoiceOver announced the ranking rows as
  plain text and XCUITest exposed them as other elements.
- **Reproduction:** VoiceOver on, Profile → Your Listening, focus a top song.
- **Risk:** accessibility regression; rows not announced as actionable.
- **Correction:** add `.accessibilityAddTraits(.isButton)` after `.ignore` on all four
  ranking elements (top song #1, songs #2+, artists #2+, collections carousel).
- **Tests:** existing analytics UI tests.
- **Expected improvement:** rows are buttons for VoiceOver and UI tests.
- **Actual result:** see G05.

### P12-03 — Re-selecting the active theme saves and publishes (P3)

- **Component:** `OFFLINE/DesignSystem/ThemeService.swift`.
- **Observed:** `ThemeTests` expected 0 publications and saw 2.
- **Root cause:** (a) `select`/`selectCustom`/`reset` always re-applied and saved;
  (b) `save()` assigned `lastError = nil` unconditionally, and `@Published` notifies on
  every assignment, including nil → nil. The test also kept two sinks alive at once.
- **Risk:** needless UserDefaults writes and full-app re-renders on each tap.
- **Correction:** a single `choose(_:)` path that is a no-op when nothing changes, but
  still retries a pending or failed save; `lastError` assigned only on change. The test now
  cancels its first sink.
- **Tests:** `testSelectingTheActiveThemeWritesNothingButRetriesAFailedSave` (new).
- **Actual result:** see G03.

### P12-04 — Theme isolation test attributed playback writes to the theme (P3)

- **Component:** `Tests/Unit/Theme/ThemeTests.swift`.
- **Root cause:** the database snapshot was taken before `player.play(...)`, so the
  playback-state and history writes of starting playback were counted as theme writes.
- **Correction:** snapshot after playback starts; the assertion (a theme change writes
  nothing to the library database) is unchanged in strength.

### P12-05 — Playback-minute budget test predates listening analytics (P3)

- **Component:** `Tests/Unit/ReleasePerformanceTests.swift`.
- **Observed:** 15 writes per minute against a budget of 12.
- **Root cause:** the 3 extra writes are one Phase 11.2 listening checkpoint (session
  insert, session update, day upsert) — correct behaviour. The test's wall-clock credit
  also varied with runner speed.
- **Correction:** classify statements (SELECT / position / listening / other); require
  0 SELECTs, exactly 12 position writes, no other writes, and listening writes derived from
  `ListeningPolicy.checkpointMs`; inject a deterministic monotonic clock.
- **Expected improvement:** stricter test — any new read or unexpected write now fails by
  name, and the result no longer depends on runner speed.

### P12-06 — Review-queue UI tests: duplicate dialog button and off-screen tap (P3)

- **Component:** `Tests/UITests/ReviewQueueUITests.swift`.
- **Root cause:** iOS 26 exposes the `confirmationDialog` action twice ("Multiple
  matching elements"); the last candidate sat at y ≈ 874–918 of 956 pt, behind the home
  indicator area, so the tap did not open the dialog.
- **Correction:** address the confirm button with `matching(identifier:).firstMatch`;
  scroll once when the candidate is within 80 pt of the bottom; wait for the dialog title
  and check the chosen candidate before confirming.

### P12-07 — 1,000-entry import test read rows during a fling (P3)

- **Component:** `Tests/UITests/PlaylistFileImportUITests.swift`.
- **Root cause:** identifiers were collected from a snapshot taken while the list was
  still decelerating, then tapped after they had moved.
- **Correction:** take hierarchy snapshots until two consecutive ones agree (max 10),
  restricted to the safe visible band, then tap by identifier.

### P12-08 — Switch flips occasionally ignored (P3)

- **Component:** `Tests/UITests/UITestSupport.swift` (`flipSwitch`).
- **Root cause:** the first tap occasionally lands during a row animation.
- **Correction:** wait 3 s for the value to change; if unchanged, tap the switch itself
  once, then require the change. The final assertion is unchanged.

### P12-09 — 60 s "animations complete" stalls while typing in CI (P3)

- **Component:** `.github/workflows/ci.yml`.
- **Observed:** intermittent 60 s stalls, always inside "Type into TextField", across
  several UI tests since Phase 11.2.
- **Root cause:** keyboard prediction, autocorrection, the prediction bar and the
  first-use slide-to-type introduction animate continuously in fresh simulators.
- **Correction:** disable those keyboard features and mark the introductions as shown in
  the booted simulator's preferences before tests run. No test timeouts were changed.

### P12-15 — XCTest idle detection still stalls when the keyboard appears (P3, open)

- **Component:** CI simulator / XCTest; observed in
  `LibraryManagementUITests.testSearchSubmitDismissesKeyboardAndCanReopen` (compact shard,
  run 44301621536). The test passed its first three keyboard cycles; on the fourth
  `Tap "search-field"` XCTest waited 60 s for "App animations complete", then a second
  60 s on `Tap "keyboard-done"`, and the 2-minute allowance expired.
- **Evidence:** the spindump XCTest captured at the hang shows the app's main thread
  blocked in `mach_msg` (idle run loop), the app at < 0.001 s CPU, `kbd` at 0.004 s and
  SpringBoard at 0.175 s over the 5 s sample. Nothing in the app or keyboard was animating;
  the idle notification itself was not delivered. The same shard also failed
  intermittently before Phase 12 (CI runs 44195714008 and 44182165889).
- **Assessment:** P12-09 removed the stalls that occurred while typing; this residual
  stall is in XCTest's idle detection, not in app code, so no app change can address it.
  No timeout was raised and the test was not changed or skipped.
- **Actual result:** see G05 in the release checklist (re-run evidence).

### P12-16 — The other-ui regression shard could never finish (P2, release evidence)

- **Component:** `.github/workflows/ci.yml` (`complete-regression` matrix).
- **Observed:** `regression-other-ui` was **cancelled** by the 40-minute job limit in
  develop #299 (44296803454), Phase 11.5 #298 (44290264115), 44211613407 and Phase 12 run
  44301621536. Its later suites (PlaylistMigration, ReviewQueue, YouTube) therefore never
  produced a verdict, so "UI regressions pass" could not be shown at all.
- **Root cause:** one shard held 47 UI tests (~35 min at ~45 s each) after a 13–23 min
  build; the total exceeds 40 min regardless of test correctness.
- **Correction:** split into `other-ui` (Appearance, CollectionArtwork, ListeningAnalytics,
  LocalProfile, Phase1 — new suites land here automatically) and `migration-ui`
  (PlaylistFileImport, PlaylistMigration, ReviewQueue, YouTube). Job limit, per-test
  allowances and test content unchanged. `check-test-hygiene.py` now fails if any suite
  with tests is not selected by some shard (verified by removing one suite: it reports
  `no regression shard runs OFFLINEUITests/ReviewQueueUITests`).

### P12-17 — Custom-colour selection check timed out on a slow runner (P3, monitoring)

- **Observed:** `AppearanceSettingsUITests.testCustomColourSectionAndCustomSelection`
  failed once (run 44301621536): `value == "Selected"` not seen within 5 s.
- **Evidence:** the hierarchy captured at failure shows the swatch with
  `value: Selected` — the app state was correct. That runner was about twice as slow as
  usual (app launch 16 s versus ~2 s; this test 90 s versus 21–45 s), with each
  accessibility query taking 2–3 s, so the 5 s wait got a single evaluation. The test passed
  in 6 of the 7 previous runs. The Phase 12 theme change (P12-03) does not alter this path:
  lime → custom is a real change and is still published.
- **Decision:** no test or timeout change on a single observation; tracked in G05.

### P12-18 — Multiple-selection import test flipped the wrong playlist (P3, fixed)

- **Component:** `Tests/UITests/PlaylistFileImportUITests.swift`
  (`testMultipleSelectionRenamePreviewAndInvalidCandidate`, line 83).
- **Observed:** failed identically in every run inspected (44182165889, 44195714008,
  44205035981, 44290264115, 44296803454, 44309773242): `"0"` is not equal to `"1"` after the
  second flip.
- **Root cause:** the switch was a lazy `firstMatch` query. The CI log shows the first flip
  tapping `playlist-import-select-A787D7BE…` and, after the scroll, the second flip tapping
  `playlist-import-select-6C81A088…` — a different, already-selected playlist, which it
  turned off. The app behaved correctly.
- **Correction:** pin the switch by its resolved identifier before flipping. Assertions
  unchanged.

### P12-19 — Two Phase 12 UI-test corrections needed a second pass (P3, fixed)

- **Review queue (P12-06):** the extra swipe addressed the scroll view "containing the song
  header"; once `reveal` had scrolled, the header was no longer in the hierarchy, so the
  swipe found no element (run 44309773242). It now swipes the scroll view containing the
  button being tapped.
- **Playlist search (P12-01):** with the fix, the test passes the step that failed before
  (line 76) and reaches "Clear". Clear also ends the search, so the list returns to its top,
  where the playlist header leaves room for one 131 pt row; the old assertion that
  "Original song 3" *exists* required a row the lazy List had not created. The test now
  checks the count is back to 5 and scrolls to song 3.

### P12-20 — Migration progress counts had no usable accessibility identifiers (P3, fixed)

- **Component:** `OFFLINE/Features/Library/MigrationPlaylistViews.swift`
  (`MigrationProgressOverview`).
- **Observed:** the 1,000-entry import test (which, with P12-07, now gets through scrolling,
  inspection and relaunch for the first time) could not find `migration-unresolved-count`
  after 15 swipes, both before and after relaunch (run 44318566907).
- **Root cause:** the captured hierarchy shows every text in the overview carrying the
  container's identifier `migration-overall-progress` — a plain SwiftUI stack passes its
  identifier down to its children and replaces theirs. The label is also locale-grouped
  ("Unresolved: 1,000"), while the test expected "1000".
- **Correction:** `.accessibilityElement(children: .contain)` on the overview, so the
  children keep their own identifiers (VoiceOver order and labels unchanged); the test
  expects "Unresolved: 1,000", matching the existing "1,000 songs" assertion.

### P12-21 — Two v1.1.0 baseline UI failures were over-long tests, not hangs (P3, fixed)

- `ReviewQueueUITests.testNavigationResetsScrollAndNeverSelects` and
  `PlaylistFileImportUITests.testMultipleSelectionRenamePreviewAndInvalidCandidate` were
  listed as baseline failures in v1.1.0 (`PHASE_10_09_RELEASE.md`). The step logs show
  steady progress of about one check per second with no idle stall; each simply contains
  more than 60 s of work, so the 60 s allowance ended them (4 of 5 earlier runs for the
  navigation test).
- **Correction:** each is split in two (button navigation / header-swipe navigation;
  selection and switch flips / rename, preview and commit). Every assertion is kept and no
  allowance was raised.
- **Follow-up (run 44327423510):** the rename half then failed at the preview check. Without
  the switch flips that used to precede it, the list was at the bottom when the test looked
  for the name field and preview button, so both unpinned `firstMatch` queries named the
  second candidate (the step log shows the preview tap on a different UUID, which reveals
  the empty "Second source"). The test now pins the first candidate by the UUID in its
  switch identifier before scrolling, and uses that UUID for the preview button.

### P12-22 — Acquisition dedup test fixture produced different bytes per encode (P3, fixed)

- `PlaylistAcquisitionRecoveryTests.testFailedVerificationNeverMarksReadyAndIdenticalAudioIsStoredOnce`
  stored 2 tracks instead of 1 in run 44327423510 (it passed in the two earlier runs).
- **Root cause:** the fixture re-encoded the "identical" tone with `AVAudioFile` for each
  download. The M4A header records its creation time to the second, so two encodes that
  straddle a second boundary differ in bytes. The app's `UNIQUE` index on
  `tracks.contentSHA256` proves the stored files differed; the app's deduplication behaved
  correctly for the bytes it was given.
- **Correction:** the fixture renders each seed once and reuses those bytes, so "same seed"
  now means byte-identical audio. No app code changed.

### P12-14 addendum — the upgrade matrix's first run

Run 44318566907 was the first to execute `Phase12UpgradeMatrixTests`. The v1.1.0 and
Phase 11.1 cuts passed every assertion; the Phase 11.2 fixture then failed to build because
the test used `"session-1"` as a listening-session ID, which the schema rejects
(`CHECK(length(id) = 36)`). The fixture now uses a fixed UUID. This was a test-fixture
error; the schema check behaved correctly.

### P12-10 — HTTP metadata responses buffered without a limit (P2, security)

See [security audit S01](PHASE_12_SECURITY_AUDIT.md). Fixed with `BoundedHTTPBody`
(8 MB YouTube, 4 MB SearXNG/Invidious) and `BoundedHTTPBodyTests`.

### P12-11 — Actions referenced by mutable tags (P3, supply chain)

See security audit S02. Pinned to commit SHAs.

### P12-12 — Release packaging verified too little (P2, release integrity)

See security audit S03. `package-ipa.sh` now verifies both bundles' identities, version,
build, minimum OS, ATS, `.mbelesh` declarations and the absence of test hooks, and
publishes a SHA-256.

### P12-13 — Build number must exceed every distributed build (P2, release integrity)

- **Observed:** v1.0.0 shipped build 195, v1.1.0 shipped build 99 (counter reset), and
  Phase 11 candidates used 100–108 (verified from manifests and embedded Info.plists).
  CI run numbers would have produced builds below 195.
- **Correction:** `project.yml` is now the single version source:
  `MARKETING_VERSION 1.2.0`, `CURRENT_PROJECT_VERSION 200`, referenced by both
  Info.plists. The packager reads it and asserts both bundles match.
- **Actual result:** preliminary candidate (run 44301640542) packaged as 1.2.0 (200) for
  app and extension.

### P12-14 — No test covered upgrading every shipped schema at once (P2, data integrity)

- **Correction:** `Phase12UpgradeMatrixTests` rewinds a populated library to the schema of
  v1.1.0 (v022), Phase 11.1 (v024), 11.2/11.3 (v025), 11.4 (v026) and 11.5 (v027), opens it
  with the v1.2.0 `StorageCoordinator`, and asserts: every pre-existing row byte-identical,
  `integrity_check = ok`, no foreign-key violations, playlist order kept, profile kept,
  audio files present, canceled migration v023 never applied, second launch a no-op.
- **Actual result:** see G06/G15.

### Reviewed, no defect

| Area | Conclusion |
| --- | --- |
| Migrations | v001–v022 (v1.1.0) and v024–v027 are append-only; v023 stays canceled and is never registered. No migration deletes or rewrites user rows. |
| Playback / queue / restoration | No new defect; covered by existing unit and UI suites. |
| Downloads | No change; recovery covered by `BackgroundDownloadTests`. |
| ZIP / `.mbelesh` / Share inbox | Defences verified (security S04–S06). |
| Privacy | Profile, analytics and settings never exported or logged (security §Privacy). |
| Dependencies | GRDB 7.11.1, YouTubeKit 0.4.10, ZIPFoundation 0.9.20 — exact pins, not changed. |

## 3. Code cleanup

Phase 12 deliberately made no broad refactors. Cleanup was limited to consolidating the
theme selection path into one `choose(_:)` function and making `project.yml` the single
version source. Every change has a test or a packaging assertion.

## 4. Changed files (vs `develop` 78c5c62)

App: `ThemeService.swift`, `ListeningComponents.swift`, `DetailViews.swift`,
`YouTubeTransport.swift`, `SearXNGDiscovery.swift`, `project.yml`.
Tests: `ThemeTests.swift`, `ReleasePerformanceTests.swift`,
`Security/BoundedHTTPBodyTests.swift` (new), `Phase12UpgradeMatrixTests.swift` (new),
`ReviewQueueUITests.swift`, `PlaylistFileImportUITests.swift`, `UITestSupport.swift`.
Build: `ci.yml`, `build-ipa.yml`, `playlist-migration.yml`, `publish-v1.2.0.yml` (new),
`Scripts/package-ipa.sh`.
Docs: README, ARCHITECTURE, BUILD_PIPELINE, KNOWN_LIMITATIONS, SIDELOADING, MIGRATIONS
and the six Phase 12 documents.

## 5. Status

Automated results, the final candidate's SHA-256 and the gate matrix are in
[PHASE_12_RELEASE_CHECKLIST.md](PHASE_12_RELEASE_CHECKLIST.md). Physical acceptance has
not yet been run, so the release is **not** approved for publication.
