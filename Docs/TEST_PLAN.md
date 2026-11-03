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
