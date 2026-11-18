# Development from Windows and macOS

Muzik Belesh is a native SwiftUI/AVFoundation iOS application. Its current stable release is **[v1.2.0](https://github.com/T-h07/MuzikBelesh/releases/tag/v1.2.0)**.

## Working from Windows

You can use **VS Code**, **Git**, **PowerShell** and GitHub to work on Swift source, YAML, Markdown and tests. Native iOS compilation requires **macOS/Xcode**; a Windows Swift compiler is not a replacement for the iOS SDK, Apple frameworks or XCTest simulator runtime.

Typical workflow:

```powershell
git clone https://github.com/T-h07/MuzikBelesh.git
cd MuzikBelesh
git switch develop
git pull --ff-only
git switch -c fix/describe-the-change

# Edit, review and commit your changes.
git status
git diff --check
git add .
git commit -m "fix: describe the correction"
git push -u origin fix/describe-the-change
```

Open a pull request into `develop`, and use the GitHub Actions checks to compile and test on macOS runners.

## Native macOS builds

The current workflows target **Xcode 26.2**, **XcodeGen 2.46.0** and **iOS 17+**.

```bash
xcodegen generate
xcodebuild -resolvePackageDependencies \
  -project OFFLINE.xcodeproj -scheme OFFLINE

xcodebuild -project OFFLINE.xcodeproj -scheme OFFLINE \
  -configuration Debug \
  -destination 'generic/platform=iOS Simulator' \
  CODE_SIGNING_ALLOWED=NO build
```

Use the `CI` workflow for deterministic tests and `Build unsigned IPA` for a sideloadable Release artifact. Review the `.xcresult` and individual workflow job conclusions; a successful IPA build does not imply all regression tests passed.

## Release distribution

The distributed v1.2.0 IPA was built as **build 200** from source `ab3763c` in [Actions #110](https://github.com/T-h07/MuzikBelesh/actions/runs/44371763077).

Use the [published v1.2.0 GitHub Release](https://github.com/T-h07/MuzikBelesh/releases/tag/v1.2.0) for device installation, rather than old development artifacts. Always preserve the existing SideStore signing identity and **install over the current app without uninstalling**, or the local music library may be lost.

For the complete process, see [CONTRIBUTING.md](../CONTRIBUTING.md), [build pipeline](BUILD_PIPELINE.md), and [SideStore installation](SIDELOADING.md).
