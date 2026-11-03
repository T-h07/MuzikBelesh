# Phase 4 application stability audit

Scope: feature/phase-04-playback, PR #5 against develop. Baseline: 56dd056.
Physical acceptance remains pending; automated checks do not establish locked-device reliability.

## Architecture and initial inventory

AppContainer creates one AudioPlayerService. Library/mini-player/Now Playing and
RemoteCommandCoordinator call that same service. PlaybackQueueManager adapts SQLite
queue occurrences to PlaybackNavigationEngine. LocalAudioAssetResolver resolves
managed audio; the injected PlaybackPlayer transport uses AVPlayer in production.
SleepTimerService owns the absolute deadline and pauses the same transport.
GRDB repositories own database access. Browsing/demo stores remain separate from
the imported library; they are not a second production audio engine.

Reviewed: 57 Swift files (including the added audit tests/transport), the 14
architecture/playback/storage/test/roadmap documents requested in the audit,
project.yml, both workflows, packaging script and app/extension metadata. Source,
tests and configuration were scanned for common credential patterns; no matching
credentials were found. This is not a historical secret scan or penetration test.

Initial risks: endpoint seek/completion races, unbounded missing-history retries,
shuffle cursor reconciliation, early queue consumption, split persistence writes,
timer expiry after await, optimistic playing state, misleading demo UI, file safety.

## Confirmed bug register

| ID | Severity | Trigger / cause | Correction / evidence |
| --- | --- | --- | --- |
| AUD-01 | P1 | Single-track Shuffle + All reports Next but produces nil | Single-track cycle replay; AuditRegressionTests |
| AUD-02 | P1 | Remove a consumed shuffle ID; cursor no longer matches filtered order | Filter consumed/remaining segments separately; AuditRegressionTests |
| AUD-03 | P1 | Previous resolves removed history repeatedly | Reconcile history against available IDs and bound retry candidates; AuditRegressionTests |
| AUD-04 | P1 | Queue entry removed before resolution succeeds; snapshots can disagree | Stage candidate until item selection, commit one occurrence, save queue/state atomically; service queue test |
| AUD-05 | P1 | Seek awaits while timer expires or Pause occurs; continuation resumes playback | FIFO command gate, intent revision and timer-expired latch checked after awaits; timer/pause service tests |
| AUD-06 | P1 | Endpoint seek and completion both advance; stale callbacks update replacement | Endpoint policy before seeking, generation-bound completion and periodic callbacks, seek-result checks; endpoint/duplicate service tests |
| AUD-07 | P2 | Calling play assigns playing even while AVPlayer waits | Observe actual timeControlStatus; loading until transport plays; fake/native tests |
| AUD-08 | P1 | Self-copy or export over existing file can truncate audio | Reject before opening destination, remove new partial copy on error; StorageAuditTests |
| AUD-09 | P1 | Hash read error treated as EOF; symlink bypasses managed path boundary | Propagate read errors, resolve symlinks before containment check; storage tests |
| AUD-10 | P2 | Demo queue/metadata/preferences appear production-ready | Label demo sections/actions, disable deferred metadata editing, search real imported titles |
| AUD-11 | P2 | Extension build stays 1 while app build increases | Shared CURRENT_PROJECT_VERSION; IPA metadata validation |
| AUD-12 | P1 | Truncated artist/album IDs collide on long common prefixes | Full normalized SHA256 IDs; reuse existing exact normalized rows |
| AUD-13 | P2 | Crash during copying leaves unjournaled managed import files | Journal before copying; reconcile only UUID-owned interrupted files without track rows |

No observed data loss or physical crash is claimed. Severity describes the confirmed
failure mechanism. No database migrations or resets are introduced. Existing rows
and audio remain intact; import recovery only removes journal-owned uncommitted files.

## Test evidence and boundaries

Before fixes: commit 39d4e87, CI run
https://github.com/T-h07/MuzikBelesh/actions/runs/41642815968 failed:
three new tests, four assertions. Other baseline tests and UI smoke passed.
Those exact regression tests remain in the suite unchanged.

