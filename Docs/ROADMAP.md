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

Phase 5: merged through PR #6 at `9ba81a7fe6d0cd6420958971ac2a89bfadb68264`,
following developer-reported build 155 category acceptance on iPhone 13 Pro Max
(iOS 27.0.1). Individual procedures not separately attested remain documented.

Phase 6 merged through PR #7 at `7674daf`. Phase 7 download management and
Phase 7.1 native background transfers are integrated into the accepted Phase 8
baseline. The Phase 9 brief records physical acceptance of Phase 8 build 189 and
PR #10 merge `b9386122a56ddf1550b360c4ce9401ff100ceeb3`.

Phase 9: 1.0.0 candidate preparation on `feature/phase-09-release`. Automated
results and artifact provenance are recorded in its integration PR. P0–P24 device
acceptance and publication approval remain open. `release` and stable tagging are
not advanced by candidate preparation. See PHASE_09_RELEASE_CHECKLIST.md.
