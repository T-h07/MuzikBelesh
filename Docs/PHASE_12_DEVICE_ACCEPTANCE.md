# Phase 12 — physical iPhone release acceptance (v1.2.0)

The physical iPhone is the final behavioural acceptance environment for v1.2.0. The
developer installs the release-candidate IPA through SideStore **over the existing
application** (no uninstall), using the same signing identity as v1.1.0.

## Candidate under test

| Field | Value |
| --- | --- |
| Version | 1.2.0 |
| Build | _recorded when the final candidate is built_ |
| Source SHA | _recorded when the final candidate is built_ |
| IPA SHA-256 | _recorded when the final candidate is built_ |
| Build run / artifact | _recorded when the final candidate is built_ |
| Device / iOS version | _reported by the developer_ |
| Installed over | _version and build previously installed on the device_ |

An acceptance record is valid only for the exact build number and SHA-256 above. If any
executable source, resource, extension or packaging input changes afterwards, the IPA is
rebuilt, re-verified and the affected cases are repeated.

## Rules

- Every case starts **NOT RUN**.
- **PASS** only when the developer reports successful execution on the device.
- **FAIL** when the observed behaviour does not meet the expectation; record what happened.
- A case that cannot be executed stays **NOT RUN** with a reason.
- Partial testing is never reported as full acceptance.

## Checklist

| ID | Required test | How to check | Status | Notes |
| --- | --- | --- | --- | --- |
| R01 | In-place upgrade retains all existing music | Song count and a sample of songs play after updating over v1.1.0/Phase 11 | NOT RUN | |
| R02 | Playlists and albums remain intact | Playlist order, repeated songs and album membership unchanged | NOT RUN | |
| R03 | Song artwork and custom covers remain intact | Song art and custom playlist/album covers still shown | NOT RUN | |
| R04 | Profile survives upgrade | Name and photo unchanged (or first-launch setup if none existed) | NOT RUN | |
| R05 | Listening analytics survive upgrade | Your Listening totals unchanged after update | NOT RUN | |
| R06 | Theme and accent preferences survive upgrade | Selected preset/custom colour unchanged | NOT RUN | |
| R07 | Dynamic artwork preferences survive upgrade | Per-collection artwork mode unchanged | NOT RUN | |
| R08 | App cold-launches successfully | Launch after reboot / force-quit | NOT RUN | |
| R09 | App relaunches without losing state | Queue, position and tab restored after relaunch | NOT RUN | |
| R10 | Home, Library, Search, Downloads and Profile navigate smoothly | No hitches or blank screens | NOT RUN | |
| R11 | Music starts and stops normally | Play/pause from list, mini-player, Now Playing | NOT RUN | |
| R12 | Shuffle and all repeat modes work | Shuffle, repeat all, repeat one | NOT RUN | |
| R13 | Next, Previous, and seeking behave correctly | Including Previous restart rule and scrubbing | NOT RUN | |
| R14 | Queue changes and playback restoration work | Reorder/remove/play next; relaunch restores | NOT RUN | |
| R15 | Lock Screen controls and artwork work | Locked controls, title and artwork | NOT RUN | |
| R16 | AirPods/Bluetooth controls work | Play/pause/skip, disconnect pauses | NOT RUN | |
| R17 | Background audio continues correctly | App in background for several songs | NOT RUN | |
| R18 | Sleep timer works while locked | Timer stops playback while locked | NOT RUN | |
| R19 | Local audio import works | Import from Files | NOT RUN | |
| R20 | YouTube search and download work | Search, choose quality, download, play offline | NOT RUN | |
| R21 | Wi-Fi-only download behavior works | Cellular waits when Wi-Fi-only is on | NOT RUN | |
| R22 | Background download recovery works | Background/relaunch during download | NOT RUN | |
| R23 | Spotify playlist import works | Exportify CSV / JSON / ZIP | NOT RUN | |
| R24 | Matching and missing-song review work | Review queue choose / skip | NOT RUN | |
| R25 | Failed-song retry works | Retry from Migration Issues | NOT RUN | |
| R26 | `.mbelesh` export works | Export playlist(s) and whole library | NOT RUN | |
| R27 | `.mbelesh` import preserves ordering and duplicates | Import on device; order and repeats kept | NOT RUN | |
| R28 | Existing local recordings are reused | No re-download of songs already present | NOT RUN | |
| R29 | Missing imported recordings can be acquired or reviewed | Matching/download/review of missing songs | NOT RUN | |
| R30 | Listening analytics count actual playback correctly | Paused/skipped time not counted | NOT RUN | |
| R31 | Theme changes do not interrupt playback | Change accent while playing | NOT RUN | |
| R32 | Dynamic artwork mosaics display correctly | 2×2 mosaics for playlists/albums/artists | NOT RUN | |
| R33 | Mosaic rotation and manual artwork priority work | 30-minute rotation; custom cover wins | NOT RUN | |
| R34 | Large playlists scroll smoothly | Largest owned playlist | NOT RUN | |
| R35 | Large Library search remains responsive | Typing in Library search | NOT RUN | |
| R36 | No reproducible crashes during normal usage | | NOT RUN | |
| R37 | No unexpected app-induced severe overheating | Extended listening and downloads | NOT RUN | |
| R38 | No obvious persistent memory-growth symptoms | Long session; no slowdown or termination | NOT RUN | |
| R39 | Share extension accepts supported YouTube links | Share → Muzik Belesh → Save Link; open app | NOT RUN | |
| R40 | Data remains intact after force-closing and reopening | Force-quit during idle and during work | NOT RUN | |
| R41 | Missing artwork and corrupt input fail gracefully | Corrupt/unsupported file import | NOT RUN | |
| R42 | Custom accent contrast remains readable | Very light and very dark custom colours | NOT RUN | |
| R43 | Downloading and playback can coexist | Play while a download runs | NOT RUN | |
| R44 | Import progress and recovery remain correct | Background/relaunch during import | NOT RUN | |
| R45 | Release candidate version, build, and source information are correct | Settings/About shows 1.2.0, build and commit matching the manifest | NOT RUN | |

## Summary

| Result | Count |
| --- | --- |
| PASS | 0 |
| FAIL | 0 |
| NOT RUN | 45 |

**Device acceptance status: NOT RUN.** Gate G16 cannot pass until the developer reports
results for the exact candidate recorded above.
