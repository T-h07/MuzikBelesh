# Roadmap

| Phase | Name | Branch |
|---|---|---|
| 0 | Foundation, CI & feasibility | `feature/phase-00-foundation` |
| 1 | Design system and UI navigation | `feature/phase-01-ui` |
| 2 | Database and file storage | `feature/phase-02-storage` |
| 3 | Native audio playback engine | `feature/phase-03-audio` |
| 4 | Playback state, queue, history and sleep timer | `feature/phase-04-playback` |
| 5 | Music library and playlist management | `feature/phase-05-library` |
| 6 | YouTube search, metadata and extraction | `feature/phase-06-youtube` |
| 7 | Audio download management | `feature/phase-07-downloads` |
| 8 | iOS Share extension | `feature/phase-08-sharing` |
| 9 | Integration, testing and v1.0 release | `feature/phase-09-release` |

Phase 0-3: complete. Phase 4: **merged into develop at a58861f (PR #5), with
physical acceptance recorded by the developer in its merge commit**.

Phase 5: persistent library and playlist management is implemented on
`feature/phase-05-library`; automated validation and the device acceptance matrix
are tracked in its PR and PHASE_05_DEVICE_TESTING.md.

**Milestone B — Complete Offline Music Player: PENDING PHYSICAL ACCEPTANCE.**
Do not mark complete until the ten-track scenario, regressions, final-head CI/IPA,
required physical checks and integration into develop are all verified.
Milestone C is not complete. Phase 6 has not started.
