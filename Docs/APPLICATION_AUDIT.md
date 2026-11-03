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


## Phase 4 incident: rejected physical build 61 (2026-11-03)

Rejected source: `dda2d0a5a612c54c2b2a76ae2e579037603c8dc8`, version 0.1.0,
iPhone 13 Pro Max, SideStore installation. The developer reports reaching EOF
after seeking leaves Play/Next/Previous ineffective; selecting another Library
track restores control. IMG_1735-1739 show disabled skips and stopped positions
4:56/4:57 and 3:43/3:46 with Shuffle/Repeat enabled. Earlier 56 unit/integration
tests and one UI test did **not** establish physical acceptance; it is withdrawn.

### Confirmed source defects and attribution limits

- `completedItem` rejected a current-generation EOF notification if
  `native.currentTime < state.duration - 0.25`. A valid decoder event could thus
  leave playback intent true with no successor or terminal transition. Injecting
  a current-item event with a lagging clock reproduces this rejection. Identity,
  generation, duplicate tracking, seek revision and intent now decide acceptance;
  EOF no longer requires two floating point duration estimates to agree.
- Previous checked elapsed time before terminal status. Above three seconds it
  sought to zero while playback intent was false, leaving transport stopped and
  ignoring history. Terminal Previous now follows history and plays, or reloads
  the current song if there is no predecessor. Active playback retains the
  three-second restart rule.
- Shuffle/Repeat Off correctly exhausted an order that can finish at any Library
  index. But manual Next and its capability query used that same exhausted policy,
  disabling recovery in-app and on Lock Screen. Navigation APIs now explicitly
  separate automatic and manual reasons. Only automatic completion stops; manual
  Next starts another shuffle cycle, excluding the current song when possible.
- The old restart path silently returned after a cancelled seek. Terminal replay
  now loads a fresh asset/item and reports recoverable failures. Its generation
  isolates late endpoint callbacks. Playing status still follows actual transport,
  rather than being assigned optimistically.

These source mechanisms are confirmed; the exact clock/order on the rejected
phone remains unknown because no device trace was captured. The screenshots do
not prove which guard fired. Indefinite gate waiting, a stuck seeking flag and
SQLite loss are not established physical causes. Native seeks and asset inspection
now have five-second deadlines, gate waiters a ten-second deadline; rejected waits
are removed, and queued completions retain their generation/seek token for retry.
These are safeguards, not additional claims about the physical incident.

### Explicit recovery and persistence policy

Play at EOF: Repeat Off/One reload the current song at zero; Repeat All advances
in the active context. Ended Previous follows history then falls back to restart.
Manual Shuffle Next starts a new cycle even with Repeat Off; automatic EOF stops.
Sequential Repeat Off still has no successor at its final indexed song.
Terminal replay neither duplicates navigation history nor consumes explicit queue
occurrences. Candidates commit after successful selection; existing atomic
SQLite state/queue snapshots remain. No migration, reset, bundle ID change or
Phase 5 work is introduced. The database stores position rather than the `.ended`
enum; restored terminal positions load paused and use the same Play policy.

### Diagnostics and test evidence

Settings / Diagnostics shows current state and the latest 300 session events in
Release builds as well as Debug. Fields include operation UUID/source, generation,
session-pseudonymous track, actual/stored time and duration, item/transport state,
before/after status via begin/end events, playback intent, completion token,
intent/seek revision, gate owner, shuffle/repeat cursor/history and automatic/manual
capabilities. Arrival, acceptance/ignore reasons, rejected commands, timer expiry
and recovery outcomes are explicit. No titles, filenames, paths, raw system errors
or credentials are exported. Clear/process exit removes the buffer. Copy is
local-only with five-minute expiry; Export shares JSON on explicit user action.

Regression tests first land separately at `3bc53d2` against unfixed source.
[Baseline CI](https://github.com/T-h07/MuzikBelesh/actions/runs/41655280715)
ran 59 unit/integration tests and one passing UI test: two new cases failed with
four assertions (current-item notification rejection; exhausted-shuffle manual
capability/selection/transport recovery). The Previous regression was subsequently
strengthened to six-second audio and a four-second seek to exercise the >3s rule.
The final suite adds injectable transport state/command matrices, real AVPlayer
natural EOF at 0/25/50/90%, lagging-clock event injection, endpoint duplicate
rejection, gate-occupied completion, remote dispatch, shuffled history/capabilities,
terminal snapshot recovery, queue/data preservation and timer protection. CI
retains xcresult with bounded test timeouts. IPA packaging checks app/extension
version/build and embedded SHA, and emits a SHA256 manifest. Exact final workflow
URLs/commit/manifest are delivered separately to avoid self-referential provenance.

Actual locked/background playback, hardware remotes, imported codecs and SideStore
in-place update remain **unverified until physical retest**. Export diagnostics
before relaunch if the failure recurs; include device/iOS/build/SHA and the time.

**FINAL STATUS: PHASE 4 END-OF-TRACK RECOVERY REWORK — AWAITING PHYSICAL DEVICE RETEST.**
