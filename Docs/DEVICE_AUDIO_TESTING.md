# Physical-device audio testing

The simulator and CI can verify compilation, generated background configuration, local AVPlayer loading, state transitions, and the generated-WAV integration test. The following tests must be run on an actual iPhone using the unsigned IPA and SideStore before Phase 3 can be called device-verified:

1. Import an MP3 or M4A from Files; tap it in Library; confirm audible playback.
2. Verify pause, resume, seek, previous, next, and automatic advancement.
3. Background the app for several minutes; confirm audio continues.
4. Lock the iPhone; confirm audio continues and Lock Screen title, artist, artwork, and controls are correct.
5. Use Control Center, AirPods, or Bluetooth play/pause/seek/skip controls.
6. Disconnect headphones and verify safe pause/route behavior.
7. Trigger a call or Siri interruption; verify conditional resume.
8. Remove or rename the managed file; verify the app reports the missing file without crashing.
9. Force-quit and relaunch; verify the saved track and position restore without auto-playing.

Record PASS, FAIL, NOT RUN, or BLOCKED for every item. CI success is not physical-device evidence.
