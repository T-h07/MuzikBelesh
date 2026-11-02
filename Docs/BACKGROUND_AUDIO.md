# Background audio

`AudioSessionManager` configures `AVAudioSession` with the `.playback` category and activates it only when playback starts or resumes. The generated main-app Info.plist includes `UIBackgroundModes = [audio]`; the Share extension does not receive that capability. Stop deactivates the session with `notifyOthersOnDeactivation`.

The player does not use silent-audio loops or background tasks. Ordinary backgrounding and device locking are supported by the native audio session; force termination is not treated as a background-playback guarantee. Managed audio remains in Documents and is resolved without hardcoded container paths.
