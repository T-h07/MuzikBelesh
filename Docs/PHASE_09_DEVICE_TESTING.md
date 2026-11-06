# Phase 9 physical-device acceptance

All candidate results are **NOT RUN**. Accepted Phase 8 build 189 is historical evidence only. Complete this record against the exact delivered IPA; do not infer radio, thermal or signing success from simulator tests.

Session: tester ___; date/time ___; IPA SHA-256 ___; source commit ___; build ___; device ___; iOS ___; prior build/signing identity ___; ambient conditions ___; battery health ___; available storage ___; library count ___. Each case inherits these fields unless an override is recorded.

## P0 — In-place update over build 189

- Setup: Installed accepted build 189; record signing identity and export a few representative tracks as a recovery reference.
- Procedure: Record counts/settings/screenshots; install candidate over existing app via same SideStore identity; launch once.
- Expected: No uninstall or new empty container; launch and library usable.
- Actual: NOT RUN. Status: NOT RUN.
- Build/device/iOS: session fields above; overrides ___. Evidence/screenshots/logs: ___.

## P1 — Library and metadata preservation

- Setup: Record several edited songs, artwork, albums, playlists, likes, queue and positions before P0.
- Procedure: Compare after update; export the same representative songs and compare SHA-256 with pre-update copies; edit a title/artwork and relaunch.
- Expected: All saved data survives; edits persist; original exported audio hashes unchanged.
- Actual: NOT RUN. Status: NOT RUN.
- Build/device/iOS: session fields above; overrides ___. Evidence/screenshots/logs: ___.

## P2 — Full 15-feature acceptance

- Setup: Use PHASE_09_FEATURE_MATRIX and authorized media.
- Procedure: Exercise F01–F15; record a separate result per row and linked evidence; include empty albums and safe deletion.
- Expected: Every mandatory capability passes; no placeholder or hidden fixture data.
- Actual: NOT RUN. Status: NOT RUN.
- Build/device/iOS: session fields above; overrides ___. Evidence/screenshots/logs: ___.

## P3 — 60-minute local playback

- Setup: Downloaded/imported queue longer than one hour; normal power, stable environment.
- Procedure: Play for 60 minutes with screen on at fixed brightness; sample state at 0/15/30/60 min and use controls.
- Expected: No hang, silence tail, unintended stop, or growing timeline error; record battery/thermal.
- Actual: NOT RUN. Status: NOT RUN.
- Build/device/iOS: session fields above; overrides ___. Evidence/screenshots/logs: ___.

## P4 — Extended locked playback

- Setup: Offline queue/repeat, enough charge, not charging for baseline.
- Procedure: Run a 30-minute locked session, then a separate two-hour session; check Lock Screen controls and end-state.
- Expected: Continuous audio and correct metadata/position; no repeatable severe heat or crash.
- Actual: NOT RUN. Status: NOT RUN.
- Build/device/iOS: session fields above; overrides ___. Evidence/screenshots/logs: ___.

## P5 — AirPods/Bluetooth changes

- Setup: Paired AirPods plus another Bluetooth device if available.
- Procedure: Play/pause/next/previous from accessory; disconnect while playing and immediately after selecting a track; reconnect; switch speaker/accessory.
- Expected: Disconnect pauses including waiting audio; reconnect alone does not play; explicit Play works on selected route.
- Actual: NOT RUN. Status: NOT RUN.
- Build/device/iOS: session fields above; overrides ___. Evidence/screenshots/logs: ___.

## P6 — Interruptions and resume

- Setup: Playback plus another phone/alarm/Siri source.
- Procedure: Receive/decline call, invoke Siri and alarm; pause manually during an interruption; verify eligible resume separately. If Developer Settings supports Reset Media Services, reset during playback then tap Play.
- Expected: System policy honored; manual pause never overwritten; reset leaves app paused/recoverable with retained track/position.
- Actual: NOT RUN. Status: NOT RUN.
- Build/device/iOS: session fields above; overrides ___. Evidence/screenshots/logs: ___.

## P7 — Shuffle/repeat/seek stress

- Setup: At least ten songs and duplicate explicit queue entries.
- Procedure: For each repeat mode, rapidly issue 30 next/previous/seek operations with shuffle on/off; test first/last song and seek to end; restart app.
- Expected: No unintended repeats/skips, stuck gate or corruption; prior navigation policy and queue order survive.
- Actual: NOT RUN. Status: NOT RUN.
- Build/device/iOS: session fields above; overrides ___. Evidence/screenshots/logs: ___.

## P8 — Locked sleep timer

- Setup: Playing local audio.
- Procedure: Set shortest timer, lock and wait through deadline; repeat after background/foreground and relaunch; test cancel.
- Expected: Pauses at deadline, persisted timer reconciles, cancellation prevents expiry; no surprise resume.
- Actual: NOT RUN. Status: NOT RUN.
- Build/device/iOS: session fields above; overrides ___. Evidence/screenshots/logs: ___.

