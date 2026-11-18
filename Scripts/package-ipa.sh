#!/usr/bin/env bash
set -euo pipefail
APP_SOURCE="${1:-build/Build/Products/Release-iphoneos/OFFLINE.app}"
OUTPUT_DIR="${2:-build/ipa}"
IPA_PATH="$OUTPUT_DIR/OFFLINE-unsigned.ipa"
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# Single authoritative version source (project.yml); both Info.plists reference it.
EXPECTED_VERSION="$(awk -F"'" '/^ *MARKETING_VERSION: /{print $2; exit}' "$REPO_ROOT/project.yml")"
[[ "$EXPECTED_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "Cannot read MARKETING_VERSION from project.yml" >&2; exit 1; }
export EXPECTED_VERSION
[[ -d "$APP_SOURCE" ]] || { echo "Missing app bundle: $APP_SOURCE" >&2; exit 1; }
rm -rf "$OUTPUT_DIR/Payload"
mkdir -p "$OUTPUT_DIR/Payload"
ditto "$APP_SOURCE" "$OUTPUT_DIR/Payload/OFFLINE.app"
plutil -p "$OUTPUT_DIR/Payload/OFFLINE.app/Info.plist" >/dev/null
BUNDLE_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$OUTPUT_DIR/Payload/OFFLINE.app/Info.plist")"
[[ "$BUNDLE_ID" == "com.th07.muzikbelesh" ]] || { echo "Unexpected bundle identifier: $BUNDLE_ID" >&2; exit 1; }
if [[ -n "${GITHUB_SHA:-}" ]]; then
  BUILD_COMMIT="$(/usr/libexec/PlistBuddy -c 'Print :MBBuildCommit' "$OUTPUT_DIR/Payload/OFFLINE.app/Info.plist")"
  [[ "$BUILD_COMMIT" == "${GITHUB_SHA:0:7}" ]] || { echo "Build provenance mismatch: $BUILD_COMMIT" >&2; exit 1; }
fi
[[ -x "$OUTPUT_DIR/Payload/OFFLINE.app/OFFLINE" ]] || { echo "Missing executable" >&2; exit 1; }
file "$OUTPUT_DIR/Payload/OFFLINE.app/OFFLINE"
lipo "$OUTPUT_DIR/Payload/OFFLINE.app/OFFLINE" -verify_arch arm64
[[ -f "$OUTPUT_DIR/Payload/OFFLINE.app/Assets.car" ]] || { echo "Compiled asset catalog missing" >&2; exit 1; }
[[ "$(plutil -type UILaunchScreen "$OUTPUT_DIR/Payload/OFFLINE.app/Info.plist")" == *dictionary* ]] || { echo "Modern launch-screen configuration missing" >&2; exit 1; }
[[ -d "$OUTPUT_DIR/Payload/OFFLINE.app/PlugIns/OFFLINEShareExtension.appex" ]] || { echo "Share extension missing" >&2; exit 1; }
lipo "$OUTPUT_DIR/Payload/OFFLINE.app/PlugIns/OFFLINEShareExtension.appex/OFFLINEShareExtension" -verify_arch arm64
for BUNDLE in "$OUTPUT_DIR/Payload/OFFLINE.app" "$OUTPUT_DIR/Payload/OFFLINE.app/PlugIns/OFFLINEShareExtension.appex"; do
  [[ ! -e "$BUNDLE/embedded.mobileprovision" && ! -d "$BUNDLE/_CodeSignature" ]] || { echo "Unexpected signing material" >&2; exit 1; }
done
# SideStore discovers requested groups from each Mach-O. Attach only ad-hoc
# metadata, to standalone binaries so neither bundle acquires a resource seal.
entitlements="$(cd "$(dirname "$0")/.." && pwd)/Sharing/ShareGroups.entitlements"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
app="$OUTPUT_DIR/Payload/OFFLINE.app"
for executable in "$app/OFFLINE" "$app/PlugIns/OFFLINEShareExtension.appex/OFFLINEShareExtension"; do
  cp "$executable" "$work/binary"
  identifier="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$(dirname "$executable")/Info.plist")"
  codesign --force --sign - --identifier "$identifier" --timestamp=none --entitlements "$entitlements" "$work/binary"
  codesign --verify "$work/binary"
  codesign -d --entitlements - --xml "$work/binary" > "$work/actual.plist"
  python3 - "$entitlements" "$work/actual.plist" <<'CHECK'
import plistlib, sys
with open(sys.argv[1], "rb") as expected, open(sys.argv[2], "rb") as actual:
    assert plistlib.load(actual) == plistlib.load(expected) == {
        "com.apple.security.application-groups": ["group.com.th07.muzikbelesh.inbox"]}
CHECK
  cp "$work/binary" "$executable"
done
python3 - "$OUTPUT_DIR/Payload/OFFLINE.app" <<'PY'
import os, pathlib, plistlib, sys
app = pathlib.Path(sys.argv[1])
main = plistlib.loads((app / "Info.plist").read_bytes())
extension = plistlib.loads((app / "PlugIns/OFFLINEShareExtension.appex/Info.plist").read_bytes())
expected_version = os.environ["EXPECTED_VERSION"]
assert main["CFBundleShortVersionString"] == extension["CFBundleShortVersionString"] == expected_version,     (main["CFBundleShortVersionString"], extension["CFBundleShortVersionString"], expected_version)
assert main["CFBundleVersion"] == extension["CFBundleVersion"]
assert main["CFBundleVersion"].isdigit() and int(main["CFBundleVersion"]) > 0
assert main["CFBundleIdentifier"] == "com.th07.muzikbelesh"
assert extension["CFBundleIdentifier"] == "com.th07.muzikbelesh.share"
assert main["MinimumOSVersion"] == extension["MinimumOSVersion"] == "17.0", (main["MinimumOSVersion"], extension["MinimumOSVersion"])
# Portable library documents (.mbelesh) stay declared and owned by the app.
assert [t["UTTypeIdentifier"] for t in main["UTExportedTypeDeclarations"]] == ["com.th07.muzikbelesh.library"]
assert main["UTExportedTypeDeclarations"][0]["UTTypeTagSpecification"]["public.filename-extension"] == ["mbelesh"]
assert any("com.th07.muzikbelesh.library" in t.get("LSItemContentTypes", []) for t in main["CFBundleDocumentTypes"])
assert main["NSAppTransportSecurity"] == {"NSAllowsArbitraryLoads": False, "NSAllowsLocalNetworking": True}
point = extension["NSExtension"]
assert point["NSExtensionPointIdentifier"] == "com.apple.share-services"
attributes = point["NSExtensionAttributes"]
assert attributes["NSExtensionActivationRule"] == {
    "NSExtensionActivationSupportsWebURLWithMaxCount": 1,
    "NSExtensionActivationSupportsWebPageWithMaxCount": 1,
    "NSExtensionActivationSupportsText": True}
assert (app / "PlugIns/OFFLINEShareExtension.appex" / (attributes["NSExtensionJavaScriptPreprocessingFile"] + ".js")).is_file()
assert main["CFBundleIcons"]["CFBundlePrimaryIcon"]["CFBundleIconFiles"]
assert "audio" in main["UIBackgroundModes"]
for executable in [app / "OFFLINE", app / "PlugIns/OFFLINEShareExtension.appex/OFFLINEShareExtension"]:
    binary = executable.read_bytes()
    for fixture in [b"NEKO -", b"Queued fixture", b"--youtube-fixtures", b"MockMusicCatalog",
                    b"--ui-testing", b"--reset-ui-library", b"--listening-fixture", b"--review-queue-fixture",
                    b"--playlist-import-fixture", b"MuzikBeleshUITests"]:
        assert fixture not in binary, f"DEBUG-only test hook {fixture!r} present in device binary"
expected_build = os.getenv("BUILD_NUMBER") or os.getenv("GITHUB_RUN_NUMBER")
if expected_build:
    assert main["CFBundleVersion"] == expected_build
print("Verified version/build/commit:", main["CFBundleShortVersionString"], main["CFBundleVersion"], main["MBBuildCommit"])
PY
(cd "$OUTPUT_DIR" && ditto -c -k --sequesterRsrc --keepParent Payload OFFLINE-unsigned.ipa)
unzip -t "$IPA_PATH" >/dev/null
unzip -l "$IPA_PATH" | grep -F 'Payload/OFFLINE.app/Info.plist' >/dev/null
unzip -l "$IPA_PATH" | grep -F 'Payload/OFFLINE.app/PlugIns/OFFLINEShareExtension.appex' >/dev/null
RESOLVED="$(find "$REPO_ROOT/OFFLINE.xcodeproj" -name Package.resolved -print -quit 2>/dev/null || true)"
python3 - "$OUTPUT_DIR" "${RESOLVED:-}" <<'PY'
import hashlib, json, os, pathlib, plistlib, sys
output = pathlib.Path(sys.argv[1])
info = plistlib.loads((output / "Payload/OFFLINE.app/Info.plist").read_bytes())
extension = plistlib.loads((output / "Payload/OFFLINE.app/PlugIns/OFFLINEShareExtension.appex/Info.plist").read_bytes())
packages = {}
if len(sys.argv) > 2 and sys.argv[2]:
    for pin in json.loads(pathlib.Path(sys.argv[2]).read_text()).get("pins", []):
        packages[pin["identity"]] = {"version": pin["state"].get("version"), "revision": pin["state"].get("revision")}
# Phase 12 manifest schema. Every value is read from the packaged bundle or computed from
# the final IPA bytes; nothing is assumed.
manifest = {"version": info["CFBundleShortVersionString"], "build": info["CFBundleVersion"],
            "sourceSHA": os.getenv("GITHUB_SHA", "local"), "embeddedCommit": info["MBBuildCommit"],
            "bundleID": info["CFBundleIdentifier"], "extensionID": extension["CFBundleIdentifier"],
            "extensionVersion": extension["CFBundleShortVersionString"], "extensionBuild": extension["CFBundleVersion"],
            "appGroup": "group.com.th07.muzikbelesh.inbox", "minimumOS": info["MinimumOSVersion"],
            "configuration": "Release", "packages": packages,
            "ipaSHA256": hashlib.sha256((output / "OFFLINE-unsigned.ipa").read_bytes()).hexdigest(),
            "signing": "unsigned; requires compatible SideStore signing",
            "verification": os.getenv("CANDIDATE_LABEL") or f"v{info['CFBundleShortVersionString']} release candidate; physical acceptance pending"}
(output / "OFFLINE-build-manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
(output / "OFFLINE-unsigned.ipa.sha256").write_text(f"{manifest['ipaSHA256']}  OFFLINE-unsigned.ipa\n")
print(json.dumps(manifest, indent=2))
PY
echo "IPA: $IPA_PATH ($(du -h "$IPA_PATH" | awk '{print $1}'))"

