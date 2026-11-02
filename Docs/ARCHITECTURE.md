# Architecture

`OFFLINEApp` creates a small `AppContainer` with environment-aware `AppConfiguration` and the `YouTubeProbe` abstraction. `DiagnosticsView` renders only foundation status; `DiagnosticsViewModel` owns UI state and receives dependencies through the container.

The YouTubeKit adapter is isolated under `OFFLINE/Feasibility/YouTube`. It validates input, requests metadata and streams locally, filters audio-only streams, and returns sanitized result data. It does not enable YouTubeKit's remote fallback and does not persist or download media.

The Share extension is a separate target with its own bundle identifier and activation metadata. Phase 0 validates received URLs and finishes cleanly; the physical iPhone test confirmed Share-sheet appearance and URL receipt. No unsupported extension-to-app launch or App Group entitlement is assumed. Automatic handoff is deferred to Phase 8.

Later phases may add the production YouTube integration and download manager, SQLite/GRDB repositories, AVFoundation/MediaPlayer playback, and a supported Share handoff. Development infrastructure remains outside runtime code.

