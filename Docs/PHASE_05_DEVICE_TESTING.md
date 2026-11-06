# Phase 5 physical iPhone acceptance

## Developer report — build 66, 2026-11-04

Device: iPhone 13 Pro Max. iOS version: **NOT PROVIDED**.
Source: `d359b20b0b613cf81f98bd58dd492d81a7d6d181`, version **0.1.0 (66)**.
The developer reports that all original A–J checks passed. These are developer
reports, not hardware tests performed by this agent.

| Original check | Build 66 result |
| --- | --- |
| A — Import | PASS — developer reported |
| B — Playlists | PASS — developer reported |
| C — Metadata | PASS — developer reported |
| D — Likes | PASS — developer reported |
| E — Search and sorting | PASS — developer reported |
| F — Restart and persistence | PASS — developer reported |
| G — Safe deletion | PASS — developer reported |
| H — Offline operation | PASS — developer reported |
| I — Phase 4 playback regressions | PASS — developer reported |
| J — In-place update | PASS — developer reported |

Build 65 (`b9cd89008d9c3e8c6604eab10ae30fabc1558766`) was rejected:
E failed because Search could trap keyboard focus and could not return album,
artist or playlist entities. A–D/F–J were reported PASS. Build 66 corrected those
functional defects, but the developer now reports an oversized gray keyboard
accessory area and choppy bottom-control movement. No iOS version was supplied
for either report. The new album-management requirements were not present in 66.

## Developer physical acceptance — build 155, 2026-11-04

Device: **iPhone 13 Pro Max**. Developer-reported iOS version: **27.0.1**.
Version/build: **0.1.0 (155)**. Accepted source SHA:
`0cb829aa6cb5687782724200bd6c15e3e0e9c8ea`.
IPA SHA256 (as reported by the build agent):
`5727a92d88e4df37247e35d4cb256bbe8ac489ca5aa1be33fd7fdabe34e68e8e`.

- [Focused CI — PASS](https://github.com/T-h07/MuzikBelesh/actions/runs/41830329066)
- [Final CI — PASS](https://github.com/T-h07/MuzikBelesh/actions/runs/41832813069):
  194 unit/integration tests, 17 UI tests and 5 compact-screen checks reported passing.
- [Unsigned IPA and manifest](https://github.com/T-h07/MuzikBelesh/actions/runs/41832813069/artifacts/13325756988)

The developer reported the following **physical-device category-level results** after
updating in place. This is developer testimony, not hardware testing by the
agent or proof of every granular procedure in the table below.

| Reported category | Build 155 result |
| --- | --- |
| Album management, search and persistence | **PASS — developer reported** |
| Keyboard layout and animation | **PASS — developer reported** |
| In-place update integrity and playback regressions | **PASS — developer reported** |

No failing behavior was reported for build 155. The full per-scenario
acceptance table remains below as a reference; individual scenarios that were
not expressly reported remain **NOT RUN / not individually attested**, rather
than being inferred from these grouped results. No further device evidence is
invented. The developer explicitly instructed **not to merge PR #6 without
separate authorization**.

## Replacement build 155 — detailed scenarios (not individually attested)

Replacement version: **0.1.0 (155)**; SHA, checksum, CI and artifact links appear
in the developer acceptance section above and in
[PR #6](https://github.com/T-h07/MuzikBelesh/pull/6).
CI is not a substitute for physical testing; grouped developer-reported results
are recorded separately from detailed individual scenarios.

Install the replacement **over build 66 through SideStore**. Do not uninstall,
reset SQLite, or remove imported files to work around any failure. Record the iOS
version, replacement version/build/embedded SHA and PASS/FAIL/NOT RUN below.

| New check | Procedure | Result |
| --- | --- | --- |
| Album creation | Library → Albums → Create Album. Save an empty album, then create another with artist, year, description, artwork and three songs. | NOT RUN |
| Album editing | Rename/change artist/year/description; replace/remove artwork; add, remove and reorder songs. Relaunch and verify everything persists. | NOT RUN |
| Primary assignment | Move a song between two albums. It appears only in its new primary album. Remove it; Unassigned Songs contains it. Playlists remain independent. | NOT RUN |
| Imported albums and identity | Edit an imported tagged album. Create two albums with the same name; they remain separate. Previously untagged songs appear under Unassigned Songs. | NOT RUN |
| Search and artist views | Search new/renamed albums and album artists in Search/Your Library and Library All/Albums; old names disappear. Open the album from the relevant artist. Repeat offline. | NOT RUN |
| Album playback/deletion | Play and shuffle an album. Start a timer, queue an unrelated song, then delete the current album with confirmation. Current audio continues; songs/files/likes/playlists/history/queue/timer survive. | NOT RUN |
| Keyboard layout | Search and Library: open keyboard, use Done beside the field, Search/Return, scroll, clear, result selection and tab changes. No gray accessory gap or blocked navigation. | NOT RUN |
| Keyboard transitions | Open/close five times with no player, with playback, and with a Sleep Timer. Check smooth single movement, stable final positions, no repeated jumps, touch failures or stale focus. Switch search modes too. | NOT RUN |
| Update integrity | Compare existing music, stable tracks, likes, metadata/artwork, playlists/custom orders, queue/history and timer before/after updating. Recheck Previous/Next, Shuffle/Repeat, seek/EOF, Lock Screen and background audio. | NOT RUN |

Do not claim a frame-rate improvement from screenshots or simulator assertions.
If a check fails, preserve the app container, record reproduction steps and export
Settings / Diagnostics. Never invent test evidence.

**PHASE 5 BUILD 155 — DEVELOPER-REPORTED CATEGORY ACCEPTANCE PASSED; INDIVIDUAL CHECKLIST PROCEDURES NOT SEPARATELY ATTESTED.**
PR #6 remains open and unmerged pending the developer's separate explicit merge
authorization. Do not modify release or start Phase 6.
