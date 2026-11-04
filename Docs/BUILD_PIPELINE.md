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
absence of embedded signing material, ZIP structure and full-SHA/hash manifest.

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
