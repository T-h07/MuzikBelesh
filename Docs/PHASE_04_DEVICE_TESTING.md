# Phase 4 physical retest

**END-OF-TRACK RECOVERY REWORK — AWAITING PHYSICAL DEVICE RETEST.**
Rejected: iPhone 13 Pro Max, 0.1.0 (61), `dda2d0a`. Simulator results do not
constitute acceptance.

1. Update in place through SideStore using the delivered IPA. Verify Settings
   version/build/commit against its workflow manifest. Check the six imported
   songs and queued occurrences remain. Do not delete the app.
2. Settings / Diagnostics / Clear, then return to playback. With Repeat All,
   complete a song without seeking and after seeks to 25%, 50%, 90% and 100%.
   Verify exactly one transition. Repeat while locked/backgrounded and with
   representative imported codecs; record timestamps for any discrepancy.
3. Shuffle On, Repeat Off: finish a cycle (its final Library index can be random).
   Verify the completed message and stopped audio. Test each recovery on a fresh
   exhausted cycle: Play restarts the song, Previous plays the previous history
   entry, manual Next starts a new cycle. Repeat with Shuffle Off: sequential
   final Next has no successor; Play/Previous remain usable.
4. Repeat One replays the current song. Repeat All completion and Play at an ended
   boundary advance/wrap in context. Previous at EOF follows the active mode:
   Library order with Shuffle Off, actual history with Shuffle On, then restart
   if no predecessor exists. Ordinary playback retains the three-second rule.
5. Repeat app/Lock Screen/Control Center Play, Next, Previous and seek. Alternate
   rapid skips near EOF; compare actual audio, titles, progress and enabled buttons.
   Recover from paused/loading/failed states without choosing an unrelated song
   or restarting the app.
6. Queue duplicate occurrences; consume only one per selection. Reorder/delete,
   relaunch after EOF, and check saved position, shuffle order/history, modes and
   queue. Check existing audio survives the in-place update.
7. Set a one-minute Sleep Timer, seek/skip near expiry and verify actual audio
   stops while locked. Delayed EOF/seek callbacks must not restart it. Test calls,
   other-app interruptions and unplugging headphones. Explicit Play after timer
   expiry is an intentional user request to resume.
8. If it sticks, **do not relaunch**. Open Settings / Diagnostics; inspect current
   state, then Copy trace or Export trace. Save the JSON text through the share
   sheet and provide device/iOS/build/commit/workflow, action order and failure
   time. Copy expires in five minutes. The last 300 events are session-only;
   Clear/process exit removes them. Track identifiers are pseudonyms and no
   titles, file paths or secrets are included.

Keep PR #5 open. Physical iPhone acceptance is required before merge; no develop
merge, release changes or Phase 5 work are authorized in this rework.


## Previous/index-boundary retest after build 62

Build `e8dc874` is the reported baseline for this follow-up; validate the new IPA
version/build/SHA against PR #5. Do not infer Shuffle state from older screenshots.

- Confirm the indexed Library order: Future first, Peso second, then C and D.
  With Shuffle Off and Repeat Off, play Peso then select Future. At 10 seconds,
  Previous restarts Future. Near zero, Previous remains on Future (and may be
  disabled); it never navigates backward to Peso or wraps. Select Peso and press
  Previous near zero: Future plays even if the preceding history entry was D.
- With Shuffle On, play Peso -> Future -> C. Previous from C reaches Future.
  Above three seconds it restarts Future; near zero it goes back to Peso. Repeat
  with Repeat Off and All. With no prior playback history, no indexed predecessor
  is invented. Repeat Off must preserve valid history.
- Toggle On -> Off at Future with Peso in history: the first-index boundary applies.
  Toggle Off -> On: actual history becomes available. After sequentially moving
  Peso -> Future with unrelated earlier history, enable Shuffle; Previous goes
  back to the actually played Peso, with no cursor jump to a different song.
- Relaunch with persisted history and repeat app and Lock Screen Previous at 10s
  and near zero. Check enabled buttons agree. With Shuffle Off and Repeat All,
  verify forward and backward Library wrapping; with Shuffle On, verify history
  traversal and continued forward shuffled playback.
- Recheck endpoint Play/Next/Previous recovery, the locked Sleep Timer and queue
  restoration. If anything differs, export Diagnostics before relaunching and
  include `navigationPolicy`, device/iOS/build/action order and timestamps.
