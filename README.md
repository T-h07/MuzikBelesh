<div align="center">

<img src="OFFLINE/Resources/Assets.xcassets/AppIcon.appiconset/AppIcon-1024.png" width="112" alt="Muzik Belesh app icon" />

# Muzik Belesh

### Your music. Your library. Your iPhone. Offline.

A native, offline-first iPhone music player built with **SwiftUI**, **AVFoundation** and **SQLite**. Import your music, build playlists, discover and download supported YouTube audio, migrate Spotify playlists from exports, and take your library between devices.

**No subscription. No mandatory online account. No backend required for your local library.**

[![Latest version](https://img.shields.io/github/v/release/T-h07/MuzikBelesh?display_name=tag&label=Latest%20release)](https://github.com/T-h07/MuzikBelesh/releases/tag/v1.2.0)
![iOS 17+](https://img.shields.io/badge/iOS-17%2B-161616?logo=apple&logoColor=white)
![SwiftUI](https://img.shields.io/badge/SwiftUI-native-161616?logo=swift&logoColor=white)
![Distribution](https://img.shields.io/badge/Distribution-SideStore-222222)
[![CI](https://github.com/T-h07/MuzikBelesh/actions/workflows/ci.yml/badge.svg?branch=develop)](https://github.com/T-h07/MuzikBelesh/actions/workflows/ci.yml)

**[Get v1.2.0](https://github.com/T-h07/MuzikBelesh/releases/tag/v1.2.0)** · **[Download unsigned IPA](https://github.com/T-h07/MuzikBelesh/releases/download/v1.2.0/OFFLINE-unsigned.ipa)** · **[Install / update guide](Docs/SIDELOADING.md)**

</div>

---

## What is Muzik Belesh?

Muzik Belesh is an iOS music player designed around an **on-device library** rather than streaming subscriptions. Add MP3/M4A files from Files, organize songs into albums and playlists, and listen without internet access once the audio is stored locally.

When you want to expand your library, search supported YouTube content, choose an available audio quality, and save it for offline playback. You can also bring in Spotify playlist exports while preserving song order and repeats.

**v1.2.0** adds personal listening statistics, a local profile, configurable colour themes, portable library sharing, and rotating collection artwork.

## Highlights

| Listen | Organize | Discover & acquire |
| --- | --- | --- |
| Offline playback, even with the screen locked | Playlists, albums, artists and liked songs | Search supported YouTube content |
| AirPods, Bluetooth and Control Center controls | Editable titles, artist/album metadata and artwork | Select audio quality and queue downloads |
| Queue, shuffle, repeat and sleep timer | Library-wide search, sorting and in-playlist search | Persistent downloads, retries and progress |
| Background audio and interruption recovery | Duplicate-aware import, export and safe deletion | Wi-Fi-only option and background transfers |

| Make it yours | Move your library |
| --- | --- |
| Local profile with name and optional photo | Import Spotify playlist exports without Spotify sign-in |
| **Your Listening**: 7-day, 30-day and all-time statistics | Keep playlist order, repeated songs and unresolved entries |
| Eight colour presets plus a custom accent picker | Export playlists or your library as a portable `.mbelesh` file |
| Rotating 2×2 collection artwork and manual covers | Reuse local matches, review candidates and download missing songs |

## What's new in v1.2.0

### Local profile

Give your library a personal identity with a **display name** and optional avatar. Create the profile on first launch and edit it from the Home header.

The profile is stored **on the iPhone**, not in an online account. There is no registration, password or profile sync server.

[How local profiles work](Docs/PHASE_11_01_LOCAL_PROFILE.md)

### Your Listening — personal music statistics

Open **Profile → Your Listening** to explore what you've actually listened to:

- Listening time across **7 days, 30 days, or all time**.
- An interactive daily activity chart and listening highlights.
- Top songs, artists, albums and playlists.
- Library totals and shortcuts back to your music.

Listening time is based on **audio that advances during actual playback**, including Lock Screen and AirPods use. Pausing, buffering and skipping do not artificially add listening time. Analytics remain local to your device.

[Listening analytics details](Docs/PHASE_11_02_LISTENING_ANALYTICS.md)

### Personalize your theme

Choose from **Original Lime, Purple, Violet, Blue, Cyan, Pink, Red and Orange**, or select your own accent colour. Changes apply across the app immediately, persist after restarting and use contrast-aware foreground colours.

Your theme does not alter music files, listening data or playback.

[Theme system](Docs/PHASE_11_03_CUSTOM_THEMES.md)

### Portable library sharing

Export **one playlist, selected playlists, or your whole library** to a `.mbelesh` document. Send it through Files, AirDrop, Messages or Mail and import it on another iPhone.

The importer preserves playlist order and repeated songs, attempts to reuse recordings already stored on the receiving device, and can help find or download missing audio through the existing matching pipeline.

**Privacy by design:** `.mbelesh` files carry portable song/playlist metadata and public YouTube references; they **do not contain audio bytes**, your avatar, profile, listening history, settings or device file paths.

[Library sharing details](Docs/PHASE_11_04_LIBRARY_SHARING.md)

### Dynamic artwork for your collections

Playlists, albums, artists and Unassigned Songs can display **automatic 2×2 mosaics** built from their own track covers. The selected mosaic rotates on the configured 30-minute cycle while the app is active.

A manual collection cover takes precedence. Global and per-collection artwork preferences are available, and the image pipeline uses a shared bounded cache for smoother scrolling.

[Dynamic artwork details](Docs/PHASE_11_05_DYNAMIC_ARTWORK.md)

### Release refinements

The v1.2.0 hardening work also addresses in-playlist search visibility, accessibility of listening-statistics controls, redundant theme updates, bounded network response handling and release-artifact integrity checks.

[Complete v1.2.0 release notes](Docs/RELEASE_NOTES_v1.2.0.md) · [Security and performance findings](Docs/PHASE_12_FINAL_RELEASE_AUDIT.md)

## Spotify playlist migration

Muzik Belesh supports **file-based Spotify migration**, introduced in v1.1.0 and retained in v1.2.0. No Spotify account linking or Spotify developer credentials are required.

**Supported sources:** Exportify CSV, Spotify account-data JSON, and supported ZIP exports.

1. Export the desired playlist to a supported file.
2. Use the playlist-file import flow in Muzik Belesh and select it from Files.
3. Preview and create the destination playlist. Source order and repeat occurrences are retained.
4. Existing local recordings are matched first; missing entries can be searched and downloaded from supported sources.
5. Open **Migration Details / Issues** to pause, resume, retry, skip, inspect or manually resolve problematic recordings.

The app retains unresolved occurrences rather than discarding songs it cannot match. Large imports, including playlists with up to 10,000 occurrences, are supported by the import pipeline.

**Not supported:** direct Spotify account connection, importing a Spotify playlist URL, or Spotify Share extension imports.

[Migration implementation](Docs/PHASE_10_09_RELEASE.md) · [v1.1.0 release notes](Docs/RELEASE_NOTES_v1.1.0.md)

## YouTube search, downloads and sharing

Search supported YouTube videos within the app or paste a video URL. The acquisition workflow presents available audio choices such as **Data Saver**, **Balanced** and **Best Available**, then queues the selected recording for offline use.

Downloads feature persistent progress, cancellation, retry and a Wi-Fi-only preference. Background transfers are subject to iOS scheduling and network conditions. Availability also depends on the source and third-party discovery services.

**Using the iOS Share extension:**

1. From YouTube or Safari, choose **Share → Muzik Belesh**.
2. Select **Save Link** and finish sharing.
3. **Open Muzik Belesh manually** to process the saved link.
4. Review the media and choose an available quality to download.

Saving a shared link does not automatically begin a download. iOS does not provide a supported Share-extension API to foreground the containing app.

[YouTube architecture](Docs/PHASE_06_YOUTUBE.md) · [Background downloads](Docs/PHASE_07_BACKGROUND_DOWNLOADS.md) · [Known limitations](Docs/KNOWN_LIMITATIONS.md)

## Install on your iPhone

> [!IMPORTANT]
> Muzik Belesh is distributed as an **unsigned IPA** for personal sideloading through **SideStore**. It is **not available on the App Store**. SideStore must sign the app and Share extension with a compatible signing identity.

**Requirements:** iPhone running **iOS 17 or later**, and SideStore configured for installation.

1. Open the **[Muzik Belesh v1.2.0 release](https://github.com/T-h07/MuzikBelesh/releases/tag/v1.2.0)**.
2. Download **[OFFLINE-unsigned.ipa](https://github.com/T-h07/MuzikBelesh/releases/download/v1.2.0/OFFLINE-unsigned.ipa)**.
3. Open the IPA in SideStore, sign it and install.
4. Launch the app, create your local profile if prompted, and import or download music.

**Upgrading from v1.0.0, v1.1.0 or a Phase 11 test build?** Install the new IPA **over the existing app using the same SideStore signing identity**. **Never uninstall first**: that can erase the local library, downloaded songs and playlists.

You can validate the published download using [the SHA-256 checksum](https://github.com/T-h07/MuzikBelesh/releases/download/v1.2.0/OFFLINE-unsigned.ipa.sha256) and [build manifest](https://github.com/T-h07/MuzikBelesh/releases/download/v1.2.0/OFFLINE-build-manifest.json).

[Complete installation and upgrade guide](Docs/SIDELOADING.md)

## Release and verification

| Release | What changed | Release page |
| --- | --- | --- |
| **v1.2.0** · build **200** | Local profile, listening stats, themes, portable sharing, dynamic artwork and release fixes | [Download v1.2.0](https://github.com/T-h07/MuzikBelesh/releases/tag/v1.2.0) |
| v1.1.0 · build 99 | Spotify playlist migration, matching, recovery and playlist tools | [v1.1.0](https://github.com/T-h07/MuzikBelesh/releases/tag/v1.1.0) |
| v1.0.0 · build 195 | Initial complete offline player, downloads and iOS sharing | [v1.0.0](https://github.com/T-h07/MuzikBelesh/releases/tag/v1.0.0) |

The v1.2.0 **unsigned Release IPA** was built from commit `ab3763c` by [GitHub Actions #110](https://github.com/T-h07/MuzikBelesh/actions/runs/44371763077). The developer reported **10/10 PASS** on a final physical-iPhone acceptance checklist, covering upgrade and data preservation, playback, downloads, imported playlists, profile, themes, analytics, artwork and library sharing.

**Verification transparency:** complete final automated regression CI and dedicated playlist-migration verification were **intentionally cancelled** to prioritize the release, and earlier Phase 12 CI runs had failures. The 10 physical checks are **not** equivalent to a fully passing automated suite or completion of the separate 45-item detailed checklist.

[Acceptance report](Docs/PHASE_12_DEVICE_ACCEPTANCE.md) · [Release gates and accepted risks](Docs/PHASE_12_RELEASE_CHECKLIST.md) · [Security audit](Docs/PHASE_12_SECURITY_AUDIT.md) · [Performance report](Docs/PHASE_12_PERFORMANCE_REPORT.md)

## Tech stack

| Area | Implementation |
| --- | --- |
| iOS interface | Swift, SwiftUI, UIKit |
| Audio and system controls | AVFoundation, MediaPlayer |
| Database and persistence | SQLite, GRDB |
| Network and downloads | URLSession, Network framework, background transfers |
| Media discovery | YouTubeKit, Invidious / SearXNG support |
| Portable documents | JSON-based `.mbelesh` metadata, ZIPFoundation for supported imports |
| Project and tooling | XcodeGen, GitHub Actions, XCTest |
| Distribution | Unsigned IPA, SideStore re-signing |

The project targets iOS 17+. On GitHub Actions, the v1.2.0 pipeline uses a pinned Xcode/XcodeGen toolchain on macOS runners.

## Build from source

Native iOS builds require **macOS with Xcode and XcodeGen**. Swift source and documentation can also be edited on Windows, with GitHub Actions handling native builds.

```bash
git clone https://github.com/T-h07/MuzikBelesh.git
cd MuzikBelesh
git switch develop

xcodegen generate
xcodebuild -resolvePackageDependencies \
  -project OFFLINE.xcodeproj -scheme OFFLINE

xcodebuild -project OFFLINE.xcodeproj -scheme OFFLINE \
  -configuration Debug \
  -destination 'generic/platform=iOS Simulator' \
  CODE_SIGNING_ALLOWED=NO build
```

The primary app target is `OFFLINE`; its native sharing target is `OFFLINEShareExtension`. For Release IPA packaging, CI test scopes, build numbers, the manifest and signing metadata, read the [build pipeline](Docs/BUILD_PIPELINE.md).

## Repository branches

| Branch | Responsibility |
| --- | --- |
| [`develop`](https://github.com/T-h07/MuzikBelesh/tree/develop) | Default branch for ongoing development and integration |
| [`release`](https://github.com/T-h07/MuzikBelesh/tree/release) | Owner-reviewed release integration |
| [`main`](https://github.com/T-h07/MuzikBelesh/tree/main) | Published stable source and release tags |

Feature branches are integrated through pull requests. Existing release tags and assets are preserved. See [CONTRIBUTING.md](CONTRIBUTING.md) for changes, tests and PR expectations.

## Documentation

**Getting started:** [Install and update](Docs/SIDELOADING.md) · [Build pipeline](Docs/BUILD_PIPELINE.md) · [Contributing](CONTRIBUTING.md) · [Roadmap](Docs/ROADMAP.md)

**Current features:** [Profile](Docs/PHASE_11_01_LOCAL_PROFILE.md) · [Your Listening](Docs/PHASE_11_02_LISTENING_ANALYTICS.md) · [Themes](Docs/PHASE_11_03_CUSTOM_THEMES.md) · [Library sharing](Docs/PHASE_11_04_LIBRARY_SHARING.md) · [Dynamic artwork](Docs/PHASE_11_05_DYNAMIC_ARTWORK.md)

**Core systems:** [Architecture](Docs/ARCHITECTURE.md) · [Playback](Docs/AUDIO_ENGINE.md) · [Library](Docs/LIBRARY_ARCHITECTURE.md) · [Playlist migration](Docs/PHASE_10_09_RELEASE.md) · [Database migrations](Docs/MIGRATIONS.md)

**Release engineering:** [v1.2.0 notes](Docs/RELEASE_NOTES_v1.2.0.md) · [Final audit](Docs/PHASE_12_FINAL_RELEASE_AUDIT.md) · [Acceptance and CI caveats](Docs/PHASE_12_RELEASE_CHECKLIST.md) · [Known limitations](Docs/KNOWN_LIMITATIONS.md)

## Important limitations

- **Offline playback works after audio is stored locally.** Finding and downloading new audio requires internet access.
- YouTube formats, restrictions and third-party discovery services can change independently of the app.
- Spotify migration accepts exported files, **not** live account access or direct playlist URLs.
- Portable `.mbelesh` documents contain **metadata, not music files**.
- Share-extension links require opening Muzik Belesh manually.
- iOS decides background task scheduling; force-quitting prevents background work until the app is reopened.
- SideStore installation and refresh rules depend on your signing setup; the public IPA is unsigned.

Read [all known limitations](Docs/KNOWN_LIMITATIONS.md) before relying on background downloads or cross-device migration.

---

<div align="center">

**Muzik Belesh · v1.2.0**

Built for personal, offline-first listening.

[Latest release](https://github.com/T-h07/MuzikBelesh/releases/latest) · [Release notes](Docs/RELEASE_NOTES_v1.2.0.md) · [Report an issue](https://github.com/T-h07/MuzikBelesh/issues)

</div>
