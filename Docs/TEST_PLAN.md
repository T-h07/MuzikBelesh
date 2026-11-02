# Test plan

Unit tests cover configuration defaults, accepted/rejected YouTube IDs and URLs, normalization, malformed input, and safe diagnostics summaries. They use no network request and run through the `OFFLINETests` target in CI.

Completed manual checks on November 2, 2026: SideStore installation, diagnostics launch, metadata resolution for two samples, five-stream audio-only enumeration, M4A selection with usable URL, Share-sheet appearance, and shared YouTube URL receipt. The app did not immediately crash. Outstanding: unavailable-media/no-internet behavior, actual download, audio playback, offline playback, and automatic Share-to-app handoff. The handoff is accepted as deferred to Phase 8.

Expected result is a passing simulator build/test job, a structurally valid unsigned IPA, and truthful device evidence. A successful compile is not evidence that YouTube extraction or SideStore signing works.