## P9 — Wi-Fi-only

- Setup: Setting enabled, cellular available, record queued jobs.
- Procedure: Leave Wi-Fi; enqueue/retry; toggle Wi-Fi back on; repeat while a native task is active.
- Expected: No new cellular media transfer while restricted; waiting reason and recovery are correct.
- Actual: NOT RUN. Status: NOT RUN.
- Build/device/iOS: session fields above; overrides ___. Evidence/screenshots/logs: ___.

## P10 — Permitted cellular

- Setup: Explicitly turn Wi-Fi-only off; small authorized track.
- Procedure: Disable Wi-Fi, download on cellular, background app, return; restore preferred setting.
- Expected: Allowed transfer completes once; preference persists and data is playable.
- Actual: NOT RUN. Status: NOT RUN.
- Build/device/iOS: session fields above; overrides ___. Evidence/screenshots/logs: ___.

## P11 — Airplane/network recovery

- Setup: Queued and active transfers.
- Procedure: Enable Airplane Mode; use local music; disable it and reconnect; retry failed work; switch Wi-Fi/cellular in permitted and restricted modes.
- Expected: Local music continues; actionable states; no duplicate import or permanent stuck job.
- Actual: NOT RUN. Status: NOT RUN.
- Build/device/iOS: session fields above; overrides ___. Evidence/screenshots/logs: ___.

## P12 — Native suspension/restoration

- Setup: Several authorized downloads; Wi-Fi stable.
- Procedure: Start transfers, open another app/lock for several minutes; return; repeat with OS-driven relaunch if naturally observed.
- Expected: OS-owned work reconciles to correct jobs; import occurs once; identities/progress remain consistent. Record if no true OS termination was exercised.
- Actual: NOT RUN. Status: NOT RUN.
- Build/device/iOS: session fields above; overrides ___. Evidence/screenshots/logs: ___.

## P13 — Restart/force-quit

- Setup: Saved playback queue and active downloads.
- Procedure: Relaunch normally, then separately swipe-kill during a transfer and reopen manually.
- Expected: Paused playback restored safely; native tasks reconciled, completed music preserved; no claim that force-quit allows continued background transfer.
- Actual: NOT RUN. Status: NOT RUN.
- Build/device/iOS: session fields above; overrides ___. Evidence/screenshots/logs: ___.

## P14 — Duplicates/missing files

- Setup: Two identical files and distinct recordings with similar tags; disposable test song.
- Procedure: Import identical bytes twice and distinct recordings; exercise missing-file UI only using a disposable unavailable file fixture; restore/reimport.
- Expected: Exact duplicate detected without extra music; distinct tracks retained; missing source shows recoverable error, no crash.
- Actual: NOT RUN. Status: NOT RUN.
- Build/device/iOS: session fields above; overrides ___. Evidence/screenshots/logs: ___.

## P15 — Playlists/large library

- Setup: Multiple playlists; record actual library size (100/1k/5k/10k when available).
- Procedure: Search, sort, scroll to last row; reorder 100 entries, edit album, play/shuffle collections, delete one playlist and relaunch.
- Expected: Responsive UI, stable order/search, no missing songs; report unavailable sizes NOT RUN.
- Actual: NOT RUN. Status: NOT RUN.
- Build/device/iOS: session fields above; overrides ___. Evidence/screenshots/logs: ___.

## P16 — YouTube/Safari share

- Setup: Candidate installed with extension; no pending inbox.
- Procedure: Share supported links from YouTube and Safari; dismiss extension, manually open app; repeat rapidly and while audio plays; include invalid link.
- Expected: One validated details handoff per entry, no automatic download, clear rejection of invalid input, ongoing audio preserved.
- Actual: NOT RUN. Status: NOT RUN.
- Build/device/iOS: session fields above; overrides ___. Evidence/screenshots/logs: ___.

## P17 — Offline duration/playback

- Setup: Known affected M4A songs (189.707 s and 169.715 s) and unrelated audio.
- Procedure: Airplane Mode; compare displayed duration, seek near audible end, let playback advance; export and compare hash to original.
- Expected: Correct evidence-based duration, no doubled silent tail, unrelated durations intact, original bytes unchanged.
- Actual: NOT RUN. Status: NOT RUN.
- Build/device/iOS: session fields above; overrides ___. Evidence/screenshots/logs: ___.

## P18 — Screens/accessibility

- Setup: Normal and largest practical Dynamic Type; VoiceOver; available iPhone sizes.
- Procedure: Navigate every tab, Library/YouTube Search and details; scroll to Load More with mini-player active and tap; open/dismiss player repeatedly; test labels/focus, contrast, keyboard and reduced motion.
- Expected: Last row/actions visible; controls reachable with adequate targets; readable labels/focus; document unavailable devices.
- Actual: NOT RUN. Status: NOT RUN.
- Build/device/iOS: session fields above; overrides ___. Evidence/screenshots/logs: ___.

