# Test plan

Unit tests cover configuration defaults, accepted/rejected YouTube IDs and URLs, normalization, malformed input, safe diagnostics summaries, deterministic fixture IDs, local search, likes, playlist/metadata mutations, queue behavior, repeat/position behavior, download transitions, and settings mutations. They use no network request and run through the `OFFLINETests` target in CI.

The `OFFLINEUITests` target contains a real XCTest smoke test that launches the app and switches through Home, Search, Library, and Downloads. Phase 2 adds isolated migration, repository, path-safety, and hashing tests in `Phase2StorageTests`; CI continues to run the existing Phase 0 and Phase 1 suites.

Phase 0 manual checks completed on November 2, 2026: SideStore installation, diagnostics launch, metadata resolution for two samples, five-stream audio-only enumeration, M4A selection with usable URL, Share-sheet appearance, and shared YouTube URL receipt. Phase 1 simulator checks cover tab navigation and the mock presentation layer. Phase 2 automated checks cover local database and filesystem foundations; physical Files import/relaunch/export remains pending device validation. Outstanding: actual download, audio playback, offline playback, and automatic Share-to-app handoff. The handoff is accepted as deferred to Phase 8.

Expected result is a passing simulator build/test job, a structurally valid unsigned IPA, and truthful device evidence. A successful compile is not evidence that YouTube extraction or SideStore signing works.

