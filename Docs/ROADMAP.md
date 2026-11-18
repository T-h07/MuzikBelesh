# Muzik Belesh — Roadmap and release history

Muzik Belesh is a **completed, offline-first native iOS music app** with an on-device music library, playback, downloads, playlist migration, personalization and portable library sharing.

**Current stable release:** [v1.2.0](https://github.com/T-h07/MuzikBelesh/releases/tag/v1.2.0) · **Build 200** · published **18 November 2026**.

This page is a historical implementation roadmap, **not a list of unfinished feature commitments**.

## Published versions

| Release | Published | Scope |
| --- | --- | --- |
| [v1.0.0](https://github.com/T-h07/MuzikBelesh/releases/tag/v1.0.0) | 6 Nov 2026 | Offline music library, audio engine, downloads, background playback and iOS Share extension |
| [v1.1.0](https://github.com/T-h07/MuzikBelesh/releases/tag/v1.1.0) | 17 Nov 2026 | Spotify playlist-file migration, local-first matching, acquisition, retry and review workflows |
| **[v1.2.0](https://github.com/T-h07/MuzikBelesh/releases/tag/v1.2.0)** | **18 Nov 2026** | Local profiles, listening analytics, theme customization, portable `.mbelesh` library sharing, dynamic artwork and release hardening |

## Completed implementation phases

| Phase | Scope | Outcome |
| --- | --- | --- |
| 0 | Feasibility, app foundation, XcodeGen and CI | Complete |
| 1 | SwiftUI design system, navigation and player presentation | Complete |
| 2 | SQLite/GRDB persistence and managed-file storage | Complete |
| 3 | Native AVFoundation audio playback | Complete |
| 4 | Queue, shuffle/repeat, history, restoration and sleep timer | Complete |
| 5 | Library, playlists, albums, metadata and artwork management | Complete |
| 6 | YouTube search, metadata and audio selection | Complete |
| 7 / 7.1 | Foreground/background downloads and network policy | Complete |
| 8 | Share extension and durable shared-link inbox | Complete |
| 9 | Integration, physical acceptance and v1.0.0 release | Released |
| 10.1–10.7 | Spotify export parsing, playlist migration, matching, acquisition, recovery and review UI | Complete |
| 10.8 | Proposed Spotify OAuth/Share integration | **Canceled intentionally**; file export remains the supported import path |
| 10.9 | v1.1.0 validation, security and release | Released |
| 11.1 | Local profile and optional avatar | Complete |
| 11.2 | Your Listening statistics and activity dashboard | Complete |
| 11.3 | Accent presets, custom themes and persistence | Complete |
| 11.4 | Portable library export/import using `.mbelesh` documents | Complete |
| 11.5 | Automatic rotating 2×2 collection artwork and cover preferences | Complete |
| 12 | Targeted accessibility, security, performance, packaging and upgrade corrections | **Released with v1.2.0** |

## Version 1.2.0 release evidence

- **Accepted application source:** `ab3763cd0a1f9dfec628bd590d3a2627bb34118f`.
- **Unsigned IPA:** build 200, [Actions run #110](https://github.com/T-h07/MuzikBelesh/actions/runs/44371763077).
- **Device acceptance:** developer-reported **10/10 PASS** on the expedited iPhone release checklist.
- **Release promotion:** Phase 12 [PR #30](https://github.com/T-h07/MuzikBelesh/pull/30) → `develop`, [PR #31](https://github.com/T-h07/MuzikBelesh/pull/31) → `release`, [PR #32](https://github.com/T-h07/MuzikBelesh/pull/32) → `main`.
- **Verification limitation:** final comprehensive CI and migration verification runs were intentionally canceled, with earlier failures documented and accepted by the owner. Do not describe full automated testing as green.

See [v1.2.0 release notes](RELEASE_NOTES_v1.2.0.md), [physical-device report](PHASE_12_DEVICE_ACCEPTANCE.md), [release gates](PHASE_12_RELEASE_CHECKLIST.md) and [known limitations](KNOWN_LIMITATIONS.md).

## Maintenance after v1.2.0

The feature roadmap has reached its v1.2.0 target. Future work is **not pre-committed**; prioritize reproducible defect reports, device compatibility, source-provider changes, accessibility and data preservation before introducing additional features.

For development practices, see [CONTRIBUTING.md](../CONTRIBUTING.md). Feature branches may be deleted after merging without removing their reviewed commit history.