Intermediate run b66bb7e (41645685336) executed 54 unit tests: the four navigator
audit tests passed, but three assertions failed. The symlink test exposed that
Foundation leaves symlinks unresolved when the leaf does not exist; containment
now checks each component. Two endpoint assertions incorrectly required Repeat Off
to continue from the final indexed track. That test now starts at the first indexed
track with a valid successor, preserving its Next/playing assertions. Native AVPlayer,
timer, queue, stress and UI smoke checks passed in that intermediate run.

PlaybackServiceAuditTests uses the real service, queue and navigator with an
injected transport; six synthetic WAV fixtures exercise endpoint seeks in all
repeat modes, paused recovery, stale/duplicate completion, timer expiry inside seek,
pause during seek, nonfinite seeks, queued duplicates, and simulated remote dispatch.
A fixed 240-operation sequence covers navigation, seeking, pause/resume, shuffle,
repeat, queue edits, completion and SQLite snapshot restoration. Shuffle is injected
deterministically. A separate native AVPlayer test checks readiness and seeks at
0/1/25/50/75/99/99.9/100 percent. No copyrighted fixture audio or network is used.

Only the three navigator regressions have recorded pre-fix execution. Other fixes
have mechanism review and post-fix tests; do not describe them as recorded red/green
tests. Fake transport tests cannot demonstrate audible output or physical remotes.

## Remaining risks and deferred work

- Physical Lock Screen/Control Center/Bluetooth, multi-minute locked playback,
  interruptions, timer timing under suspension and SideStore in-place update require
  developer validation. They are not accepted by CI.
- Synthetic WAV tests do not establish every MP3/M4A/AAC codec, damaged-file,
  low-disk, process-kill or large-library performance scenario. No Instruments memory
  or energy profile was available on the Windows host.
- Metadata/artwork queries still occur during periodic publishing; profile with a
  real large library before optimizing. Export UI currently materializes file Data.
- Legacy pre-journal orphan files are intentionally not deleted automatically.
- Existing incorrect artist/album associations caused by historical ID collisions
  are preserved; metadata repair belongs to an explicit data repair operation.
- Phase 1 demo albums/playlists/settings/downloads are marked as demonstrations;
  production management and downloading remain deferred.
- Remote handler success means accepted for asynchronous processing; subsequent
  failures are published in playback state, not synchronously returned to iOS.

## Build verification

CI runs XcodeGen, dependency resolution, simulator compilation, unit/integration
tests and UI smoke. Unsigned IPA is dispatched only after successful CI, on the
same feature commit. Packaging checks bundle ID, embedded source SHA, assets and
Share extension. Final workflow URLs, build number, artifact digest and conclusion
are recorded in the PR audit handoff to avoid embedding a self-referential commit.

## iPhone 13 Pro Max acceptance (all pending)

1. Update in place with SideStore; verify About commit/build and existing six songs.
2. Start every track, including first/last, with Shuffle Off/On and Repeat Off/All/One.
3. Pause/resume, seek backward/forward and to 100%; recover with Play/Next/Previous.
4. Alternate app, Lock Screen and Control Center Next/Previous/seek; verify one
   continuous sequence and matching title/artwork/button availability.
5. Complete sequential and shuffled cycles while locked; test explicit queued
   duplicates, removal, reorder and relaunch restoration.
6. Start/cancel/reset a one-minute Sleep Timer; seek and change songs before the
   original deadline; verify actual audio pauses while locked and does not auto-resume.
7. Relaunch paused/ended states, interrupt with another app/call, disconnect headphones,
   and confirm safe recovery without reselecting from Library.
8. Verify imported bytes, queue and absolute timer deadline survive update/relaunch.

Record device/iOS, workflow SHA/build, expected/actual result and timestamps. Keep
PR #5 open; no acceptance or merge decision follows from automated tests alone.
