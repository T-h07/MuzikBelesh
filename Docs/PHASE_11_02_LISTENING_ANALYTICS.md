# Phase 11.2: Listening statistics, playback analytics and the activity dashboard

> **Current status (18 November 2026):** This feature is merged into the stable application and published in [Muzik Belesh v1.2.0](https://github.com/T-h07/MuzikBelesh/releases/tag/v1.2.0). Historical branch/CI/acceptance status statements below describe the original feature-implementation stage, not the current release state. The final release had 10/10 owner-reported expedited iPhone checks PASS; complete final CI was canceled with known risks accepted.


Branch: `feature/phase-11-02-analytics` (from `develop` after Phase 11.1).
Status: implemented; developer-reported physical acceptance **18/18 PASS** on 2026-11-17. Native CI incomplete (some regression jobs canceled, one running); not merged and not released.

## 1. Audit of the existing playback history

`playback_history` (v001) is **not** a reliable source of listening time:

| Finding | Effect |
| --- | --- |
| A row is inserted when a song is *selected* (`PlaybackHistoryService.started`), before audio plays | Failed or skipped selections look like plays |
| Changing tracks calls `finish()` with the default duration `0` | Almost every row records 0 ms |
| `stop()` and end of queue record `state.elapsedTime`, the **song position** | Seeking to 3:00 and stopping records three minutes |
| Replays (`recordNavigation: false`) and Repeat One are not recorded | Plays are undercounted |
| A crash leaves `completedAt` empty forever | No recovery |
| `trackID` cascades on delete | Deleting a song erases its history |

Decision: legacy history is left exactly as it is, is not migrated and is never counted. The
dashboard says: “Accurate listening time is tracked from <date>. Earlier playback isn't
included.” The date is `listening_analytics_state.trackingStartedAt`, written by the migration.

## 2. Listening-time engine

`ListeningSessionTracker` (`OFFLINE/Analytics`) is owned by `AudioPlayerService` and only
observes it. The player, queue and command gate are unchanged apart from these hooks:

| Player event | Tracker call |
| --- | --- |
| `replaceItem` (every new AVPlayerItem) | `prepare(trackID:context:continuing:)` — finalizes the previous session as `replaced` |
| Periodic time observer (`samplePlaybackTime`) | `observe(position:duration:playing:)` |
| `timeControlStatus` change (`synchronizeTransport`) | `observe` with the native time; `pause()` when not playing |
| `performSeek` | `observe` then `discontinuity()` |
| `pause`, interruption began, sleep timer expiry, failure, media-services reset | `pause()` (flush) |
| Leaving the foreground | `checkpoint()` |
| Accepted end-of-item (`completedItem`) | `finish(reason: "completed", natural: true)` |
| `stop()`, end of queue | `finish(reason: "stopped"/"ended", natural: false)` |
| `UIApplication.willTerminateNotification` | `finish(reason: "terminated")` |

**Credit rule.** Between two observations the tracker credits
`min(Δposition, Δmonotonic + 0.25 s)` only if the earlier observation was taken while playing
and the position moved forward. Consequences:

- paused, stalled and buffering time never counts (the position does not move);
- seeks never count: `discontinuity()` drops the baseline, and an unannounced jump is capped at
  the elapsed monotonic time;
- background, lock-screen and AirPods playback count, because the periodic observer keeps
  firing (every 5 s in the background) while audio plays;
- nothing is credited after termination: there are no more observations.

The monotonic clock is `ProcessInfo.systemUptime`, so wall-clock changes cannot add time.

**Persistence and recovery.** A session row is inserted only once audio has been credited, so a
selection that never plays leaves nothing. Credited time is written every 15 s of audio, on every
pause and when the app leaves the foreground. At the next launch, sessions still `active` (crash
or termination) become `recovered` with `endedAt = lastCheckpointAt`; at most 15 s of audio is
lost. Finalization updates `WHERE state = 'active'` and day totals are added in the same
transaction only when that update matched, so finishing twice, or a late write, changes nothing.

**Failure isolation.** Every write is wrapped in `do/catch`; a failure sets `lastError` and is
retried by the next flush (each write is one transaction, so retries never double count).
Analytics never throws into playback. Without storage the tracker is a no-op.

**Continuations.** Reloading the same song after a failure or a media-services reset
(`continueListening: true`) keeps the session. A replay (Repeat One, Play after the end,
restarting from a scrub to the end) is a new session.

## 3. Metrics and policy

| Metric | Definition |
| --- | --- |
| Listening time | Sum of credited milliseconds in the range (by calendar day of listening) |
| Playback starts | Sessions that produced audio, by start day |
| Qualified plays | Sessions with ≥ 30 s of audio, or ≥ 50 % of a track shorter than 60 s |
| Completed plays | Natural end of the item **and** qualified **and** ≥ 80 % of the song heard. Seeking to the end, skipping or stopping is never a completion |
| Unique songs | Distinct songs among sessions started in the range |
| Longest session | Largest single-session listening time started in the range |

## 4. Attribution

Context comes from the player's existing `contextKind` / `contextSourceID`, captured when a song
starts through navigation:

- `playlist` and `migrationPlaylist` carry `playlists.id`; both count as playlist plays, so
  ordinary and migrated playlists rank together. Duplicate occurrences, shuffle and repeat all
  keep the playlist context.
- `album`, `artist`, `library`, `liked`, `search`, `recent` and `listeningStats` are kept as
  recorded but never counted as playlist plays.
- Songs started from the manual queue (Play Next / Add to Queue) are recorded as `queue`, even
  while a playlist is the active context.
- A playback with no context (`play(trackID:)` without context IDs) is `unknown`. Nothing guesses.

## 5. Rankings

Top songs, artists, albums and playlists (5 each) are ordered by listening time in the range,
then qualified plays, then name.

- **Metadata changes.** Rankings join the library at read time, so a renamed song, or one moved
  to another artist or album, appears with its current metadata, and its history moves with it.
- **Deleted songs.** `trackID` becomes NULL (`ON DELETE SET NULL`). The time still counts in
  totals and the chart, but the song disappears from rankings. A deleted playlist disappears
  from playlist rankings. Songs whose audio is missing stay ranked and are shown as unavailable.

## 6. Ranges, days and time zones

Each credited interval is split at local midnight and stored per calendar day (`yyyy-MM-dd`) in
the time zone in effect while listening. “Last 7 Days” is today and the six previous calendar
days (30 for “Last 30 Days”), computed with `Calendar` day arithmetic, so a 23- or 25-hour
daylight-saving day is still one day. After a time-zone change, earlier days keep the day they
were listened in, and “today” follows the current zone. All Time charts switch from daily to
weekly (over 31 days) and monthly (over 26 weeks) buckets.

## 7. Interface

**Profile.** The Phase 11.1 “Listening Activity — Planned” row is replaced by a live preview of
the last 30 days: listening time, qualified plays, the most-played song and a “See Your
Listening” link. “Appearance” and “Music Sharing” stay as planned rows.

**Your Listening dashboard.** Pure-black and typographic, with each section composed
differently:

- *Hero.* Total listening time set in large rounded type over three thin rings. Each ring is a
  real ratio (active days in range, qualified share of starts, completed share of qualified
  plays) with a legend; the number moves with `numericText` on range changes.
- *Range control.* A capsule control with a sliding selection and selection haptics.
- *Figures.* Unique songs, average per active day and longest session, separated by hairlines
  rather than boxed into cards.
- *Activity chart.* Swift Charts bars with rounded ends, a dashed fine grid and drag/tap
  selection: the selected bar stays bright, the others dim, and a callout reads, for example,
  “Tuesday — 2h 14m”. Bars carry VoiceOver labels and values.
- *Highlights.* Shown only when the data exists: busiest listening day, most replayed track.
- *Top Songs.* The number-one song is presented editorially with large artwork; songs 2–5 are a
  ranked list with artwork and bars relative to the leader. Tapping an available song plays it;
  unavailable songs are dimmed and labelled and cannot be tapped.
- *Top Artists.* A featured number-one with circular artwork and share of listening, then ranked
  rows with large numerals and relative bars (values are also given in text).
- *Top Albums / Top Playlists.* Artwork carousels that open the existing album and playlist
  screens. The artwork slot is a single view, ready for Phase 11.5 mosaics.
- *Your Library.* Songs, available offline, playlists and storage used.
- *States.* “Your listening story starts here.” when nothing is recorded; a per-range message
  when only that range is empty; a lightweight skeleton while loading; an error with Try Again.

Colour comes only from `AppColors` through `ListeningStyle.accent`, so Phase 11.3 themes can
replace it in one place.

## 8. Motion and performance

- Motion is short and event-driven: rings draw once (0.9 s) when data changes, the range
  selection slides, chart data animates for 0.35 s, presses scale to 0.97. Nothing loops or
  runs off screen. With Reduce Motion, values change without animation.
- Aggregation is SQL (`SUM`, `COUNT DISTINCT`, `GROUP BY`) over indexed columns and runs on a
  detached task; views only read the last published summary, which stays visible (dimmed) while
  another range loads. A unit test aggregates 100,000 sessions.
- The dashboard does not observe the player, so playback ticks never re-render it.
- Artwork goes through the existing `ManagedArtworkView` downsampling cache. No blur layers,
  shaders or third-party UI dependencies.

## 9. Privacy

All analytics live in the local database. Nothing is uploaded, sent to analytics services or
attached to network requests, and no account is involved. The tables are separate from library
tables, so a Phase 11.4 export can include or exclude them explicitly.

## 10. Tests

- `ListeningPolicyTests`: thresholds, completion policy, formatting, midnight split,
  daylight-saving ranges, chart bucketing.
- `ListeningSessionTrackerTests`: only progressing audio counts (pause, buffering), seeks and
  jumps, no session without audio, checkpoints and crash recovery, natural end vs replacement,
  replays vs reloads, midnight crossing, write failure and retry without duplication, no storage.
- `ListeningAnalyticsRepositoryTests`: migration, idempotent finalization, distinct metrics,
  calendar ranges, rankings and playlist attribution (queue and album excluded), deleted and
  renamed songs, legacy history ignored, 100k-session aggregation.
- `ListeningPlaybackIntegrationTests` (real `AudioPlayerService`): playlist attribution and paused
  time, manual-queue attribution, unknown context, completion recorded once, seeking.
- `ListeningAnalyticsUITests`: empty states, real totals for all three ranges, rankings,
  playing the top song, opening the top playlist, large text. Screenshots are kept as CI
  attachments.
- Migration-sequence assertions now expect `v025_listening_analytics` last (24 identifiers, 25
  with the canceled v023 record). The Phase 11.1 v1.1.0 rewind also removes v025.

## 11. Physical acceptance checklist

| # | Check |
| --- | --- |
| P01 | Upgrade install keeps the library, playlists and profile |
| P02 | Fresh state shows “Your listening story starts here.” in Profile and the dashboard |
| P03 | Play 2 minutes, pause 2 minutes: listening time grows by about 2 minutes only |
| P04 | Seek forward and back: no extra time |
| P05 | Lock screen playback for 5 minutes counts |
| P06 | AirPods playback counts; removing AirPods (pause) stops counting |
| P07 | A phone call interruption stops counting and resumes after |
| P08 | Skipping a song after 10 s is a start, not a qualified play |
| P09 | A song played to the end counts as completed; scrubbing to the end does not |
| P10 | Force-quit during playback; relaunch keeps the time up to the last checkpoint |
| P11 | Playlist plays rank the playlist; Play Next songs do not |
| P12 | Migrated playlist plays rank that playlist |
| P13 | Top song tap plays it; top playlist/album/artist opens it |
| P14 | 7 / 30 / All Time totals switch correctly, chart scrubbing shows day and time |
| P15 | Listening across midnight appears on both days |
| P16 | Deleting a ranked song keeps the total and removes it from rankings |
| P17 | Large text and VoiceOver read the hero, chart and rankings |
| P18 | Playback never stutters or stops because of the dashboard or analytics |

## 12. Physical iPhone acceptance report — 2026-11-17

The developer confirmed installing the Phase 11.2 IPA and reported all **18/18** checks in the *conversation's user-facing acceptance checklist* as **PASS**. No failures or skips were reported.

| ID | User-facing test | Developer result |
| --- | --- | --- |
| P01 | Upgrade safety | **PASS** |
| P02 | Analytics navigation | **PASS** |
| P03 | Listening duration | **PASS** |
| P04 | Paused time | **PASS** |
| P05 | Seeking | **PASS** |
| P06 | Background listening | **PASS** |
| P07 | AirPods/Bluetooth | **PASS** |
| P08 | Top songs | **PASS** |
| P09 | Artist and album rankings | **PASS** |
| P10 | Playlist attribution | **PASS** |
| P11 | Spotify migration playlists | **PASS** |
| P12 | Date filters | **PASS** |
| P13 | Interactive chart | **PASS** |
| P14 | Persistence | **PASS** |
| P15 | Shuffle and repeat | **PASS** |
| P16 | Empty and historical states | **PASS** |
| P17 | Visual design | **PASS** |
| P18 | Regression | **PASS** |

**Test interpretation:** These results apply specifically to the user-facing checklist identified above. The detailed repository checklist in §11 has different ID-to-scenario mappings; no unreported edge case (such as VoiceOver, midnight-crossing, song deletion, or phone calls) should be marked independently tested solely because its number matches.

### Merge-readiness assessment

- **Physical device acceptance:** PASS — 18 reported PASS, 0 reported FAIL.
- **Unsigned IPA build:** [44154149357](https://github.com/T-h07/MuzikBelesh/actions/runs/44154149357) SUCCESS, source `70db001a3ba6fbfa816d86679f51fbd972ac7ddc`.
- **Static CI checks:** SUCCESS on [44153899214](https://github.com/T-h07/MuzikBelesh/actions/runs/44153899214).
- **Full CI:** NOT GREEN as of recording; the unit/accessibility job was in progress, and regression compact, library, and other-UI jobs were canceled. Canceled tests are **not** treated as passing or as confirmed regressions.
- **Branch compatibility:** Phase 11.2 branch ahead of `develop` by two commits, behind by zero before the acceptance documentation commit.
- **Assessment:** Functionally accepted by the physical-device tester and eligible for owner-approved integration into `develop`. If full native CI is a mandatory merge gate, final automated clearance remains outstanding. Explicitly document any decision to merge without it.
- **No merge performed during acceptance recording.** Do not promote to `release` or `main` or publish v1.2.0.
