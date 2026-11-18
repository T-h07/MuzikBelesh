# Phase 12 — performance and resource report (v1.2.0)

This report compares the Phase 11.5 baseline (the state of `develop` before Phase 12)
with the Phase 12 release candidate, using only measurements that were actually taken.
Anything not measured is marked **NOT RUN**.

## Environment and limits

- All numbers come from XCTest on GitHub-hosted `macos-15` runners, Xcode 26.2, iOS 26.2
  simulator. Simulator timings reflect algorithmic cost and database work, **not** iPhone
  CPU, battery or thermal behaviour. Shared runners vary by roughly ±20 % between runs.
- The baseline is taken from the Phase 11.5 CI log (`develop`, run 44290264115 / #298).
- The Phase 12 values come from the final Phase 12 CI run listed in
  [PHASE_12_RELEASE_CHECKLIST.md](PHASE_12_RELEASE_CHECKLIST.md) (G03/G11).

## Decision: no hot-path rewrites in Phase 12

The audit looked for avoidable work in playback, the clock, library lists and search,
analytics and artwork. The measurements below show every hot path already well inside
interactive budgets at 10,000 songs, and the one apparent "regression" (writes per
playback minute) is correct, intended Phase 11.2 behaviour. A rewrite close to release
would add risk without a demonstrated benefit, which the Phase 12 rules forbid. Phase 12
therefore changed only:

1. **Bounded HTTP reads** (security S01) — caps peak memory for metadata responses at
   8 MB / 4 MB instead of "whatever the server sends".
2. **Theme re-selection** — selecting the already-active theme no longer saves or
   publishes; before, every tap published `lastError = nil` and re-rendered observers.
3. **A precise playback-minute budget test** that classifies every SQL statement, so a
   future extra read or write is caught by name.

## Playback clock — one minute of playback

The test drives 120 half-second ticks (60 s of audio) through `AudioPlayerService` with a
recording SQL tracer.

| Measure | Phase 11.5 baseline | Phase 12 | Budget |
| --- | --- | --- | --- |
| Work time for 60 s of ticks | 0.0258 s | _see below_ | — |
| `@Published` state publications | 122 | _see below_ | ≤ 123 |
| SELECT statements | 0 | _see below_ | 0 |
| Position checkpoint writes | 12 (counted together) | _see below_ | exactly 12 (one per 5 s) |
| Listening-analytics writes | 3 (counted together) | _see below_ | 1 + 2 per 15 s checkpoint |
| Other writes | 0 | _see below_ | none |

**Root cause of the baseline CI failure (15 vs 12 writes):** the old test assumed only
position checkpoints. Since Phase 11.2, each 15 s of credited listening also inserts or
updates the listening session and upserts the daily total — legitimate writes. The test
now names each category and derives the analytics budget from
`ListeningPolicy.checkpointMs` and the credited milliseconds, with an injected monotonic
clock so the result no longer depends on how fast the runner is.

## Library scale (Phase 9 harness)

| Songs | Navigation (s) baseline | Navigation (s) Phase 12 | Search (s) baseline | Search (s) Phase 12 |
| --- | --- | --- | --- | --- |
| 100 | 0.0000668 | _see below_ | 0.00209 | _see below_ |
| 1,000 | 0.000405 | _see below_ | 0.0136 | _see below_ |
| 5,000 | 0.00178 | _see below_ | 0.0690 | _see below_ |
| 10,000 | 0.00379 | _see below_ | 0.135 | _see below_ |

Other baselines (Phase 11.5 CI): SQLite 10,000-song snapshot + search 0.198 s; XCTest
search `measure` average 0.164 s (RSD 11 %), peak memory ≈ 100 MB in the test process.
Phase 11.4 documented a 10,000-song `.mbelesh` decode of 0.71 s and a 10,000-occurrence
preview + commit of 2.93 s; Phase 12 did not change that code.

## Memory and resources

| Area | Finding |
| --- | --- |
| HTTP metadata | Unbounded buffering removed (S01); peak per response now ≤ 8 MB / 4 MB. |
| Theme | No publication when re-selecting the active theme (unit test). |
| Artwork mosaics | One shared 30-minute rotation epoch; no timers per cell, no work while backgrounded (Phase 11.5 design, unchanged). |
| Listening analytics | Writes only at 15 s checkpoints and on pause/end; zero reads on the clock path (budget test). |
| Downloads | Native background `URLSession`; files streamed to disk, not memory (unchanged). |

## NOT RUN

| Measurement | Status | Reason |
| --- | --- | --- |
| Instruments Allocations / Leaks / Time Profiler | NOT RUN | Requires a Mac with the device attached; not available to this phase. |
| Multi-hour playback/download soak | NOT RUN | No device soak was executed; simulator soak would not represent battery or thermal behaviour. |
| Battery and thermal on iPhone | NOT RUN | Covered qualitatively by device acceptance R37/R38. |
| Device scroll/launch timing | NOT RUN | Covered qualitatively by device acceptance R08, R34, R35. |

Gate G11 (no severe avoidable regression) and G12 (no demonstrated unbounded retention)
are judged in the release checklist from the measurements above; G12 explicitly notes that
Instruments and soak evidence were not run.