## P19 — Low-storage recovery

- Setup: Disposable test media and naturally low-storage test device or controlled simulator injection.
- Procedure: Attempt import/download/export/artwork save near available capacity; cancel/retry after freeing expendable space; reopen library.
- Expected: Actionable failure; no partial indexed track or original deletion; existing library remains usable. Do not fill the user's phone solely for testing.
- Actual: NOT RUN. Status: NOT RUN.
- Build/device/iOS: session fields above; overrides ___. Evidence/screenshots/logs: ___.

## P20 — Playback battery/thermal

- Setup: Controlled scenarios A–C, brightness/network/charge recorded.
- Procedure: Run idle, screen-on browsing and locked playback protocol; sample battery, Diagnostics thermal and responsiveness.
- Expected: Low avoidable overhead; no repeatable app-attributable serious/critical pressure; observations separated from measured CPU.
- Actual: NOT RUN. Status: NOT RUN.
- Build/device/iOS: session fields above; overrides ___. Evidence/screenshots/logs: ___.

## P21 — Download thermal

- Setup: Scenarios D/E with authorized downloads.
- Procedure: Compare one/several transfers and playback plus transfer; observe Diagnostics and queue; if pressure occurs naturally, stop stress and observe deferred scheduling/recovery.
- Expected: No audio regression; new work defers under serious/critical pressure and resumes on recovery; active tasks remain OS-managed.
- Actual: NOT RUN. Status: NOT RUN.
- Build/device/iOS: session fields above; overrides ___. Evidence/screenshots/logs: ___.

## P22 — Low Power Mode

- Setup: Queue concurrency preference >1; scenario F.
- Procedure: Enable LPM before queueing; play audio, check Diagnostics and effective single new transfer; turn LPM off and verify concurrency preference.
- Expected: Music continues, reduced scheduling/cadence, original preference preserved, queued work resumes.
- Actual: NOT RUN. Status: NOT RUN.
- Build/device/iOS: session fields above; overrides ___. Evidence/screenshots/logs: ___.

## P23 — Lifecycle stress

- Setup: Playback and a queued/active transfer.
- Procedure: Repeat 30 foreground/background/lock cycles; present/dismiss player/settings/details 30 times; inspect saved queue and completion, record memory if tooling allows.
- Expected: No duplicate observer effect, stalled UI, growing retained-state trend or duplicate imports.
- Actual: NOT RUN. Status: NOT RUN.
- Build/device/iOS: session fields above; overrides ___. Evidence/screenshots/logs: ___.

## P24 — IPA/signing/update integrity

- Setup: Delivered IPA and manifest from final run.
- Procedure: Compute SHA-256; compare exact commit/version/build; inspect both executable group metadata; SideStore signs with existing identity; verify app and extension after update.
- Expected: 1.0.0, build >189, identities/group consistent, both binaries verified; actual device signing and data continuity pass.
- Actual: NOT RUN. Status: NOT RUN.
- Build/device/iOS: session fields above; overrides ___. Evidence/screenshots/logs: ___.

## Controlled thermal protocol A–F

A: idle Home for five minutes. B: locked offline playback for 30 minutes and a separate two hours. C: playback while browsing Library, Search, Albums and Playlists for 15 minutes. D: several Wi-Fi downloads for a recorded interval. E: local playback plus one transfer. F: repeat B or E with Low Power Mode on.

For each, record start/end battery %, exact elapsed time, screen/brightness, charging status, Wi-Fi/cellular, LPM, Diagnostics thermal state at start/during/end, subjective warmth separately, response delays, crashes and forced stops. Keep brightness, ambient conditions and charging consistent. A charging session cannot be the only baseline. Stop stress if uncomfortably hot or serious/critical pressure appears; investigate under normal conditions. Never artificially heat the phone.

| Scenario | Duration | Battery start/end | Thermal start/peak/end | Conditions/evidence | Result |
|---|---|---|---|---|---|
| A Idle | — | — | — | — | NOT RUN |
| B Locked playback | — | — | — | — | NOT RUN |
| C Browsing/playback | — | — | — | — | NOT RUN |
| D Downloads | — | — | — | — | NOT RUN |
| E Download/playback | — | — | — | — | NOT RUN |
| F Low Power Mode | — | — | — | — | NOT RUN |

Acceptance requires no reproducible application-induced severe thermal problem or excessive avoidable battery drain in ordinary local playback, and no corruption, glitches or background transfer regression from optimizations. Missing tooling must be reported as NOT MEASURED. See [performance methods](PHASE_09_PERFORMANCE.md), [feature matrix](PHASE_09_FEATURE_MATRIX.md) and [release gates](PHASE_09_RELEASE_CHECKLIST.md).
