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
