<div align="center">

<img src="OFFLINE/Resources/Assets.xcassets/AppIcon.appiconset/AppIcon-1024.png" width="112" alt="Muzik Belesh app icon" />

# Muzik Belesh

**Your music. On your iPhone. Offline.**

A native, offline-first iOS music player with a persistent local library, background playback, YouTube audio downloads, and **file-based Spotify playlist migration**. No mandatory account, subscription, or backend.

[![Latest release](https://img.shields.io/github/v/release/T-h07/MuzikBelesh?display_name=tag&label=release)](https://github.com/T-h07/MuzikBelesh/releases/latest)
[![CI](https://github.com/T-h07/MuzikBelesh/actions/workflows/ci.yml/badge.svg?branch=develop)](https://github.com/T-h07/MuzikBelesh/actions/workflows/ci.yml)
![iOS](https://img.shields.io/badge/iOS-17%2B-000000?logo=apple&logoColor=white)
![SwiftUI](https://img.shields.io/badge/SwiftUI-native-000000?logo=swift&logoColor=white)
![SideStore](https://img.shields.io/badge/installation-SideStore-202020)

**[Download the latest release](https://github.com/T-h07/MuzikBelesh/releases/latest)** · **[Unsigned IPA](https://github.com/T-h07/MuzikBelesh/releases/latest/download/OFFLINE-unsigned.ipa)** · **[Installation guide](Docs/SIDELOADING.md)**

</div>

---

## Overview

Muzik Belesh keeps your music on your device. Import audio files through Files, organize your collection into playlists and albums, and listen without a network connection. When you want new music, the app can search supported YouTube content, inspect audio formats, and queue a download for offline playback.

The player is built with **SwiftUI and AVFoundation**, using **SQLite/GRDB** for persistent library data. It supports native **Lock Screen / Control Center** and **AirPods / Bluetooth** media controls. You can import exported Spotify playlists while keeping their order and repeated tracks, and v1.2.0 adds a local profile, listening statistics, custom accent colours, `.mbelesh` library sharing between iPhones and automatic collection artwork.

## Features

| Playback | Your library |
| --- | --- |
| Offline audio and background / Lock Screen playback | Playlists, likes, albums, and artists |
| Play, pause, seek, shuffle, and repeat | Local search and seven sorting options |
| Persistent queue, listening history, and sleep timer | Editable titles, artists, albums, and artwork |
| AirPods / Bluetooth controls and audio interruption recovery | Duplicate detection, Files import/export, safe deletion |

| YouTube and downloads | Native iOS integration |
| --- | --- |
| Search, video details, and supported URL imports | Share links directly from YouTube or Safari |
| Quality choices: Data Saver, Balanced, Best Available | Persistent Share extension inbox |
| Download queue with progress, cancellation, and retry | Downloads managed through background URLSession |
| Wi-Fi-only preference with optional cellular downloads | Low Power Mode and thermal-aware work scheduling |

### New in v1.2.0 — profile, statistics, themes, sharing and artwork

| Personal | Share and browse |
| --- | --- |
| **Local profile** with name and optional photo — no account or server | Export playlists or the whole library as a small **`.mbelesh`** file |
| **Your Listening**: 7-day, 30-day and all-time listening time, activity chart, top songs, artists, albums and playlists | Import on another iPhone, reusing songs already there and finding the rest |
| Only time when audio is really playing is counted | Files carry metadata and public YouTube references only — never audio or personal data |
| **Custom themes**: eight accent presets or any colour, contrast-adjusted | Automatic **2×2 artwork mosaics** for playlists, albums and artists; custom covers always win |

[v1.2.0 release notes](Docs/RELEASE_NOTES_v1.2.0.md)

### Since v1.1.0 — Spotify playlist migration

| Import and matching | Manage and listen |
| --- | --- |
| Import **Exportify CSV**, Spotify account-data **JSON**, or supported **ZIP** exports | Preserve original order and repeated song occurrences |
| Preview files and import up to **10,000 songs per playlist** | Match songs already in your local library first |
| Find possible YouTube recordings for remaining songs | Review ambiguous matches instead of silently choosing the wrong recording |
| Persistent migration progress, retry, pause, and recovery | Add library songs, paste multiple YouTube links, remove an occurrence, or **Change Video** |
| Per-song Migration Issues with next steps | Search within a playlist without restricting its playback queue |

**No Spotify sign-in or developer credentials required.** Direct Spotify account connection, Spotify playlist-URL importing, and Spotify Share integration are **not** included. These imports use files you export yourself.

A persistent mini-player and full-screen Now Playing interface keep playback accessible across **Home, Search, Library, and Downloads**.

## Install on iPhone

> [!IMPORTANT]
> The release provides an **unsigned IPA** for personal **SideStore** installation. It is **not** an App Store build. SideStore must sign the main app and the Share extension using your compatible signing identity.

1. Open the **[latest GitHub Release](https://github.com/T-h07/MuzikBelesh/releases/latest)**.
2. Download `OFFLINE-unsigned.ipa` (and optionally `OFFLINE-build-manifest.json` and `OFFLINE-unsigned.ipa.sha256` to verify provenance and integrity).
3. Open the IPA with **SideStore**, sign it, and install on your iPhone.
4. Launch Muzik Belesh. Import existing audio from Files, or search for supported media and download audio for offline listening.

**Updating?** Install the new IPA **over the existing app**, using the same SideStore signing identity. **Do not uninstall first**—doing so may delete your local music library.

[Full sideloading instructions](Docs/SIDELOADING.md) · [Release checksums and details](https://github.com/T-h07/MuzikBelesh/releases/latest)

## Import a Spotify playlist

1. Export a Spotify playlist to **CSV** using Exportify, or obtain Spotify account-data **JSON/ZIP** files.
2. Open Muzik Belesh and choose its **playlist file-import** flow, then select the exported file in Files.
3. Review the preview and create the playlist. Songs are added in source order as placeholders until audio is found.
4. Match tracks from your library or review YouTube candidates; download accepted recordings for offline playback.
5. Use **Migration Details** and **Issues** to review unresolved songs, retry failures, or select a different recording.

Importing the same export again recognizes the prior import without overwriting local playlist edits. Network access is needed to discover and download new recordings; downloaded music plays offline.

[Detailed v1.1.0 release notes](Docs/RELEASE_NOTES_v1.1.0.md)

## Using YouTube sharing

1. In the YouTube app or Safari, choose **Share → Muzik Belesh**.
2. Select **Save Link**, then **Done**.
3. **Manually open Muzik Belesh** to inspect the saved link.
4. Choose an available audio quality and tap **Download Audio**.

Sharing a link does **not** automatically start a download. Apple's supported Share extension behavior does not automatically foreground the containing app.

## Performance and reliability

v1.0.0 introduced reliability improvements for long listening sessions and large libraries; v1.1.0 added validation and maintainability hardening; v1.2.0 adds a final release-hardening pass:

- Reduces repeated playback-clock database reads and writes.
- Reuses Now Playing artwork instead of rebuilding it on every clock tick.
- Uses linear-time queue setup and bounded recent navigation history.
- Streams file exports with integrity checks rather than loading entire audio files into memory.
- Adapts optional work to Low Power Mode and thermal pressure without interrupting normal music playback.
- Bounds imported audio metadata and removes unsafe control characters to avoid rejected imports or oversized metadata.
- Avoids rebuilding the whole playlist playback-ID list separately for every visible ordinary-playlist row.
- Includes import-integrity tests through 10,000 entries, careful inbox downgrade handling, and reviewed CI workflow input validation.
- Stops oversized YouTube and discovery responses while they stream (8 MB / 4 MB) instead of buffering them first.
- Verifies in-place upgrades from v1.1.0 and every Phase 11 database schema with row-for-row, integrity and foreign-key checks.
- Pins every CI action to an immutable commit and publishes a SHA-256 checksum with each IPA.

These are engineering improvements, **not a guarantee of a particular battery life or device temperature**.

### Verification for v1.2.0 (Build 200)

Simulator, unit, upgrade and packaging evidence, and the physical-iPhone acceptance checklist, are recorded in the [Phase 12 final release audit](Docs/PHASE_12_FINAL_RELEASE_AUDIT.md), [release checklist](Docs/PHASE_12_RELEASE_CHECKLIST.md) and [device acceptance](Docs/PHASE_12_DEVICE_ACCEPTANCE.md). The IPA's SHA-256 is published with the release.

[Security audit](Docs/PHASE_12_SECURITY_AUDIT.md) · [Performance report](Docs/PHASE_12_PERFORMANCE_REPORT.md)

### Previous release: v1.1.0 (Build 99)

- **261 focused native tests passed**, including new hardening/import integrity coverage ([run](https://github.com/T-h07/MuzikBelesh/actions/runs/44096490155)).
- Final full regression: **Library UI 16/16** and compact UI **5/5** passed. Seven other tests (six migration/review UI cases and one coordinator timing case) remain **documented baseline failures**; do not interpret the full CI run as green ([run](https://github.com/T-h07/MuzikBelesh/actions/runs/44096495656)).
- The developer reported **P01–P08** physical acceptance on build 98 and passing **targeted build-99 checks** for in-place update, imports/downloads, playlist playback/search/editing, and sharing.
- Build 99 source: `d5551d5`; SHA-256 for `OFFLINE-unsigned.ipa`: `2358a7bdd6da6dafa3d309501464c4fc53163c99f46e732bd64b90c6b530984f`.

[Integration and release verification](Docs/PHASE_10_09_RELEASE.md) · [Security, performance and cleanup audit](Docs/PHASE_10_09_SECURITY_PERFORMANCE.md)

### Previous release: v1.0.0 (Build 195)

- **262** unit/integration tests in the full suite (six optional live YouTube tests skipped).
- **25** full UI tests, **5** compact-layout checks, and **1** accessibility check passed.
- **25/25** physical iPhone 13 Pro Max acceptance cases reported as passed, including in-place upgrade, offline/locked playback, Bluetooth, downloads, and library preservation.

[Full CI evidence](https://github.com/T-h07/MuzikBelesh/actions/runs/42197209510) · [Performance report](Docs/PHASE_09_PERFORMANCE.md) · [Test plan](Docs/PHASE_09_DEVICE_TESTING.md)

## Tech stack

| Layer | Technology |
| --- | --- |
| App and UI | Swift, SwiftUI, UIKit |
| Audio | AVFoundation, MediaPlayer |
| Local storage | SQLite with GRDB, managed local audio files |
| Downloads | URLSession background transfers, Network framework |
| YouTube support | YouTubeKit, validated URL and stream handling |
| Project generation | XcodeGen |
| Builds and testing | GitHub Actions on macOS, XCTest |
| Device installation | SideStore |

**Requirements:** iPhone running **iOS 17 or later**. Building from source requires macOS/Xcode; the application can be developed from Windows while GitHub Actions performs macOS builds.

## Build from source

```bash
git clone https://github.com/T-h07/MuzikBelesh.git
cd MuzikBelesh

# On macOS, with Xcode and XcodeGen installed:
xcodegen generate
xcodebuild -resolvePackageDependencies -project OFFLINE.xcodeproj -scheme OFFLINE
xcodebuild -project OFFLINE.xcodeproj -scheme OFFLINE \
  -configuration Debug \
  -destination 'generic/platform=iOS Simulator' \
  CODE_SIGNING_ALLOWED=NO build
```

For simulator test runs and the verified arm64 unsigned IPA packaging process, see [Build pipeline](Docs/BUILD_PIPELINE.md). The source app target is `OFFLINE`; the Share extension target is `OFFLINEShareExtension`.

## Branches and development

The repository keeps three long-lived branches:

| Branch | Purpose |
| --- | --- |
| [`main`](https://github.com/T-h07/MuzikBelesh/tree/main) | Stable repository baseline |
| [`develop`](https://github.com/T-h07/MuzikBelesh/tree/develop) | Default branch; ongoing integration |
| [`release`](https://github.com/T-h07/MuzikBelesh/tree/release) | Validated stable releases and tags |

Development took place on short-lived feature branches, integrated through pull requests. **Completed feature branches can be deleted without deleting their merged commits or pull-request history.**

## Documentation

- [Project roadmap](Docs/ROADMAP.md) and [contributing](CONTRIBUTING.md)
- [v1.2.0 release notes](Docs/RELEASE_NOTES_v1.2.0.md), [final release audit](Docs/PHASE_12_FINAL_RELEASE_AUDIT.md), [security audit](Docs/PHASE_12_SECURITY_AUDIT.md) and [performance report](Docs/PHASE_12_PERFORMANCE_REPORT.md)
- [v1.1.0 release notes](Docs/RELEASE_NOTES_v1.1.0.md), [verification](Docs/PHASE_10_09_RELEASE.md), and [hardening audit](Docs/PHASE_10_09_SECURITY_PERFORMANCE.md)
- [v1.0 feature acceptance matrix](Docs/PHASE_09_FEATURE_MATRIX.md)
- [Library architecture](Docs/LIBRARY_ARCHITECTURE.md) and [playlist management](Docs/PLAYLIST_MANAGEMENT.md)
- [Metadata](Docs/METADATA_EDITING.md), [artwork](Docs/ARTWORK_MANAGEMENT.md), and [search/sorting](Docs/LOCAL_SEARCH_AND_SORTING.md)
- [Duplicate detection](Docs/DUPLICATE_DETECTION.md) and [safe deletion](Docs/SAFE_LIBRARY_DELETION.md)
- [Release audit](Docs/PHASE_09_RELEASE_AUDIT.md), [test evidence](Docs/TEST_PLAN.md), and [known limitations](Docs/KNOWN_LIMITATIONS.md)

## Known limitations

- YouTube availability and supported stream formats can change independently of the app; requests require connectivity and can occasionally time out.
- The native Share extension requires you to open Muzik Belesh manually after saving a link.
- iOS controls the scheduling of background transfers; force-quitting the app may stop pending background work.
- The distributed IPA requires personal signing through SideStore.
- Spotify playlist import is **file-based**, not an account connection or direct Spotify URL import.
- Matching and downloading require internet access. iOS may pause or stop background work after a force-quit; saved work is restored when reopened.
- `.mbelesh` files share metadata only; songs not on the receiving iPhone are matched or downloaded there.
- Full list: [known limitations](Docs/KNOWN_LIMITATIONS.md).

---

<div align="center">

**Muzik Belesh · v1.2.0**

Built for personal, offline-first listening.

</div>
