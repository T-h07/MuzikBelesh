# Build pipeline

The workflows use the GitHub-hosted `macos-15` runner. The verified run used Xcode 16.4, iOS SDK 18.5, Swift 6.1.2, and XcodeGen 2.46.0; the workflows fail if the XcodeGen version changes. YouTubeKit is pinned to `0.4.10`.

CI runs `xcodegen generate`, resolves packages, selects the first available iPhone simulator, and runs `xcodebuild ... test CODE_SIGNING_ALLOWED=NO`. A missing simulator fails the job. The IPA workflow builds with `-sdk iphoneos -destination 'generic/platform=iOS'`, `CODE_SIGNING_ALLOWED=NO`, `CODE_SIGNING_REQUIRED=NO`, and an empty identity.

`Scripts/package-ipa.sh` copies the built app into `Payload/OFFLINE.app`, validates `Info.plist`, the bundle identifier, executable, extension bundle, ZIP integrity, and expected IPA members. The artifact is uploaded as `OFFLINE-Phase0-unsigned-IPA`. It is not directly installable until SideStore signs it.

