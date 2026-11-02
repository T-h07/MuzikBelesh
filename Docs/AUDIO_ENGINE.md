# Native audio engine

Phase 3 uses one `@MainActor` `AudioPlayerService` backed by one `AVPlayer`. It resolves a stable track ID through the Phase 2 GRDB repository and `Documents/Music` relative path, validates readability, installs a new `AVPlayerItem`, and observes item status and end-of-track notifications. A 500 ms periodic time observer drives elapsed time and is removed when the item changes.

The service exposes typed idle/loading/ready/playing/paused/interrupted/ended/failed state. Play, pause, resume, stop, seek, basic previous, basic next, and non-wrapping end advancement all update the same observable state consumed by Library, MiniPlayer, and Now Playing. Playback context refreshes from available persistent tracks, transitions are serialized, and stale completion notifications are ignored. Phase 3 playback was accepted in developer-reported iPhone 13 Pro Max validation. Advanced queue editing, shuffle, repeat, history, and sleep timer remain Phase 4 work.
