# Phase 10.4.10 — Release polish, pause/resume, background reliability

## Background progress regression (device: ~100 → ~31, earlier songs searched again)

Root cause, reproduced in `MatchingPauseResumeTests.testConnectivityLossStopsEarly…`:

1. **Failed songs were reclaimed by every ordinary resume (B).** `claimMatchingEntry`
   re-claimed any occurrence whose checkpoint was `retryable`. When the phone was
   locked/suspended, in-flight and subsequent searches failed with connection-lost
   errors and were committed as `discoveryFailed` (retryable). Every relaunch/foreground
   restore then searched that whole run of songs again.
2. **Progress was rebuilt from zero (A).** Each new worker started an in-memory counter
   at 0 and counted visited entries, so the UI dropped back to the first failed song.
3. **Cleanup mislabelled the in-flight song (C).** `finishMatching` turned an
   interrupted, unsaved search into "Needs Review".

Fixes:

- Ordinary resume claims only unfinished work: never searched / in flight, provider
  deferred, checkpoint cleared (rejection) or older algorithm. Failed searches are
  retried only by **Retry Songs That Failed** or **Retry This Song**.
- Device connectivity loss is not a song failure: the song is saved as deferred, and
  after three consecutive offline songs the run stops (`systemPaused`, "Waiting for
  connection"), leaving the rest unfinished. An unreachable Invidious host is still a
  song-level failure; only the device being offline counts.
- Progress is seeded from the persisted summary and refreshed from it at most every 2 s.
- An interrupted in-flight song with nothing saved returns to `pending`
  (new `matching → pending` transition).
- Each run logs `claimed` / `skippedCompleted` via OSLog (`PlaylistMatching`).

## Pause / resume

Durable intents (`migration_matching_jobs`, migration `v015_matching_user_pause`):
`running`, `systemPaused` (auto-resume), `userPaused`, `userCancelled`, `completed`,
`fatal` (never auto-resume). Pause persists `userPaused` immediately, cancels the
in-flight request, releases the background assertion and keeps every committed
result. Foreground activation and relaunch never restart a user-paused job.

## iOS background execution

`BGContinuedProcessingTask` (iOS 26) with `beginBackgroundTask` fallback. On expiration
the in-flight request is cancelled cooperatively and the job is `systemPaused`; it
resumes from saved progress on the next foreground activation. iOS does not guarantee
arbitrary-duration background execution; no audio/location tricks are used.
