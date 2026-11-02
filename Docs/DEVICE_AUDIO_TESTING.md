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
# Phase 3 device-validation hotfix

Commit `1aff803` corrects the import foreign-key insertion order and cleans staged, audio, and artwork files when an import transaction fails. It also makes the shared `AudioPlayerService` the direct SwiftUI observation source, uses an isolated scrubbing value for seeking, adds complete iPhone icon slots, and replaces the fixed mini-player offset with safe-area-aware layout.

The CI build passed 22 tests and the unsigned IPA build passed. The IPA contains compiled `Assets.car` and `OFFLINEShareExtension.appex`. iOS may cache application icons after an update; verify the icon after installing the new build, and restart SpringBoard or reinstall only if the device continues showing a cached icon.

The responsive UI correction uses a safe-area inset for the mini-player instead of a tab-bar offset, separates its navigation and transport hit regions, and sizes Now Playing artwork from the available geometry. Home shortcuts use adaptive columns, and imported library rows retain 44-point actions with truncation for long filenames.

The app now declares `UILaunchScreen` in both the XcodeGen source configuration and the checked-in source plist. The IPA packaging script verifies the compiled launch-screen key, `Assets.car`, and the embedded Share extension. Build number `3` is used for the device re-test; the bundle identifier remains unchanged so an in-place update can retain user data.

The final playback/navigation hotfix puts the mini-player safe-area inset inside each tab page, leaving the native tab bar outside that inset. It adds Previous, refreshes the deterministic available-track context after imports, serializes track transitions, ignores stale item-end notifications, and skips missing upcoming files without changing unrelated records.

## Required re-test on iPhone 13 Pro Max

Install artifact `OFFLINE-unsigned-IPA` from the [unsigned IPA workflow](https://github.com/T-h07/MuzikBelesh/actions/runs/41539143347), preserving the existing app data. Record each result as PASS, FAIL, or NOT RUN:

- Existing imported files remain available after the in-place update.
- New MP3 import succeeds with artist/album metadata.
- New M4A import succeeds with artist-only and artist-plus-album metadata.
- Repeated artist/album identities resolve without a SQLite foreign-key error.
- Failed import leaves no incomplete audio/artwork files.
- App icon renders as Muzik Belesh rather than the generic placeholder.
- Mini-player and Now Playing immediately switch between Play and Pause.
- Elapsed time and duration match a 42-second MP3, a 90-second M4A, and a track longer than five minutes.
- Seeking forward, backward, near the end, and from the lock screen works without changing the prior play/pause intent.
- Now Playing controls are fully visible; mini-player buttons do not open Now Playing accidentally.
- Background playback, lock-screen controls, headphone controls, export, and Share extension remain functional.
- A competing audio/video app interrupts Muzik Belesh and the in-app state changes to paused/interrupted without falsely resuming.
# Phase 3 final acceptance

Status: **Complete — developer-reported and accepted physical iPhone validation.**

The developer tested the final Phase 3 IPA on an iPhone 13 Pro Max and accepted local MP3/M4A importing, SQLite integrity, real playback, seeking, Previous/Next, automatic advancement, export, background playback, Lock Screen and earphone controls, app icon, full-screen layout, mini-player navigation, and access to all four tabs while playing. These results are manual device evidence, not automated Codex hardware testing. Exhaustive Bluetooth compatibility, every interruption scenario, and prolonged stress testing remain **NOT VERIFIED**.

