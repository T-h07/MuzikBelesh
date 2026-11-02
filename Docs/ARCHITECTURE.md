# Architecture

`OFFLINEApp` creates an `AppContainer` with environment-aware `AppConfiguration`, the Phase 0 `YouTubeProbe`, and Phase 1 in-memory stores. `RootView` and `AppCoordinator` own tab and presentation state. Feature views receive shared stores through the SwiftUI environment; focused view models can be added without introducing global singletons. `DiagnosticsView` remains available from Settings and is not part of normal music browsing.

The YouTubeKit adapter is isolated under `OFFLINE/Feasibility/YouTube`. It validates input, requests metadata and streams locally, filters audio-only streams, and returns sanitized result data. It does not enable YouTubeKit's remote fallback and does not persist or download media.

The Share extension is a separate target with its own bundle identifier and activation metadata. Phase 0 validates received URLs and finishes cleanly; the physical iPhone test confirmed Share-sheet appearance and URL receipt. No unsupported extension-to-app launch or App Group entitlement is assumed. Automatic handoff is deferred to Phase 8.

Later phases may add the production YouTube integration and download manager, SQLite/GRDB repositories, AVFoundation/MediaPlayer playback, and a supported Share handoff. Development infrastructure remains outside runtime code.

