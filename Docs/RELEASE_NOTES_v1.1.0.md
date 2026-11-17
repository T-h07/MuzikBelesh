# Muzik Belesh v1.1.0 — Draft release notes

> **Draft.** Not published. v1.1.0 is a release candidate until physical-device acceptance
> is recorded and the release is explicitly approved (see `Docs/PHASE_10_09_RELEASE.md`).

v1.1.0 adds **playlist migration**: bring a Spotify playlist into Muzik Belesh from an
exported file, match each song to audio, download it, and play the playlist offline in its
original order. Everything from v1.0.0 (offline library, background playback, lock-screen
and AirPods controls, queue, shuffle/repeat, sleep timer, YouTube search, downloads and the
YouTube Share extension) is unchanged.

## New

### Import Spotify playlists from a file
- **Exportify CSV**, **Spotify account-data JSON** (`Playlist1.json` …) and **ZIP** archives
  of those files. No Spotify account, login or developer key is needed.
- An import preview shows each playlist, its song count and any problem before anything is
  saved. Invalid files are rejected with an explanation; existing music is never changed.
- Up to 10,000 songs per playlist. Order is kept exactly, and a song that appears several
  times stays several separate entries.
- Importing the same export again reuses the existing playlist instead of creating a copy
  or overwriting your edits.

### Matching
- Songs already in your library are used first.
- Other songs are matched to YouTube recordings by title, artists and duration. Remixes,
  live versions, covers, sped-up/slowed versions and other mismatches are not accepted
  automatically.
- When the evidence is not strong enough, the song goes to **Review** so you can pick the
  right video or skip it.

### Automatic download and recovery
- Matched songs download through the existing download queue (Wi-Fi-only setting, retry,
  cancel and background transfers all apply).
- Progress is saved: closing or relaunching the app continues where it stopped. Temporary
  failures retry on a bounded schedule; one failing song does not stop the others.
- Pause, continue or cancel each playlist migration independently.

### Migration issues
- Songs that could not be completed are listed with the reason (no reliable match, needs
  review, unavailable, download failed, waiting for network, storage full, skipped …) and
  an action: retry, choose a video, use a song from your library, or skip.
- A summary appears when a migration finishes. Diagnostics live in **Migration Details**,
  not on the playlist screen.

### Imported playlist management
- Ready songs play immediately when tapped, like any library song.
- **Add Songs** from your library, or paste several YouTube links at once.
- **Remove from Playlist** removes just that entry; the audio stays in your library.
- **Change Video** replaces a wrong recording safely: the new audio is verified before the
  old one is swapped, and other playlists using the old recording are not affected.

### Playlist search
- Search inside a playlist to filter what you see. Tapping a result plays from that song
  through the **whole** playlist (shuffle uses the whole playlist too), not just the
  search results.

## Fixes since the Phase 10.8 test build

- Phones that installed the canceled Phase 10.8 test build could no longer save YouTube
  shares ("Could not save the link") and saw "Could not read the shared link inbox" on every
  launch. v1.1.0 converts that inbox once, keeps every pending YouTube share in order and
  keeps a backup copy of the original file.

## Not included

- Direct Spotify account connection, Spotify playlist links or a Spotify Share extension
  (the canceled Phase 10.8). Use an Exportify CSV or Spotify data export instead.

## Upgrading

Install over the existing app with the **same SideStore signing identity** so the app keeps
its data container and App Group. Library, playlists, downloads and queue carry over; the
database is upgraded in place and never reset.
