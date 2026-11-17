# Contributing to Muzik Belesh

Thanks for your interest in contributing. **Muzik Belesh** is a native, offline-first SwiftUI music player for personal iPhone use, with local audio, a persistent library, YouTube search/downloads, and file-based Spotify playlist migration (v1.1.0).

Please keep pull requests focused, preserve existing music libraries, and never introduce account credentials or a required backend.

## Project and release model

The repository uses these long-lived branches:

| Branch | Purpose |
| --- | --- |
| `develop` | Default integration branch; the base for normal contributions |
| `release` | Owner-approved release promotion and stable packaging |
| `main` | Published stable code and GitHub release tags |

Create feature and fix branches from `develop`, using descriptive names such as `feature/playlist-improvement` or `fix/share-inbox-recovery`. Open pull requests **into `develop`**, not directly into `main` or `release`.

A version release is promoted **from `develop` to `release`, then synchronized with `main`**. Only after owner approval are the corresponding version tag and GitHub Release published. Never publish automatically from a feature branch. Preserve long-lived branch history; do not force-push release branches.

## Development setup

The app and Share extension are written in **Swift**, with **SwiftUI**, **AVFoundation / MediaPlayer**, **GRDB / SQLite**, and **URLSession**. XcodeGen generates the Xcode project from `project.yml`.

- Editing, Git and source checks can be done on Windows, including via an editor and GitHub.
- Native iOS compilation and XCTest require macOS with Xcode. GitHub Actions uses **Xcode 26.2** and **XcodeGen 2.46.0** for the current release pipeline.
- Supported deployment target: **iOS 17+**.
- The app target is `OFFLINE`; the extension target is `OFFLINEShareExtension`.

On macOS:

```bash
git clone https://github.com/T-h07/MuzikBelesh.git
cd MuzikBelesh
git switch develop
xcodegen generate
xcodebuild -resolvePackageDependencies -project OFFLINE.xcodeproj -scheme OFFLINE
xcodebuild -project OFFLINE.xcodeproj -scheme OFFLINE \
  -configuration Debug -destination 'generic/platform=iOS Simulator' \
  CODE_SIGNING_ALLOWED=NO build
```

See [Build pipeline](Docs/BUILD_PIPELINE.md) and [SideStore installation](Docs/SIDELOADING.md) for verification and device-distribution details.

## Contribution guidelines

- Prefer small changes with a clear problem statement and relevant tests.
- Preserve local track identities, playlist occurrence order, repeated entries, file references, migration/recovery state and the existing SQLite migration history.
- Never reset or erase a user's database as a repair strategy. Use isolated temporary directories for destructive tests.
- Keep security boundaries explicit: validate external URLs and imported CSV/JSON/ZIP/audio, use parameterized SQL, preserve safe file ownership and atomic writes, and avoid unbounded work on untrusted input.
- Avoid heavy work on SwiftUI render paths and unnecessary blocking operations on the main actor. Measure performance changes where possible; don't assert device energy improvements from simulator timings.
- Keep async task ownership, cancellation and background-operation recovery clear. iOS controls background execution and stops or defers work after a user force-quit.
- Don't reintroduce the **canceled Spotify OAuth/Web API flow**. The v1.1.0 Spotify migration feature accepts **Exportify CSV, Spotify account-data JSON and supported ZIP exports** without an account login.
- Avoid unrelated refactors, feature creep and UI redesigns in bug-fix PRs. Document high-risk architectural proposals for separate review.
- Use concise comments where behavior is non-obvious. Update README and other docs when public behavior changes.

## Tests and evidence

Before opening a PR:

1. Run `python3 Scripts/check-test-hygiene.py` and `git diff --check`.
2. Run appropriate unit/integration tests for the changed components using macOS or GitHub Actions.
3. Test relevant user interactions on a physical device when changing playback, downloads, share handling, storage or migrations.
4. Include the exact commit SHA, test commands/run links and outcomes in the PR description.
5. Mark unexecuted verification **NOT RUN**, unavailable verification **BLOCKED**, and failures **FAIL**. Never imply that skipped tests passed.
6. Identify pre-existing failures separately from failures introduced by the PR, with evidence.

The v1.1.0 focused release verification completed **261 tests with no failures**. The final full regression retained seven documented baseline failures (six migration/review UI tests and one coordinator timing case); those failures must not be concealed or described as passing. See [Phase 10.9 release evidence](Docs/PHASE_10_09_RELEASE.md) and the [hardening audit](Docs/PHASE_10_09_SECURITY_PERFORMANCE.md).

## Pull request checklist

- [ ] My branch is based on `develop` and contains only the intended change.
- [ ] No user-data deletion or unexpected schema changes.
- [ ] Security and concurrency risks have been considered.
- [ ] Relevant tests ran and their actual results are documented.
- [ ] I updated docs for any user-facing behavior change.
- [ ] I did not commit secrets, certificates, provisioning profiles, API tokens, signed/unsigned IPA files, Xcode build outputs or generated `.xcodeproj` artifacts.
- [ ] Any required device test is explicitly recorded.

## Release and signing safety

Version tags and stable GitHub Releases are **owner-controlled**. Produce unsigned IPAs through the pinned GitHub Actions workflow; the main app and Share extension must retain compatible bundle identifiers and App Group entitlements so SideStore can sign an **in-place update**.

**Never instruct an existing user to uninstall the app before upgrading.** Uninstalling can delete the local music library. Use the same SideStore signing identity for an update, and keep a backup of important local music.

See [v1.1.0 release notes](Docs/RELEASE_NOTES_v1.1.0.md), [known limitations](Docs/KNOWN_LIMITATIONS.md), and [the project README](README.md).
