# Muzik Belesh v1.1.0 — Release notes

**Release candidate:** unsigned IPA build **99**, built from product source `d5551d5`. The developer reported successful in-place installation and targeted iPhone acceptance. The release was approved after acceptance; see [Phase 10.9 release evidence](PHASE_10_09_RELEASE.md).

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
- Importing an audio file (or finishing a YouTube download) no longer fails when the file's
  artist or album tag is unusually long; very long titles are shortened to 300 characters
  and control characters are removed.

## Not included

- Direct Spotify account connection, Spotify playlist links or a Spotify Share extension
  (the canceled Phase 10.8). Use an Exportify CSV or Spotify data export instead.

## Upgrading

Install over the existing app with the **same SideStore signing identity** so the app keeps
its data container and App Group. Library, playlists, downloads and queue carry over; the
database is upgraded in place and never reset.

## Security, performance and code quality

- Validates long embedded artist/album tags and YouTube metadata before import so unusual metadata doesn't abort an otherwise valid audio import.
- Tightens handling of security-scoped local-file access and validates free-text CI workflow input.
- Reduces repeated playback-context calculations when displaying ordinary playlists.
- Removes obsolete Phase 1 debug mocks and unused types; no playback or migration engine rewrite.

## Verification and artifact

- Focused native verification: **261 tests passed, none failed** ([run](https://github.com/T-h07/MuzikBelesh/actions/runs/44096490155)).
- Complete regression: library UI **16/16**, compact UI **5/5**; seven documented pre-existing failures remain in other suites, including six migration/review UI cases and one coordinator timing case ([run](https://github.com/T-h07/MuzikBelesh/actions/runs/44096495656)). This full run was **not green**.
- The developer reported passing in-place preservation and playlist-import device checks on build 98, followed by the targeted build-99 regression checks.
- IPA build: [GitHub Actions run 44093034975](https://github.com/T-h07/MuzikBelesh/actions/runs/44093034975), `OFFLINE-unsigned.ipa`, v1.1.0 build 99.
- IPA SHA-256: `2358a7bdd6da6dafa3d309501464c4fc53163c99f46e732bd64b90c6b530984f`.

The IPA is **unsigned** and must be signed by SideStore. Use the same signing identity when upgrading, and **do not uninstall** the existing app.

[Final hardening audit](PHASE_10_09_SECURITY_PERFORMANCE.md) · [Release acceptance and known risks](PHASE_10_09_RELEASE.md)
