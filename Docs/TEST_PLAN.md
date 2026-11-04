# Test plan

Unit tests cover configuration defaults, accepted/rejected YouTube IDs and URLs, normalization, malformed input, safe diagnostics summaries, deterministic fixture IDs, local search, likes, playlist/metadata mutations, queue behavior, repeat/position behavior, download transitions, and settings mutations. They use no network request and run through the `OFFLINETests` target in CI.

The `OFFLINEUITests` target contains a real XCTest smoke test that launches the app and switches through Home, Search, Library, and Downloads. Phase 2 adds isolated migration, repository, path-safety, hashing, cold-reopen, and export tests in `Phase2StorageTests`; the final Phase 2 CI run executed 17 tests with zero failures, including the existing Phase 0/1 suites and UI smoke test.

Phase 0 manual checks completed on November 2, 2026: SideStore installation, diagnostics launch, metadata resolution for two samples, five-stream audio-only enumeration, M4A selection with usable URL, Share-sheet appearance, and shared YouTube URL receipt. Phase 1 simulator checks cover tab navigation and the mock presentation layer. Phase 2 automated checks cover local database and filesystem foundations. Phase 3 CI covers local AVPlayer loading and state transitions; the developer-reported physical iPhone 13 Pro Max checks are recorded as accepted in `Docs/DEVICE_AUDIO_TESTING.md`. Exhaustive hardware combinations remain not verified.

Expected result is a passing simulator build/test job, a structurally valid unsigned IPA, and truthful device evidence. A successful compile is not evidence that YouTube extraction or SideStore signing works.

# Phase 4 verification

CI covers queue-entry identity, ordering, repeat modes, timer validation, database migration, AVPlayer integration, and the existing UI regression suite. Physical iPhone testing remains necessary for locked-device background timer behavior; simulator success is not evidence for that gate.

The application audit adds recorded failing-before navigator regressions, fake-player
tests of the real service, native AVPlayer seek checks, a deterministic 240-operation
six-track stress scenario, and filesystem safety tests. See APPLICATION_AUDIT.md for
evidence limits, deferred scenarios and the physical acceptance matrix.


# Phase 5 verification

Tests/Unit/Library uses isolated UUID databases/directories and generated original
WAV/JPEG/PNG fixtures. Coverage includes playlist validation/CRUD/membership/order,
rollback, likes, metadata identity/bytes, artist/album/compilation grouping, artwork
staging/reference cleanup, bound Unicode/literal search, seven deterministic sorts,
source/hash duplicates, concurrent imports, deletion recovery and v008 upgrades.
The ten-track SQLite/filesystem test closes/recreates its services and validates
all files, persistent data, playback order, a live metadata edit and native startup.

LibraryManagementUITests launches a DEBUG-only isolated test root with three real
stored WAVs. Reset is explicit for the first launch; restart tests keep that same
root. Production storage is never used by destructive UI tests. Workflows cover
playlist CRUD, multi-add, accessible reorder controls (the same repository used by
native drag), removal, likes, editing/cancel, search/play, confirmed deletion and
restart persistence. Stable accessibility IDs replace absolute screen coordinates.
UI screenshots are kept as XCTest attachments and exported to library-ui-screenshots.
Native drag, system Photos selection and device-specific media routing remain in
the physical checklist. The existing UI smoke and all Phase 0-4 tests remain enabled.

CI retains xcresult, enforces bounded waits/test timeouts and records the selected
simulator/toolchain. Final counts, environment, workflow and artifact URLs belong
in the PR for the exact tested source. A compile or simulator run is not physical
acceptance; physical outcomes are recorded separately in PHASE_05_DEVICE_TESTING.md.

Build 65 was physically rejected for search/keyboard check E. Its developer-reported
A-D/F-J results are PASS, with iOS version NOT PROVIDED; E stays FAIL pending retest.
New failing-before UI regressions cover submit dismissal, playlist search and the
missing Library field in playlist mode. Universal-search unit tests cover all four
entity types, scopes/likes, Unicode/literals, live CRUD/metadata, persistence/sort
isolation, cancelled responses and deliberately out-of-order completions. UI tests
exercise real keyboards, Done/Search, tab changes, scroll/clear, result navigation,
mini-player access, All/filter consistency and relaunch. The compact test must install
the app/extension with matching nonempty versions before its assertions can run.

Failing-before evidence: CI 41720899168 on d9ab131 passed all 167 unit/integration
tests and failed the new UI cases for the absent Library search field in Playlists,
the absent playlist entity result, and the missing keyboard Done control. An existing
metadata/search UI flow also exceeded its two-minute execution allowance. It remains
enabled and must pass with the fixes; no timeout or failure is treated as acceptance.

CI 41724937547 passed 180 unit/integration tests, the new entity-search workflows,
and the Search/Done dismissal workflow. The live-player keyboard test reproduced
the native tab bar remaining behind the keyboard. The restart workflow reached
all assertions at 126 seconds, exceeding its 120-second cap; helper queries/swipes
and empty-field deletion were made more efficient without removing assertions or
raising that cap. A focused keyboard UI gate now precedes the complete suite and
exports its own screenshot/xcresult evidence. Compact installation/layout and keyboard
tests still run after the complete suite passes.

The additional album scope adds tests for empty/duplicate-name albums, all metadata
fields, atomic primary assignments, ordering/moving/removal, safe deletion, likes
and playlist preservation, real tagged audio import, reopen/search, JPEG/PNG cover
replacement/removal/recovery, failed-save rollback, active playback/queue/history/
timer preservation, and upgrade from build 66's actual v009 schema. A v008 upgrade
still runs too. The focused gate runs album tests and the existing live-player
keyboard test before the complete suite. UI workflows cover album creation/editing,
song selection/reorder/removal, playback/deletion and relaunch/search. Compact tests
also exercise the album editor. No per-test execution cap or assertion was removed.

Keyboard UI tests capture open/closed screenshots and measured keyboard/tab-bar
geometry over repeated focus transitions. They assert the accessible Done control
is alongside the field, tabs stay above the keyboard, and closed geometry returns
without drift. UIKit alone owns keyboard avoidance (`safeAreaRegions = .container`
in its child host); no accessory toolbar is installed. This removes two competing
insets, but simulator checks do not establish physical frame rate. Hardware animation
quality remains a required additional acceptance check in PHASE_05_DEVICE_TESTING.md.
