# Muzik Belesh

Muzik Belesh is a private, native iPhone music application designed to work without a personal backend. The repository is currently in **Phase 1 — Design System, UI & Application Navigation**.

The foundation uses SwiftUI, Swift Package Manager, and XcodeGen. Windows is supported for editing, Git, and triggering remote builds; iOS compilation and simulator tests run on GitHub Actions macOS runners. The planned bundle identifier is `com.th07.muzikbelesh`.

Phase 0 is complete and device-verified. Phase 1 adds the black/lime design system, four-tab SwiftUI presentation layer, reusable components, deterministic mock data, shared mock playback/download state, and simulator-tested UI navigation. Playback, persistence, real downloads, production YouTube discovery, and Share-to-app handoff remain deferred to later phases. This is not yet the complete music player.

## Build

On macOS, install XcodeGen and run `xcodegen generate`. On GitHub, run **CI** for simulator compilation/tests or **Build unsigned IPA** to create the `OFFLINE-unsigned-IPA` artifact. An unsigned IPA must be signed by SideStore before installation.

See [Docs/DEVELOPMENT.md](Docs/DEVELOPMENT.md), [Docs/BUILD_PIPELINE.md](Docs/BUILD_PIPELINE.md), and [Docs/SIDELOADING.md](Docs/SIDELOADING.md).

## Status

Phase 0 physical evidence is recorded in [Docs/FEASIBILITY.md](Docs/FEASIBILITY.md). Phase 1 interface validation is simulator/UI-test based; no new physical-device claim is made.

## Documentation

- [Roadmap](Docs/ROADMAP.md)
- [Architecture](Docs/ARCHITECTURE.md)
- [Windows development](Docs/DEVELOPMENT.md)
- [Build pipeline](Docs/BUILD_PIPELINE.md)
- [Feasibility](Docs/FEASIBILITY.md)
- [Test plan](Docs/TEST_PLAN.md)
