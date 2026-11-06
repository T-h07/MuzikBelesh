#!/bin/bash
# Run the actual Phase 10.0 sources and XCTest file without starting an iOS app.
# This is a contract gate, not a substitute for iOS build/integration/UI tests.
set -euo pipefail
cd "$(dirname "$0")/.."

HARNESS=$(mktemp -d "${TMPDIR:-/tmp}/muzik-foundation.XXXXXX")
trap 'rm -rf "$HARNESS"' EXIT
mkdir -p "$HARNESS/Sources/OFFLINE" "$HARNESS/Tests/OFFLINETests" build
cp OFFLINE/PlaylistMigration/*.swift "$HARNESS/Sources/OFFLINE/"
cp Tests/Unit/PlaylistMigration/PlaylistMigrationFoundationTests.swift "$HARNESS/Tests/OFFLINETests/"
cat > "$HARNESS/Package.swift" <<'SWIFT'
// swift-tools-version: 5.9
import PackageDescription
let package = Package(
    name: "PlaylistMigrationFoundationVerification",
    platforms: [.macOS(.v13)],
    targets: [
        .target(name: "OFFLINE"),
        .testTarget(name: "OFFLINETests", dependencies: ["OFFLINE"])
    ],
    swiftLanguageVersions: [.v5]
)
SWIFT

git rev-parse HEAD > build/FoundationContracts-source.txt
swift --version
swift test --package-path "$HARNESS" 2>&1 | tee build/FoundationContracts.log
