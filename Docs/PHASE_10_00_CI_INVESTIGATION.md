# Phase 10.0 CI investigation

PR: <https://github.com/T-h07/MuzikBelesh/pull/13>

Original source: `ac0d97a0afd4a1b44d8cc6e6acac8af746432ae0`.
Base: `897f3f7180ad31615df1d20946f0b7521d84afb4`.
Original run: <https://github.com/T-h07/MuzikBelesh/actions/runs/42262812917>.

## Findings from the original artifacts

Both attempts built successfully with Xcode 16.4 (16F6), iOS 18.5 on the
macOS 15 ARM runner. The five-file Phase 10.0 diff only adds foundation types,
validation, protocols, tests and documentation. It does not call these types
from an application service or change the library UI, playback, database,
application bootstrap, UI tests or the original CI workflow.

### Attempt 1: simulator lifecycle failure

Job `128046881019`; artifact `13526912558` (`playback-test-results`).
`CompactResults.xcresult` records 4 successful tests and 1 timeout.

- `testAlbumNameAndArtistSurviveRelaunch` continued through its restored album
  assertions and screenshot, then entered `app.terminate()` at 17:41:52 UTC.
- Its setup took 43.03 seconds; the 120-second test deadline had already
  expired at 17:41:36 during navigation after relaunch, before teardown.
- At 17:42:55, XCTest reported failure to terminate the application.
- Uploaded simulator crash reports record `SimRenderServer` trapping on its
  display capture service queue at 17:42:58, followed by `backboardd` at
  17:43:00. These are simulator processes, not an OFFLINE crash.
- The available spindump covers 17:41:38–17:41:43, **before** the termination
  call. It cannot establish the exact cause of the later termination failure.
  The renderer crashes are evidence of infrastructure instability, not proof
  that they caused the earlier timeout.
- After runner recovery, the library sort menu also incurred a 60-second
  animation-notification wait. The symptom is not unique to track metadata.

### Attempt 2: animation-quiescence wait, not an application deadlock

Job `128063173538`; artifact `13531530553` (`playback-test-results`).

- Compact suite: 5 passed, 0 failed.
- Unit/integration suite: 276 reported, **270 passed, 6 live tests skipped**, 0
  failed. The 14 Phase 10.0 tests are included in that total and all passed
  (0.089 seconds of test execution; 0.121 seconds including suite overhead).
- Full UI results: 24 passed, 1 failed. Across `TestResults.xcresult`, the
  recorded totals are 294 successes, 6 skips, 1 failure.
- The metadata test's first track-menu tap took 60.94 seconds. The runner
  received the application's event-loop-idle reply at 18:24:49.784, but logged
  `eventLoopHasIdled: YES && animationsHaveFinished: NO`.
- At 18:25:49.684, XCTest reported that its animation-completion notification
  had not arrived and continued. It then opened the editor, edited all three
  fields, saved, and found the updated title. The uploaded
  `Metadata-Editor-Draft` screenshot visibly contains the expected values.
- The second track-menu tap started at test time 85.68 seconds and encountered
  the same animation wait. The existing 120-second test deadline expired
  during that wait. The runner again continued at 146.38 seconds.
- The 18:26:41–18:26:46 spindump records OFFLINE's main thread idle in
  `CFRunLoop` / `mach_msg2_trap` in **309/309 samples**, with less than 0.001
  seconds process CPU. The UI test runner is in `tapVisible`, `XCUIElement.tap`
  and `waitForQuiescenceIncludingAnimationsIdle`, waiting via `XCTWaiter`.
- `testLikeUnlikeIsSharedWithLikedSongs` also incurred a 60-second menu wait
  but passed because it only encountered one such stall.

The verified failure mechanism is XCTest waiting for menu-animation
completion while the application's event loop is idle. The evidence does
not establish which internal UIKit/CoreSimulator component lost or retained
that animation state. No application lock, database wait, migration work or
infinite main-thread loop appears in the timeout sample. Replacing menus,
changing production animation behavior, private XCTest swizzling, or raising
the test deadline is not justified by this evidence.

## Comparison with develop

