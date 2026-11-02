# Architecture

`OFFLINEApp` creates a small `AppContainer` with environment-aware `AppConfiguration` and the `YouTubeProbe` abstraction. `DiagnosticsView` renders only foundation status; `DiagnosticsViewModel` owns UI state and receives dependencies through the container.

The YouTubeKit adapter is isolated under `OFFLINE/Feasibility/YouTube`. It validates input, requests metadata and streams locally, filters audio-only streams, and returns sanitized result data. It does not enable YouTubeKit's remote fallback and does not persist or download media.

The Share extension is a separate target with its own bundle identifier and activation metadata. It validates received URLs and finishes cleanly. No unsupported extension-to-app launch or App Group entitlement is assumed. A future phase can evaluate a supported handoff after signing evidence exists.

Later phases may add MVVM view models, SQLite/GRDB repositories, AVFoundation/MediaPlayer playback, and URLSession services. Development infrastructure remains outside runtime code.

