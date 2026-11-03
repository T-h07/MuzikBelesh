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
[[ -f "$OUTPUT_DIR/Payload/OFFLINE.app/Assets.car" ]] || { echo "Compiled asset catalog missing" >&2; exit 1; }
[[ "$(plutil -type UILaunchScreen "$OUTPUT_DIR/Payload/OFFLINE.app/Info.plist")" == *dictionary* ]] || { echo "Modern launch-screen configuration missing" >&2; exit 1; }
[[ -d "$OUTPUT_DIR/Payload/OFFLINE.app/PlugIns/OFFLINEShareExtension.appex" ]] || { echo "Share extension missing" >&2; exit 1; }
python3 - "$OUTPUT_DIR/Payload/OFFLINE.app" <<'PY'
import os, pathlib, plistlib, sys
app = pathlib.Path(sys.argv[1])
main = plistlib.loads((app / "Info.plist").read_bytes())
extension = plistlib.loads((app / "PlugIns/OFFLINEShareExtension.appex/Info.plist").read_bytes())
assert main["CFBundleShortVersionString"] == extension["CFBundleShortVersionString"] == "0.1.0"
assert main["CFBundleVersion"] == extension["CFBundleVersion"]
if os.getenv("GITHUB_RUN_NUMBER"):
    assert main["CFBundleVersion"] == os.environ["GITHUB_RUN_NUMBER"]
print("Verified version/build/commit:", main["CFBundleShortVersionString"], main["CFBundleVersion"], main["MBBuildCommit"])
PY
(cd "$OUTPUT_DIR" && ditto -c -k --sequesterRsrc --keepParent Payload OFFLINE-unsigned.ipa)
unzip -t "$IPA_PATH" >/dev/null
unzip -l "$IPA_PATH" | grep -q 'Payload/OFFLINE.app/Info.plist'
unzip -l "$IPA_PATH" | grep -q 'Payload/OFFLINE.app/PlugIns/OFFLINEShareExtension.appex'
python3 - "$OUTPUT_DIR" <<'PY'
import hashlib, json, os, pathlib, plistlib, sys
output = pathlib.Path(sys.argv[1])
info = plistlib.loads((output / "Payload/OFFLINE.app/Info.plist").read_bytes())
manifest = {"version": info["CFBundleShortVersionString"], "build": info["CFBundleVersion"],
            "embeddedCommit": info["MBBuildCommit"], "sourceSHA": os.getenv("GITHUB_SHA", "local"),
            "bundleID": info["CFBundleIdentifier"], "sha256": hashlib.sha256((output / "OFFLINE-unsigned.ipa").read_bytes()).hexdigest()}
(output / "OFFLINE-build-manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
print(json.dumps(manifest, indent=2))
PY
echo "IPA: $IPA_PATH ($(du -h "$IPA_PATH" | awk '{print $1}'))"

