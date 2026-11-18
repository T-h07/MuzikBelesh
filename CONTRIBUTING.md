# Contributing to Muzik Belesh

Muzik Belesh is a native, offline-first iOS music player. The current stable release is **[v1.2.0](https://github.com/T-h07/MuzikBelesh/releases/tag/v1.2.0)**.

The codebase includes playback and persistent queues, local library management, YouTube search/download workflows, Spotify playlist-file migration, a local profile, listening analytics, custom themes, portable `.mbelesh` sharing and dynamic collection artwork.

Contributions should **preserve users' music libraries** and improve well-defined behavior. A small, verified correction is preferable to a large speculative rewrite.

## Branches and pull requests

| Branch | Purpose |
| --- | --- |
| `develop` | Default development branch and target for feature/bug-fix pull requests |
| `release` | Owner-reviewed stable release integration |
| `main` | Published stable source and release tags |

Create a descriptive `feature/`, `fix/` or `docs/` branch from `develop`. Open a PR against `develop`; avoid direct changes to stable release branches. Releases are promoted by reviewed merges to `release` and `main`, followed by the owner-authorized tag and GitHub Release.

Do not force-push `release` or `main`, rewrite published tags, or replace previously distributed IPA bytes.

## Development environment

- **Language/UI:** Swift, SwiftUI and UIKit.
- **Playback:** AVFoundation and MediaPlayer.
- **Storage:** SQLite / GRDB, managed audio and artwork files.
- **Downloads:** URLSession foreground and background transfers.
- **Media discovery:** YouTubeKit, supported public Invidious and configured SearXNG.
- **Imports:** Spotify CSV/JSON/ZIP and portable `.mbelesh` metadata documents.
- **Build:** XcodeGen; native builds and XCTest on macOS.
- **Minimum supported OS:** iOS 17.

The current CI configuration uses **Xcode 26.2** and **XcodeGen 2.46.0**. Run and inspect the workflows to verify toolchain availability rather than assuming all macOS images include the pinned versions.

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

You may edit source on Windows, but a Windows Swift compiler is not a substitute for an iOS SDK/Xcode build. Use macOS or GitHub Actions to verify native changes.

See [build pipeline](Docs/BUILD_PIPELINE.md) and [SideStore installation](Docs/SIDELOADING.md).

## Architectural invariants

Before changing code, read the [architecture](Docs/ARCHITECTURE.md) and related subsystem documentation.

- **One audio engine:** playback, queue, sleep timer, Lock Screen and Bluetooth controls use the established audio service; do not add a second player.
- **One persistent library:** retain GRDB/SQLite as the authoritative state. Never reset a user's database as a shortcut or change historical migration IDs.
- **Order and repeats matter:** imported and ordinary playlists must preserve occurrence identity, ordering and duplicates.
- **Atomic file operations:** validate paths, maintain file-operation recovery semantics, and do not delete a recording still referenced elsewhere.
- **Migration isolation:** preserve placeholders, review decisions, retry state, cancellation and recovery across relaunch.
- **Local-first privacy:** usernames, avatars, listening history and preferences stay on-device and must not leak into portable exports.
- **Share extension safety:** use the App Group inbox and documented handoff flow. Do not use private APIs to launch the containing app.
- **Background correctness:** iOS governs scheduling. Do not promise execution after force-quit or create multiple concurrent download coordinators.
- **View performance:** avoid expensive queries, repeated image decoding, redundant observers and unnecessary work on the main actor.
- **User-visible accessibility:** retain VoiceOver traits and stable UI test identifiers.

Keep the main app and extension identifiers plus App Group intact. They are part of the established SideStore in-place-upgrade contract.

## Feature-specific change guidance

**Spotify migration:** imports are **file-based**, using Exportify CSV, supported account-data JSON and ZIP. The direct Spotify OAuth/API/Share workflow was explicitly canceled. Do not reintroduce it as an incidental dependency.

**Listening analytics:** credit actual progressing playback, not skipped, paused, buffering or seeked time. Analytics failures must not stop audio.

**Themes:** changing accent colours must not mutate playlists, profile, playback or analytics. Re-selecting the active theme should not cause unnecessary work.

**Portable library sharing:** `.mbelesh` files contain portable metadata, not audio bytes, user profile, analytics, private settings or device paths. Always validate untrusted documents.

**Dynamic artwork:** use existing shared image caches and collection-specific selections. Respect manual cover precedence, per-collection mode and the app's rotation interval.

## Testing and evidence

Before submitting a PR:

1. Run `python3 Scripts/check-test-hygiene.py` and `git diff --check`.
2. Execute affected XCTest/unit/UI tests when a macOS runner is available.
3. For changes to playback, database migrations, managed files, downloads or Share extension, include physical iPhone acceptance where relevant.
4. Record the tested commit, workflow links, test counts and failed assertions.
5. Treat **FAIL**, **CANCELLED**, **SKIPPED**, **BLOCKED** and **NOT RUN** as distinct from PASS.
6. For performance fixes, document comparable measured baselines rather than claimed improvements.
7. Document external network/service dependencies and error behavior.

**Current release context:** v1.2.0 build 200 passed **10/10 owner-reported expedited physical-device checks**. The final complete CI and playlist migration verification were canceled, with earlier Phase 12 failures documented as accepted release risks. New changes should still run the relevant tests; previous risk acceptance is not permission to disable or weaken them.

[Phase 12 acceptance](Docs/PHASE_12_DEVICE_ACCEPTANCE.md) · [Release gate record](Docs/PHASE_12_RELEASE_CHECKLIST.md) · [Test reliability guide](Docs/TESTING_RELIABILITY.md)

## Pull request checklist

- [ ] Based on `develop` with a focused diff and clear motivation.
- [ ] No destructive database migration, loss of files or change to published IDs.
- [ ] Security, privacy and concurrency impact considered.
- [ ] Relevant tests executed; results and incomplete checks recorded accurately.
- [ ] Physical-device retesting described if the change affects app/extension or installation behavior.
- [ ] README/docs updated for user-facing changes.
- [ ] No secrets, signing keys, provisioning profiles, generated Xcode build outputs or IPA artifacts committed.

## Publishing and SideStore safety

Version tags and public releases are controlled by the project owner. The unsigned IPA must include compatible bundle identifiers and App Group entitlement metadata so the user's SideStore signing setup can preserve the existing app container.

**Do not ask users to uninstall Muzik Belesh before updating.** Uninstalling can remove the user's downloaded music, database and playlists. Recommend preserving independent copies of important audio.

For the full current product overview, see [README.md](README.md). For release artifacts, consult the [v1.2.0 GitHub Release](https://github.com/T-h07/MuzikBelesh/releases/tag/v1.2.0).
