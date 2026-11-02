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
[[ -x "$OUTPUT_DIR/Payload/OFFLINE.app/OFFLINE" ]] || { echo "Missing executable" >&2; exit 1; }
file "$OUTPUT_DIR/Payload/OFFLINE.app/OFFLINE"
[[ -f "$OUTPUT_DIR/Payload/OFFLINE.app/Assets.car" ]] || { echo "Compiled asset catalog missing" >&2; exit 1; }
plutil -type xml -extract UILaunchScreen xml1 -o - "$OUTPUT_DIR/Payload/OFFLINE.app/Info.plist" >/dev/null || { echo "Modern launch-screen configuration missing" >&2; exit 1; }
[[ -d "$OUTPUT_DIR/Payload/OFFLINE.app/PlugIns/OFFLINEShareExtension.appex" ]] || { echo "Share extension missing" >&2; exit 1; }
(cd "$OUTPUT_DIR" && ditto -c -k --sequesterRsrc --keepParent Payload OFFLINE-unsigned.ipa)
unzip -t "$IPA_PATH" >/dev/null
unzip -l "$IPA_PATH" | grep -q 'Payload/OFFLINE.app/Info.plist'
unzip -l "$IPA_PATH" | grep -q 'Payload/OFFLINE.app/PlugIns/OFFLINEShareExtension.appex'
echo "IPA: $IPA_PATH ($(du -h "$IPA_PATH" | awk '{print $1}'))"

