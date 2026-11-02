# Muzik Belesh

Muzik Belesh is a private, native iPhone music application designed to work without a personal backend. The repository is currently in **Phase 1 — Design System, UI & Application Navigation**.

The foundation uses SwiftUI, Swift Package Manager, and XcodeGen. Windows is supported for editing, Git, and triggering remote builds; iOS compilation and simulator tests run on GitHub Actions macOS runners. The planned bundle identifier is `com.th07.muzikbelesh`.

Phase 0 is complete and device-verified. Phase 1 adds the black/lime design system and four-tab SwiftUI presentation layer. Phase 2 adds GRDB-backed local persistence, Files-visible Music and Artwork directories, supported-audio import/export, metadata extraction, streaming hashes, duplicate detection, and recovery-aware storage. Production playback, network downloads, and Share-to-app handoff remain deferred; this is not yet the complete music player.

## Build

On macOS, install XcodeGen and run `xcodegen generate`. On GitHub, run **CI** for simulator compilation/tests or **Build unsigned IPA** to create the `OFFLINE-unsigned-IPA` artifact. An unsigned IPA must be signed by SideStore before installation.

See [Docs/DEVELOPMENT.md](Docs/DEVELOPMENT.md), [Docs/BUILD_PIPELINE.md](Docs/BUILD_PIPELINE.md), and [Docs/SIDELOADING.md](Docs/SIDELOADING.md).

## Status

Phase 0 physical evidence is recorded in [Docs/FEASIBILITY.md](Docs/FEASIBILITY.md). Phase 2 storage validation is covered by isolated migration/repository tests and CI; physical Files import, relaunch, export, and SideStore checks remain device acceptance work.

## Documentation

- [Roadmap](Docs/ROADMAP.md)
- [Architecture](Docs/ARCHITECTURE.md)
- [Windows development](Docs/DEVELOPMENT.md)
- [Build pipeline](Docs/BUILD_PIPELINE.md)
- [Feasibility](Docs/FEASIBILITY.md)
- [Test plan](Docs/TEST_PLAN.md)
