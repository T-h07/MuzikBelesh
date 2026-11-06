#!/usr/bin/env bash
set -euo pipefail
APP_SOURCE="${1:-build/Build/Products/Release-iphoneos/OFFLINE.app}"
OUTPUT_DIR="${2:-build/ipa}"
IPA_PATH="$OUTPUT_DIR/OFFLINE-unsigned.ipa"
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
assert main["CFBundleShortVersionString"] == extension["CFBundleShortVersionString"] == "0.1.0"
assert main["CFBundleVersion"] == extension["CFBundleVersion"]
assert extension["CFBundleIdentifier"] == "com.th07.muzikbelesh.share"
point = extension["NSExtension"]
assert point["NSExtensionPointIdentifier"] == "com.apple.share-services"
attributes = point["NSExtensionAttributes"]
assert attributes["NSExtensionActivationRule"] == {
    "NSExtensionActivationSupportsWebURLWithMaxCount": 1,
    "NSExtensionActivationSupportsWebPageWithMaxCount": 1,
    "NSExtensionActivationSupportsText": True}
assert (app / "PlugIns/OFFLINEShareExtension.appex" / (attributes["NSExtensionJavaScriptPreprocessingFile"] + ".js")).is_file()
assert main["CFBundleIcons"]["CFBundlePrimaryIcon"]["CFBundleIconFiles"]
expected_build = os.getenv("BUILD_NUMBER") or os.getenv("GITHUB_RUN_NUMBER")
if expected_build:
    assert main["CFBundleVersion"] == expected_build
print("Verified version/build/commit:", main["CFBundleShortVersionString"], main["CFBundleVersion"], main["MBBuildCommit"])
PY
(cd "$OUTPUT_DIR" && ditto -c -k --sequesterRsrc --keepParent Payload OFFLINE-unsigned.ipa)
unzip -t "$IPA_PATH" >/dev/null
unzip -l "$IPA_PATH" | grep -F 'Payload/OFFLINE.app/Info.plist' >/dev/null
unzip -l "$IPA_PATH" | grep -F 'Payload/OFFLINE.app/PlugIns/OFFLINEShareExtension.appex' >/dev/null
python3 - "$OUTPUT_DIR" <<'PY'
import hashlib, json, os, pathlib, plistlib, sys
output = pathlib.Path(sys.argv[1])
info = plistlib.loads((output / "Payload/OFFLINE.app/Info.plist").read_bytes())
manifest = {"version": info["CFBundleShortVersionString"], "build": info["CFBundleVersion"],
            "embeddedCommit": info["MBBuildCommit"], "sourceSHA": os.getenv("GITHUB_SHA", "local"),
            "bundleID": info["CFBundleIdentifier"], "extensionID": "com.th07.muzikbelesh.share",
            "requestedGroupBothExecutables": "group.com.th07.muzikbelesh.inbox",
            "signing": "ad-hoc entitlement metadata only; requires device signing", "sha256": hashlib.sha256((output / "OFFLINE-unsigned.ipa").read_bytes()).hexdigest()}
(output / "OFFLINE-build-manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
print(json.dumps(manifest, indent=2))
PY
echo "IPA: $IPA_PATH ($(du -h "$IPA_PATH" | awk '{print $1}'))"

