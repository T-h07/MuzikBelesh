# Muzik Belesh

Muzik Belesh is a private, native iPhone music application designed to work without a personal backend. The repository is currently in **Phase 0 — Foundation, CI & Feasibility**.

The foundation uses SwiftUI, Swift Package Manager, and XcodeGen. Windows is supported for editing, Git, and triggering remote builds; iOS compilation and simulator tests run on GitHub Actions macOS runners. The planned bundle identifier is `com.th07.muzikbelesh`.

Phase 0 contains a minimal diagnostics app, an isolated YouTubeKit feasibility probe, a packaging-only Share extension, unit tests, an unsigned IPA workflow, and documentation. It does not contain playback, library, downloads, search, or navigation features from later phases.

## Build

On macOS, install XcodeGen and run `xcodegen generate`. On GitHub, run **CI** for simulator compilation/tests or **Build unsigned IPA** to create the `OFFLINE-unsigned-IPA` artifact. An unsigned IPA must be signed by SideStore before installation.

See [Docs/DEVELOPMENT.md](Docs/DEVELOPMENT.md), [Docs/BUILD_PIPELINE.md](Docs/BUILD_PIPELINE.md), and [Docs/SIDELOADING.md](Docs/SIDELOADING.md).

## Status

Physical iPhone, SideStore, live YouTube extraction, and Share-sheet checks remain device-only acceptance work until evidence is recorded in [Docs/FEASIBILITY.md](Docs/FEASIBILITY.md).

## Documentation

- [Roadmap](Docs/ROADMAP.md)
- [Architecture](Docs/ARCHITECTURE.md)
- [Windows development](Docs/DEVELOPMENT.md)
- [Build pipeline](Docs/BUILD_PIPELINE.md)
- [Feasibility](Docs/FEASIBILITY.md)
- [Test plan](Docs/TEST_PLAN.md)
