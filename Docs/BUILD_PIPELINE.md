# Build pipeline

The workflows use the GitHub-hosted `macos-15` runner. The verified run used Xcode 16.4, iOS SDK 18.5, Swift 6.1.2, and XcodeGen 2.46.0; the workflows fail if the XcodeGen version changes. YouTubeKit is exactly pinned to `0.4.10` (revision `89854c93207ad0d2b3d78d6f1aea24595ca66552`).

CI runs `xcodegen generate`, resolves packages, selects the first available iPhone simulator, and runs `xcodebuild ... test CODE_SIGNING_ALLOWED=NO`, including the Phase 0 unit target and Phase 1 UI-test target. A missing simulator fails the job. The IPA workflow builds with `-sdk iphoneos -destination 'generic/platform=iOS'`, `CODE_SIGNING_ALLOWED=NO`, `CODE_SIGNING_REQUIRED=NO`, and an empty identity.

`Scripts/package-ipa.sh` copies the built app into `Payload/OFFLINE.app`, validates `Info.plist`, the bundle identifier, executable, extension bundle, ZIP integrity, and expected IPA members. The artifact is uploaded as `OFFLINE-unsigned-IPA` for use by Phase 0 and upcoming feature branches. It is not directly installable until SideStore signs it.


Phase 6 focused/complete dispatch uses `phase6-test-products` and verifies the full
source SHA before reusing build products. Optional `live_youtube` tests are isolated
from deterministic gates and preserve a separate xcresult. The complete dispatch
with prebuilt products builds one verified unsigned Release candidate after tests;
there is no need to also dispatch the standalone IPA workflow. Packaging checks
arm64 for both executables, app/extension bundle IDs and version/build consistency,
absence of embedded provisioning profiles or Apple signing identities, ZIP structure and full-SHA/hash manifest.

From Phase 8, the packager adds ad-hoc Mach-O metadata with the requested App Group to both executables and reads it back before archiving. SideStore still provisions and signs each bundle for installation.

The `runner_label` dispatch option supports `macos-15-intel` as a bounded capacity
fallback when the default `macos-15` pool does not allocate a runner. Reuse test
products only on the same selected runner architecture. Device builds still target
arm64 independently of the host CPU. Runner allocation is not a source/test result.

For a packaging-only correction after passing regressions, the standalone IPA
workflow accepts an optional positive `build_number` so its separate workflow
counter does not regress below an already installed CI candidate. The same value
is supplied to both targets and validated by the packager. Record both the tested
application-source commit and the final packaging commit; confirm application,
extension, tests and project configuration are identical before reusing evidence.

## Phase 9 candidate verification

The profile scope runs the repeatable clock SQL/publication and large-library
measurements. Baseline evidence and its limits are in PHASE_09_PERFORMANCE.md.
Focused adds reliability/resource policy/large-library regressions and retains
compiled products. Complete reuses only exact-SHA products, tests compact and
standard/large-screen layouts, then builds the Release device candidate. Never
run focused and complete concurrently. Inspect each failure before retrying.

Both targets read their marketing version from `MARKETING_VERSION` in `project.yml` (1.2.0 since Phase 12); CI supplies the build number.
Packaging checks audio background mode, identities, versions, deployment target,
arm64, icons and both ad-hoc App Group entitlement blobs, and rejects fixture
markers in Release executables. The manifest labels this a candidate with physical
acceptance pending; it is not stable publication. Test evidence, package manifest
and final SHA-256 are linked from the integration PR.

## Phase 12 — v1.2.0 packaging and publication

- **Single version source.** `project.yml` `MARKETING_VERSION` (`1.2.0`) feeds both
  Info.plists through `$(MARKETING_VERSION)`. `Scripts/package-ipa.sh` reads the same value
  instead of a hardcoded version, so a version bump is one line.
- **Build number.** v1.2.0 uses build **200**, above every build ever distributed
  (v1.0.0 = 195, v1.1.0 = 99, Phase 11 candidates = 100–108; verified from the published
  manifests and IPA artifacts). Dispatch `build-ipa.yml` with `build_number: 200`; the
  workflow run counter is not used for release candidates.
- **Packaging checks** (in addition to the earlier ones): app and extension bundle IDs,
  identical version and build in both bundles, `MinimumOSVersion` 17.0 in both, the
  `.mbelesh` exported type and document declaration, the ATS policy, and absence of every
  DEBUG-only UI-test hook string in both executables.
- **Manifest** `OFFLINE-build-manifest.json`: `version`, `build`, `sourceSHA`,
  `embeddedCommit`, `bundleID`, `extensionID`, `extensionVersion`, `extensionBuild`,
  `appGroup`, `minimumOS`, `configuration`, `packages` (resolved SwiftPM pins),
  `ipaSHA256` (computed from the final IPA bytes), `signing`, `verification`. A
  `OFFLINE-unsigned.ipa.sha256` file is uploaded alongside.
- **Supply chain.** First-party GitHub Actions are pinned to commit SHAs (checkout v4.4.0,
  upload-artifact v4.6.2, download-artifact v4.3.0). SwiftPM packages are exact pins
  (GRDB 7.11.1, YouTubeKit 0.4.10, ZIPFoundation 0.9.20).
- **CI simulators** disable keyboard prediction, autocorrection, slide-to-type and keyboard
  onboarding before tests: every 60 s XCUITest idle stall observed in CI #284–#298 occurred
  while typing.
- **Publication** uses `.github/workflows/publish-v1.2.0.yml`: manual dispatch only, on
  `main` only, refuses while the accepted build/source/SHA-256/run are `PENDING_ACCEPTANCE`,
  requires the SHA-256 to be typed as confirmation, never builds, verifies the downloaded
  artifact byte-for-byte and the source diff since acceptance, never moves an existing tag,
  and re-downloads the published IPA to verify its hash. The v1.1.0 publisher is unchanged.
