# Phase 6 iPhone acceptance — NOT RUN

Device: developer's iPhone 13 Pro Max; iOS 27.0.1 per developer report.
Install the candidate over the existing SideStore app using the same identity.
Do not delete the app, reset storage or create a fresh installation to test it.
Before updating, record track/playlist/album counts, liked tracks, queue and settings.

| ID | Test | Expected result |
|---|---|---|
| A | Search a song title | Real relevant results, artwork and duration |
| B | Search an artist/channel | Real relevant results |
| C | Type rapid different queries | Late old responses never overwrite current results |
| D | Load More repeatedly | More results, no duplicates or simultaneous page requests |
| E | Open details | Real title/channel/artwork/duration; responsive back navigation |
| F | Paste standard watch URL with extra parameters | Correct normalized video opens |
| G | Paste mobile, youtu.be, Shorts, embed and live links | Correct identity, or explicit unsupported live-stream error |
| H | Paste malformed/deceptive URL | Clear validation failure, no network navigation |
| I | Resolve PSY `9bZkp7q19f0` and NEKO `HLYjoPv4QGY` | Actual audio-only M4A/AAC or verified compatible option; no remote server |
| J | Change Data Saver / Standard / High | Rate follows available compatible options; same rate is valid if only one exists |
| K | Private/removed/restricted video; airplane mode | Recoverable clear error, no crash or restriction workaround; retry network failures |
| L | Search/resolve while local audio plays | Identity, position, shuffle, repeat, queue, history and sleep timer unchanged |
| M | Back/forward, switch tabs/modes, type/Done/Search/scroll | Keyboard/tab bar/mini-player remain accessible and stable |
| N | Inspect imported track and any track with real YouTube provenance | Imported title match is not downloaded; exact available provenance is downloaded |
| O | Download Audio | Fresh stream preparation, explicit Phase 7 feedback; no file/job/fake completion |
| P | Restart after changing quality | Quality and existing library/settings persist |
| Q | Upgrade over previous IPA | All audio, artwork, albums, playlists/orders, likes, edits, history and queue survive |
| R | AirPods, lock screen, background playback and sleep timer | Existing playback controls and timer still operate |

All rows remain NOT RUN until the developer reports results. If no real YouTube
provenance exists yet, N should confirm ordinary imports stay Not Downloaded;
positive provenance is covered by deterministic SQLite tests until Phase 7.

For a failure, record the build/commit, video ID, network type, action and sanitized
message. Do not share signed media URLs or tokens. Provider/region/IP differences
can make a simulator fail where the iPhone succeeds (or the reverse). A passing
compile, test fixture or HEAD check is not evidence of completed file downloading.