The last full develop run
<https://github.com/T-h07/MuzikBelesh/actions/runs/42217483367>
passed on `18cd2fff5f6bf0570f0958cc6601473216ae6196`. The only subsequent base
change is README documentation. Its metadata UI test passed in 45.096 seconds;
all 25 full UI tests passed, and the unit suite reported 262 tests including
6 skips and no failures. The relevant app and UI-test source is identical to
the original PR. A passing historical run alone does not exclude a flaky
environmental failure; the focused comparison below uses fresh devices.

Fresh-device controls on Xcode 16.4 / iOS 18.5, Intel runners, reproduced the
problem on **both** revisions:

| Run | Actual app source | Unique test outcomes | Recorded repetitions |
| --- | --- | --- | --- |
| [PR control](https://github.com/T-h07/MuzikBelesh/actions/runs/42273398863) | `1c03f58` (unchanged app/UI tests) | 1 passed, 3 failed | 4 passed, 3 failed |
| [develop control](https://github.com/T-h07/MuzikBelesh/actions/runs/42273393335) | `897f3f7` | 0 passed, 4 failed | 1 passed, 4 failed |

Each requested three repetitions of four existing tests. XCTest stopped some
repetitions after timeouts/runner recovery; these are **not** twelve-pass runs.
The result-bundle root metrics report four unique cases, with three and four
failures respectively. Per-test result objects contain the repetition counts
above. The zero-test summary printed by the final recovery process is not the
overall result. Both runs contain the same menu-animation notification waits;
develop also fails termination in the Like/Unlike test. Fresh-device isolation
alone is therefore not a verified remedy, and Phase 10.0 is not required to
trigger the failure.

## Rejected test-fixture experiment

`459e036` temporarily added `MB_UI_TEST_DISABLE_ANIMATIONS=1` in the library
UI-test fixture, using the public `UIView.setAnimationsEnabled(false)` API
inside the DEBUG-only isolated-library bootstrap. Assertions, event-loop
synchronization, real UI interactions and deadlines remained unchanged.

The [experiment run](https://github.com/T-h07/MuzikBelesh/actions/runs/42278768645)
did not produce a passing result. Its log contains no animation-completion
notification warnings, and all three Like/Unlike iterations passed (53.943,
44.058 and 37.786 seconds). However, album restart, metadata and persistence
tests still exceeded 120 seconds, and app launch/termination failures remained.
The metadata test was typing its third search term at 118.37 seconds; its
largest logged gap between UI activities was 5.57 seconds, rather than the
original 60-second menu stall. This is evidence of continued UI progress and
slow automation, not a new application deadlock.

The job reached its existing 40-minute limit and was cancelled. Its uploaded
bundle lacks a finalized `Info.plist`; the retained per-case objects contain
3 successes and 3 failures, but this is incomplete evidence, not an overall
suite total. The workflow log additionally records failed termination/launch
attempts. No full-suite pass or twelve-iteration pass is claimed.

**The animation setting was removed.** Although it addressed the observed
animation-notification symptom, it did not establish a reliable passing
verification path. The final application bootstrap and UI-test source are
identical to the original PR and develop. No speculative animation workaround,
private XCTest API, weakened assertion or larger timeout is retained.

## Targeted verification

The existing CI workflow now has two additional manually selected scopes:

- `foundation`: copies the real Phase 10.0 Swift files and the unchanged
  `PlaylistMigrationFoundationTests.swift` into a temporary, dependency-free
  Swift package and runs its 14 XCTest cases on the macOS host. It also takes
  the actual `LibraryIdentity`/`LibraryError` declarations from the prefix of
  `LibraryModels.swift` before `PlaylistMembership`, omitting only the unused
  GRDB import in that prefix. No hashing implementation is mocked or duplicated
  in the script; changes to the boundary fail the harness setup. It uses Swift
  5 language mode, matching the app project. No simulator, XcodeGen, GRDB build,
  application launch, test rewrite or substitute implementation is involved.
  This checks the contracts only; the iOS build and integration gate remains
  necessary. The script also runs locally on a Mac with
  `bash Scripts/test-playlist-migration-foundation.sh`.
- `library-menu`: the existing metadata/save/cancel/search, Like/Unlike,
  metadata/liked-state restart, and album name/artist restart tests, each
  repeated three times. Repetition runs every iteration; it is not retry-until-
  success. Assertions and existing 120-second maximum allowances are unchanged.

The menu scope creates a dedicated simulator of the selected device type/runtime,
waits for boot completion, disables parallel test workers, preserves its
`.xcresult` bundle, and shuts down/deletes only the device it created.
`compare_develop=true` checks out develop for the menu scope and logs its exact
commit. It is rejected for other scopes to prevent a misleading foundation
comparison on a branch where the suite does not exist. Foundation logs and
the exact source SHA are retained as `foundation-contract-results`.

Examples:

```sh
gh workflow run ci.yml --ref feature/phase-10-00-foundation \
  -f verification_scope=foundation -f runner_label=macos-15-intel
gh workflow run ci.yml --ref feature/phase-10-00-foundation \
  -f verification_scope=library-menu -f runner_label=macos-15-intel
gh workflow run ci.yml --ref feature/phase-10-00-foundation \
  -f verification_scope=library-menu -f runner_label=macos-15-intel \
  -f compare_develop=true
```

`macos-15` remains available. The Intel pool is the existing capacity fallback;
cross-architecture success alone does not prove an ARM simulator defect.
Push/PR runs and `complete` still execute the original full test gates. No tests
were removed, skipped, weakened, or assigned larger timeouts. Diagnostic
concurrency groups distinguish scope and baseline so comparisons do not cancel
one another. No release branch, application identity or playback behavior is
changed.

Diagnostic jobs have distinct check names; a passing focused run must not be
mistaken for the full `build-and-test` regression gate.

## Verification status

The direct foundation run
<https://github.com/T-h07/MuzikBelesh/actions/runs/42277955445> passed on
`067fa4f` with **14 tests, 0 failures, 0 skips**, 0.019 seconds test execution
(0.022 seconds including top-level overhead), and a 79.86-second clean SwiftPM
build. It used Apple Swift 6.1.2 on the Intel macOS runner, in Swift 5 language
mode. The original iOS run had independently passed the same 14 tests.

An earlier harness run (`42276011117`) failed to compile because its source
closure omitted the production `LibraryIdentity` dependency. This was a
harness error, corrected by including the actual source declarations;
no application or test assertion was modified. The initial simulator-backed
foundation diagnostic (`42273388735`) was cancelled during compilation and
superseded by the fast host gate; it supplies no test-pass evidence.

## Merge readiness and remaining blocker

**Do not merge PR #13 yet.** The foundation contracts pass on iOS and in the
new fast host gate, and the controlled comparison does not implicate Phase
10.0 as the cause of the legacy UI failures. However, a clean full regression
pass on the final branch has not been obtained. The unresolved blocker is
simulator/XCTest animation tracking, launch/termination instability and slow
automation; the exact internal platform defect has not been localized.

The retained changes are CI diagnostics, a verified direct contract-test
script and this report. The four original diagnostic cases and all full-suite
assertions remain available, with their original time limits. No application,
library, playback, signing, bundle-ID or release-branch change remains from
this investigation. PR #13 stays open and unmerged.

The next bounded investigation is to run the menu scope on a healthy macOS
runner and compare an explicitly recorded Xcode/simulator runtime, retaining
diagnostics for any animation-notification failure. A full regression pass is
still required before declaring the branch merge-ready. Repeating the entire
UI suite or increasing deadlines without that evidence is not a remedy.

The new workflow has passed local YAML parsing, embedded Bash syntax checks,
and `git diff --check`. XCTest requires the macOS CI runners; it was not run
on the Windows development host.

## Alternative environment comparison (2026-11-07)

The published [ARM runner inventory](https://github.com/actions/runner-images/blob/main/images/macos/macos-15-arm64-Readme.md)
and [Intel runner inventory](https://github.com/actions/runner-images/blob/main/images/macos/macos-15-Readme.md)
list Xcode 16.0, 16.1, 16.2, 16.3, 16.4, 26.0.1, 26.1.1, 26.2 and 26.3.
Installed iOS runtimes are 18.5, 18.6, 26.0.1, 26.1 and 26.2. SDK availability
does not imply that the corresponding older simulator runtime is installed.

The bounded candidate is **macos-15 ARM, Xcode 26.2 (17C52), iOS 26.2,
iPhone 16 Pro Max**. This changes both XCTest and the simulator runtime;
success would validate the combination, not isolate which component matters.
The inventory also lists iPhone SE (3rd generation) for this runtime, retaining
the possibility of the existing compact regression gate. Runtime availability
and actual toolchain versions must be confirmed on the allocated workers.

The manual `environment-comparison` scope runs the unchanged metadata
save/cancel/search and album name/artist relaunch tests once each, on both
the dispatched head and pinned develop `897f3f7180ad31615df1d20946f0b7521d84afb4`.
Both jobs use the same explicit Xcode path, runtime, device type and fresh-device
lifecycle. No retry or animation workaround is enabled. Existing 60/120-second
test allowances remain; the diagnostic test step additionally has an eight-minute
wall-clock cap to bound lifecycle recovery. Diagnostic check names cannot stand
in for the complete regression gate.

The jobs retain source SHA, runner image/architecture, OS and toolchain versions,
runtime inventory, test log/timing, result bundle, exported test summaries and
XCTest diagnostics/attachments for 30 days. Missing prerequisites fail before
the expensive build. The normal CI environment remains unchanged until the
comparison provides evidence supporting a switch. A failed comparison stops
further full-suite reruns; a successful comparison is only a prerequisite for
one complete regression run, not proof of merge readiness.

### Comparison result and full-suite candidate

[Run 42367762796](https://github.com/T-h07/MuzikBelesh/actions/runs/42367762796)
passed on both sources, without retries:

| Source | Job | Album relaunch | Metadata save/cancel/search | Result |
| --- | --- | --- | --- | --- |
| Head `6da871d` (application/tests unchanged from `6a5ea4f`) | [128389337247](https://github.com/T-h07/MuzikBelesh/actions/runs/42367762796/job/128389337247) | 71.249 s | 64.103 s | 2 passed, 0 failed, 0 skipped |
| Develop `897f3f7` | [128389337469](https://github.com/T-h07/MuzikBelesh/actions/runs/42367762796/job/128389337469) | 85.187 s | 64.500 s | 2 passed, 0 failed, 0 skipped |

Both workers actually used image `20261104.0514.1`, ARM64, macOS 15.8.2
(`24H232`), Xcode 26.2 (`17C52`), Swift 6.2.3, XcodeGen 2.46.0 and iOS 26.2
(`23C54`). Their fresh iPhone 16 Pro Max simulator IDs were respectively
`C7E9B98B-093F-46D2-9B79-6651F49AA3B9` and
`EF463C04-A955-466A-B094-5FB79385A971`. Test execution totals were 135.352 s
and 149.688 s; the surrounding xcodebuild invocations took 232 s and 350 s,
excluding the explicit simulator boot. Startup overhead varies across workers.

Neither exported runner session contains an animation-notification timeout or
failed termination. The largest gaps between logged test activities were
18.44 s and 12.59 s, both during app launch, not a 60-second menu-idleness wait.
Each runner does record the existing five-second `mini-player` lookup expiring;
the alternative `Open Now Playing` lookup then succeeds, as the unchanged
assertion permits. These are passing assertions, not suppressed failures.

Evidence artifacts are `environment-comparison-head` (`13572119438`,
5,178,958 bytes) and `environment-comparison-develop` (`13573160322`,
5,172,749 bytes), containing complete result bundles plus exported summaries,
diagnostics, attachments, provenance and logs. Local copies are retained in
the ignored `build/phase10-ci-evidence/environment-{head,develop}` directories.

This small comparison supports one full regression attempt; it does not prove
long-term simulator reliability. The full-suite candidate explicitly pins
Xcode 26.2/iOS 26.2, creates fresh devices of the existing Pro Max/SE/standard
sizes, and uses serial XCTest execution as in the comparison. Only one device
is booted at a time. It records provenance and exports summaries/diagnostics
for every result bundle. Reused products must match source, Xcode build, SDK
and architecture. No application code, assertion or test allowance changes.
