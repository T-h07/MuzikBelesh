# Muzik Belesh v1.2.0

Muzik Belesh v1.2.0 is a free update for everyone on v1.1.0. It adds a local profile,
listening statistics, custom accent colours, library sharing between iPhones and automatic
collection artwork, and finishes with a release-hardening pass across playback, storage,
security and tests.

Install it **over** your existing app with the same SideStore identity. Your music,
playlists and settings stay where they are.

## What's new since v1.1.0

### Your profile
- A local profile with a display name and an optional photo, created once on first launch
  (or the first launch after updating). It lives only on your iPhone: no account, email,
  password or server.
- Edit your name and photo from the Profile page, opened from the Home header.

### Listening statistics
- **Your Listening** shows how much music you actually listened to over the last 7 days,
  last 30 days or all time, with an activity chart, highlights, Top Songs, Top Artists,
  Top Albums and Top Playlists.
- Only time when audio is really playing is counted. Paused, buffering, skipped and seeked
  time never counts. Lock Screen, background and AirPods listening counts normally.
- Tap a top song to play it, or open a top album, artist or playlist.

### Custom themes
- Eight accent presets (Original Lime, Purple, Violet, Blue, Cyan, Pink, Red, Orange) or
  any custom colour, with automatic contrast adjustment for readability.
- The choice applies instantly across the app, persists across launches and never
  interrupts playback. **Reset** returns to Original Lime and keeps your custom colour.

### Share your library
- Export one playlist, several playlists or the whole library as a small `.mbelesh` file
  and send it with AirDrop, Messages, Mail or Files.
- Importing on another iPhone keeps playlist order and repeated songs, reuses songs that
  are already on that iPhone, and finds or downloads the rest through the existing
  matching and download system.
- The file contains song metadata, playlist order and public YouTube references only —
  never audio, your profile, listening history, settings or file locations.

### Collection artwork
- Playlists, albums, artists and Unassigned Songs show an automatic 2×2 mosaic built from
  up to four of their own song covers. It changes every 30 minutes while the app is open.
- A custom cover always takes priority. Choose per collection in **Artwork Settings**.
- Nothing is downloaded for artwork and no music or metadata is changed.

## Reliability, accessibility and security (Phase 12)

- **Search inside a playlist** now keeps the search field at the top while you type, so
  matching songs are visible above the keyboard instead of hidden underneath it.
- **VoiceOver** announces Top Songs, Top Artists and the Top Albums/Playlists carousels in
  Your Listening as buttons.
- **Theme selection**: tapping the colour that is already selected no longer re-saves it or
  refreshes the screen.
- **Network safety**: YouTube, Invidious and SearXNG responses are size-checked while they
  download (8 MB / 4 MB limits), so an oversized or endless response from a misconfigured
  server is stopped early instead of being read into memory first.
- **Build integrity**: the release pipeline pins its GitHub Actions to exact commits,
  verifies both app and Share extension identities, versions, minimum iOS version and the
  absence of test-only code, and publishes a SHA-256 checksum with the IPA.
- **Upgrade safety**: new automated checks upgrade databases from v1.1.0 and every Phase 11
  build to v1.2.0 and verify that no row changes, playlist order and audio files are kept,
  and SQLite integrity and foreign keys are intact.

## Install or update

1. Download `OFFLINE-unsigned.ipa` from this release (optionally `OFFLINE-build-manifest.json`
   and `OFFLINE-unsigned.ipa.sha256` to verify it).
2. Open it in **SideStore**, sign it with the same identity you used before, and install.
3. **Do not uninstall first.** Uninstalling deletes the app's library.

This is an unsigned IPA for personal SideStore installation, not an App Store build. It
requires iOS 17 or later and keeps the same identities as v1.1.0 (`com.th07.muzikbelesh`,
its Share extension and App Group), so SideStore treats it as an update.

**What an in-place update keeps:** downloaded and imported audio, artwork and custom covers,
playlists (order and repeated songs), albums, likes, the play queue and history, playlist
migrations and their review state, saved Share links, download preferences and, if you
already used a Phase 11 build, your profile, listening statistics, theme and artwork
choices. The database upgrade only adds new tables; it never rewrites existing rows.

**iOS restrictions:** free Apple Accounts need a SideStore refresh every seven days; iOS
decides when background downloads run; after a force-quit no background work runs until
you open the app again.

## Known limitations

- YouTube availability and formats can change at any time; discovery and downloads need
  a connection.
- iOS controls background work; force-quitting pauses downloads and matching until you
  reopen the app.
- After sharing a link from YouTube or Safari, open Muzik Belesh yourself to finish.
- Spotify import is file-based (Exportify CSV, account-data JSON or ZIP).

Full details: [Known limitations](KNOWN_LIMITATIONS.md) ·
[Phase 12 audit](PHASE_12_FINAL_RELEASE_AUDIT.md) ·
[Security audit](PHASE_12_SECURITY_AUDIT.md) ·
[Performance report](PHASE_12_PERFORMANCE_REPORT.md)
