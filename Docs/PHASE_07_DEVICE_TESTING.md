# Phase 7 - iPhone 13 Pro Max

Install the verified unsigned IPA over build 168 using the same SideStore signing identity. Keep the existing app installed. Record the build, iOS version, network and observations for each check. Use an authorized sample. For the offline test disable both Wi-Fi and cellular, relaunch, then play from Library.

| ID | Test | Expected result | Status |
|---|---|---|---|
| A | Install over Build 168 | Existing data survives | NOT RUN |
| B | Search YouTube | Real results load | NOT RUN |
| C | Open Video Details | Correct metadata | NOT RUN |
| D | Download supported audio | Real download job starts | NOT RUN |
| E | Observe progress | Received bytes and progress update | NOT RUN |
| F | Observe transfer speed | Realistic nonnegative value | NOT RUN |
| G | Finish download | Valid audio imported | NOT RUN |
| H | Open Library | Downloaded song appears | NOT RUN |
| I | Disable internet | Song remains available | NOT RUN |
| J | Play offline | Actual local playback succeeds | NOT RUN |
| K | Background/lock screen | Downloaded audio plays correctly | NOT RUN |
| L | Cancel active transfer | No broken track created | NOT RUN |
| M | Retry failed transfer | Recovery works | NOT RUN |
| N | Interrupt Wi-Fi | Policy respected | NOT RUN |
| O | Restore Wi-Fi | Eligible transfer resumes/restarts | NOT RUN |
| P | Wi-Fi-only on cellular | No media download over cellular | NOT RUN |
| Q | Cellular allowed | Permitted transfer works | NOT RUN |
| R | Restart during download | Job state recovered | NOT RUN |
| S | Re-download same video | No duplicate library entry | NOT RUN |
| T | Switch quality | Correct compatible choice | NOT RUN |
| U | Queue three or more songs | Ordering/concurrency respected | NOT RUN |
| V | Reorder pending jobs | Correct order retained | NOT RUN |
| W | Corrupt/incomplete download | No invalid track imported | NOT RUN |
| X | Artwork/metadata | Saved and visible offline | NOT RUN |
| Y | Existing local playback | No regressions | NOT RUN |
| Z | Mini-player/Load More | No overlap regression | NOT RUN |

## Post-build-175 iPhone retest

Build 175 device testing confirmed several real downloads, visible byte counts and transfer speed, imported metadata and artwork, and playback at normal speed. The following hotfix checks await device testing.

1. Install the new IPA over 175 with the same SideStore signing identity.
2. Confirm existing downloads and local imports are available. Allow the local duration audit to finish.
3. Compare the two reported tracks with their audible endpoints. Record Library and Now Playing durations for each.
4. Seek near the middle and end, check the lock screen, and resume after relaunch.
5. Download another authorized AAC/M4A on Wi-Fi. Record quality, file size and elapsed transfer time.
6. Compare average bytes per second with the live rate. For investigation, the Transfer log category includes numeric response-body bytes, network duration, callback cost and checkpoint cost.
7. Confirm the completed download appears in Library with exact file bytes, metadata and artwork.
8. Reopen its Video Details and verify Play in Library appears without stream resolution.
9. Enable Airplane Mode, open the saved video's ID via Paste a Video Link, and play it locally.
10. Confirm playlists, likes, queue, history and settings survived.
