# Phase 9 performance and thermal report

## Baseline and method

Accepted Phase 8 source: b9386122a56ddf1550b360c4ce9401ff100ceeb3. Baseline profiling commit 6eb7275 adds a neutral clock sampling seam, tests and workflow scope without changing the original half-second behavior. [Successful baseline run 42147221082](https://github.com/T-h07/MuzikBelesh/actions/runs/42147221082) executes ReleasePerformanceTests on a hosted iPhone simulator. Initial run 42146834013 failed to compile two asynchronous GRDB trace setup calls; adding await corrected the harness before measurement.

The clock test invokes 120 half-second samples immediately, representing 60 seconds of timeline with a 20-entry explicit queue. SQL trace counts only SELECT and INSERT/UPDATE/DELETE statements within that interval. Publications count AudioPlayerService.objectWillChange. Elapsed execution time is wall time, **not CPU time**, despite the original baseline log's cpuWorkSeconds label. There is no sleep, radio, audio decoding or 60-second battery measurement in this test.

| Clock workload | Baseline | Candidate acceptance |
|---|---:|---:|
| SELECT statements | 240 | 0 |
| Data mutation statements | 504 | 12 position UPDATEs |
| Observable publications | 480 | at most 123 |
| Elapsed work time | 0.092943 s | Report measured value in integration PR; no timing threshold |

| Synthetic records | Context setup baseline | Search baseline |
|---:|---:|---:|
| 100 | 0.000340 s | 0.001758 s |
| 1,000 | 0.030562 s | 0.013000 s |
| 5,000 | 0.776343 s | 0.067724 s |
| 10,000 | 3.120857 s | 0.128076 s |

The same baseline test remains in candidate verification, with optimized measurements attached to its PR. Context setup should scale linearly after replacing growing-array membership checks with a Set. Search remains an asynchronous immutable-snapshot operation; no unsupported latency promise or speculative rewrite is made. Different hosted runners introduce timing variation, so work counts are stronger evidence than single-run timing ratios.

ReleaseReliabilityTests additionally creates 10,000 SQLite rows, checks search, 1,000 playlist memberships, reopening and foreign keys. These are synthetic records sharing one tiny audio fixture, **not 10,000 real files**. ReleasePerformanceTests adds five-iteration XCTClockMetric, XCTCPUMetric and XCTMemoryMetric search measurements. Those are simulator test-process metrics, not whole-app steady state or physical energy results.

## Changes and their limits

- Clock callbacks update elapsed display, update Previous availability only across the three-second boundary, and checkpoint position every five seconds. Transport/metadata events publish Now Playing; iOS extrapolates elapsed time from rate. Queue structure is still persisted atomically at structural changes.
- Foreground clock interval is 0.5 s normally, 1 s under Low Power Mode or thermal pressure; background interval is 5 s. Pause, foreground return and Previous synchronize from AVPlayer's actual time. Playback/EOF/deadlines remain native, independent of display cadence.
- Artwork object is cached by bytes instead of decoded for every clock tick. One cache entry is retained and cleared on stop. Existing thumbnail caches stay bounded.
- Context membership uses a bulk available-ID query and Set lookups. Navigation history is capped at 1,000; the separate listening history table is unchanged.
- File export copies in 1 MB chunks and verifies SHA-256, avoiding a complete audio Data allocation. The picker owns a temporary copy until dismissal; abandoned owned export directories are cleaned on next launch.
- Release excludes legacy mock catalogs. Resource policy listens to system notifications rather than polling. Background download progress retains its existing 0.5 s UI and eight-second persistence throttles.
- OSLog signposts BeginPlayback, LibrarySearch and AudioHash provide intervals without paths, titles or media URLs. Repeated 200-track-change deallocation checks cover observer ownership, not an Instruments leak verdict.

## Resource policy

| System state | New transfers | Maintenance | Playback |
|---|---|---|---|
| Nominal, normal power | User concurrency preference | Allowed | Normal cadence |
| Fair or Low Power Mode | At most one; preference unchanged | Deferred between files | Reduced display cadence |
| Serious or critical | Deferred; queued state explains cooling | Deferred | Existing audio continues; system remains authoritative |

Already-running native transfers are not cancelled merely for pressure; cancellation can waste bytes and break restoration. New resolution results are rechecked before dispatch. Normal conditions resume queued scheduling without changing persisted preferences. Low Power Mode never independently pauses music. Diagnostics shows real thermal/Low Power state; this is observability, not an estimate of device temperature.

Apple references: [power notifications](https://developer.apple.com/documentation/xcode/responding-to-power-notifications), [Now Playing elapsed time](https://developer.apple.com/documentation/mediaplayer/mpnowplayinginfopropertyelapsedplaybacktime), [file export copy](https://developer.apple.com/documentation/uikit/uidocumentpickerviewcontroller/init(forexporting:ascopy:)).

## Outstanding physical profiling

All rows below are NOT RUN for the candidate. Record CPU, peak/steady memory, wakeups and energy when supported by Instruments or device tooling; disk/write frequency, bytes/requests, responsiveness/screen-open time, playback-start time, throughput, battery interval, thermal state and hangs as applicable. Mark unavailable metrics NOT MEASURED rather than estimating them. On Windows, use Diagnostics, iOS Battery, exact timestamps, screen recordings and the protocol in the device checklist; a Mac/Instruments capture provides deeper optional CPU/memory attribution.

| Scenario | Required observation / device case |
|---|---|
| Cold launch | Time to usable Library; saved data present; P0,P1 |
| Idle Home | Five-minute background-work/thermal baseline; scenario A |
| Local playback, screen on | Continuous 60 minutes; P3 |
| Local playback, locked | 30 minutes then two hours; P4/scenario B |
| Playback while browsing Library | Responsiveness/memory; scenario C |
| Playback during Search | Latency and dropped audio; P15/scenario C |
| AirPods playback | Routes, controls, energy; P5 |
| One YouTube download | Bytes/time, success, heat; P21 |
| Multiple downloads | Concurrency, throughput, pressure; scenario D |
| Download plus playback | No glitches, memory/thermal; scenario E |
| Suspended native transfer | Completion/relaunch identity; P12 |
| Large library search/scroll | 100/1,000/5,000/10,000 real-record scenarios where available; P15 |
| Metadata/artwork editing | Repeated presentation/memory; P1,P15 |
| Long running session | Two hours, retained objects/thermal/battery; P4,P23 |

Before/after device comparisons should use accepted build 189 and the candidate with equivalent data, brightness, network, charge and ambient conditions. Do not downgrade destructively or uninstall the user's library to obtain a baseline. If a safe same-data baseline is unavailable, document that limit. No measured reduction in CPU percentage, battery drain or device temperature is claimed by this report. Full performance/thermal release gates remain open until those observations are recorded.
