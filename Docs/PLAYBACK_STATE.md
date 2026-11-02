# Playback state

`AudioPlaybackState` is the single observable source for current track ID, status, elapsed time, duration, seeking capability, skip capability, output route, and the last error. Mini-player, full-screen Now Playing, Now Playing metadata, and remote commands all consume the same `AudioPlayerService`.

Pause, seek, stop, track changes, end-of-track, and interruption transitions save a bounded `playback_state` snapshot through the Phase 2 repository. On cold launch, a saved track is resolved and rebuilt as a paused AVPlayer item at its saved position; missing files become a user-visible failed state without deleting metadata.
