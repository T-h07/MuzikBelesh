# Test plan

Unit tests cover configuration defaults, accepted/rejected YouTube IDs and URLs, normalization, malformed input, and safe diagnostics summaries. They use no network request and run through the `OFFLINETests` target in CI.

Device-only checks: install with SideStore; confirm the diagnostics screen opens; run metadata resolution; verify audio-only filtering and M4A selection; test unavailable media and no-internet behavior; confirm no crash; share a YouTube URL from Safari/YouTube; verify OFFLINE appears and receives the URL; record whether a supported handoff exists. These checks are currently `NOT RUN`.

Expected result is a passing simulator build/test job, a structurally valid unsigned IPA, and truthful device evidence. A successful compile is not evidence that YouTube extraction or SideStore signing works.

