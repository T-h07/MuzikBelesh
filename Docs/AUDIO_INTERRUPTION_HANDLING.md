# Audio interruptions and route changes

Interruption begin pauses the AVPlayer and records whether playback was active. Interruption end resumes only when iOS supplies `shouldResume` and the user did not deliberately pause during the interruption. Otherwise the state returns to paused.

`AudioRouteMonitor` observes `AVAudioSession.routeChangeNotification`, updates the displayed route, and pauses only for `oldDeviceUnavailable` while playing. Ordinary new-route changes are left to the system. Missing or invalid managed files produce a typed failure state while preserving the library record.
