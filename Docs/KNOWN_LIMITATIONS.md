# Known limitations — Muzik Belesh v1.2.0

These are platform and product limits that remain true for v1.2.0. They are not defects
waived for release; release-risk decisions are recorded in
[PHASE_12_RELEASE_CHECKLIST.md](PHASE_12_RELEASE_CHECKLIST.md).

## Installation and signing

- The release IPA is **unsigned**. SideStore (or a compatible signer) must sign both the app
  and the Share extension with the user's identity. Ad-hoc entitlement metadata declares
  `group.com.th07.muzikbelesh.inbox` on both executables so the signer can request it; the
  metadata alone does not authorize installation.
- Updating keeps your library only when the new IPA is installed **over** the existing app
  with the same signing identity. Uninstalling first deletes the app container, including
  the database and downloaded audio.
- Free Apple Accounts normally require a seven-day refresh and limit sideloaded App IDs.

## YouTube and network discovery

- YouTube availability, formats, region restrictions and extraction compatibility change
  independently of the app. Deterministic test fixtures do not prove live availability.
- Invidious and SearXNG discovery depend on third-party or user-run servers. Local-network
  SearXNG is allowed by an explicit ATS local-networking exception and a local-network usage
  prompt; public endpoints must use HTTPS.
- Metadata responses are limited to 8 MB (YouTube) and 4 MB (discovery), enforced while
  streaming. A legitimate response above those limits is reported as unavailable.
- The native background URLSession follows redirects under iOS control; prepared and
  completed sources are validated, but each redirect cannot be inspected before contact.

## Background execution and lifecycle

- iOS owns background scheduling. Force-quitting stops background transfers and matching
  until the app is reopened; saved work is reconciled on the next launch. No code runs after
  a force-quit.
- Audio continues in the background only while iOS permits it (calls, other audio apps and
  interruptions can pause it).
- Playback position is checkpointed every 5 s of progress and listening analytics every
  15 s of credited audio. An abrupt process kill can lose up to those last few seconds;
  normal pause and background transitions persist immediately.
- Serious or critical thermal state defers new optional work; active native transfers are
  allowed to finish. Low Power Mode lowers download concurrency without changing the saved
  preference.

## Sharing, import and export

- The Share extension saves a validated link in the App Group inbox. iOS offers no supported
  API for an extension to open its containing app, so open Muzik Belesh manually.
- Spotify playlist import is file-based (Exportify CSV, account-data JSON, ZIP). There is no
  Spotify account connection or playlist-URL import.
- `.mbelesh` library files contain portable metadata only — never audio, profile, listening
  history, settings or device paths. Songs missing on the receiving device must be matched
  or downloaded there.
- Exports need temporary space for one verified copy; insufficient space produces an error
  and leaves the original music intact.

## Verification limits

- Simulator measurements are not battery, thermal or device-performance measurements.
- Background audio, Lock Screen, AirPods/Bluetooth, radio transitions, real YouTube downloads
  and in-place upgrade on the owner's library can only be verified on a physical iPhone; see
  [PHASE_12_DEVICE_ACCEPTANCE.md](PHASE_12_DEVICE_ACCEPTANCE.md).
- Multi-hour soak tests and Instruments (Allocations/Leaks/Time Profiler) sessions were not
  run in Phase 12; see [PHASE_12_PERFORMANCE_REPORT.md](PHASE_12_PERFORMANCE_REPORT.md).


## Published v1.2.0 release-testing caveat

Muzik Belesh v1.2.0 build 200 was released following **10/10 developer-reported expedited physical-device checks PASS**, including preservation of the existing library. The owner approved publication with an explicit qualification: final comprehensive CI #307 and playlist migration verification were canceled, and preceding Phase 12 runs had failures. These checks must **not** be represented as a complete green automated regression suite. See [release gates](PHASE_12_RELEASE_CHECKLIST.md) and [physical acceptance](PHASE_12_DEVICE_ACCEPTANCE.md).
