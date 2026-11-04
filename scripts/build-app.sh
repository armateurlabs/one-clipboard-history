#!/bin/bash
set -euo pipefail

OCH_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$OCH_ROOT"
OCH_NAME="One Clipboard History"
OCH_BUNDLE_ID="com.arthur.mcm"
OCH_PREVIEW=false
if [[ "${1:-}" == "--preview" && "$#" == 1 ]]; then
    OCH_NAME="One Clipboard History Preview"
    OCH_BUNDLE_ID="com.arthur.mcm.preview"
    OCH_PREVIEW=true
elif [[ "$#" != 0 ]]; then
    printf 'Usage: %s [--preview]\n' "$0" >&2
    exit 2
fi

swift build -c release --product OneClipboardHistory
OCH_BIN="$(swift build -c release --show-bin-path)"
OCH_RESOURCES="$OCH_BIN/OneClipboardHistory_OneClipboardHistoryCore.bundle"
[[ -d "$OCH_RESOURCES" ]] || { printf 'Missing Swift package resources: %s\n' "$OCH_RESOURCES" >&2; exit 1; }
mkdir -p "$OCH_ROOT/build"
OCH_STAGE="$(mktemp -d "$OCH_ROOT/build/.app-stage.XXXXXX")"
trap 'rm -rf "$OCH_STAGE"' EXIT
OCH_APP="$OCH_STAGE/$OCH_NAME.app"
mkdir -p "$OCH_APP/Contents/MacOS" "$OCH_APP/Contents/Resources"
cp "$OCH_BIN/OneClipboardHistory" "$OCH_APP/Contents/MacOS/OneClipboardHistory"
cp Resources/Info.plist "$OCH_APP/Contents/Info.plist"
ditto "$OCH_RESOURCES" "$OCH_APP/Contents/Resources/$(basename "$OCH_RESOURCES")"
ditto Resources/en.lproj "$OCH_APP/Contents/Resources/en.lproj"
ditto Resources/fr.lproj "$OCH_APP/Contents/Resources/fr.lproj"
cp LICENSE "$OCH_APP/Contents/Resources/LICENSE.txt"
cp PRIVACY.md "$OCH_APP/Contents/Resources/PRIVACY.txt"
cp AppStore/PrivacyInfo.xcprivacy "$OCH_APP/Contents/Resources/PrivacyInfo.xcprivacy"
if [[ "$OCH_PREVIEW" == true ]]; then
    /usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $OCH_BUNDLE_ID" "$OCH_APP/Contents/Info.plist"
    /usr/libexec/PlistBuddy -c "Set :CFBundleName $OCH_NAME" "$OCH_APP/Contents/Info.plist"
    /usr/libexec/PlistBuddy -c "Set :CFBundleDisplayName $OCH_NAME" "$OCH_APP/Contents/Info.plist"
    /usr/libexec/PlistBuddy -c 'Add :OCHPreviewMode bool true' "$OCH_APP/Contents/Info.plist"
fi
swift scripts/make-icon.swift "$OCH_STAGE"
iconutil -c icns "$OCH_STAGE/AppIcon.iconset" -o "$OCH_APP/Contents/Resources/AppIcon.icns"
cp "$OCH_STAGE/AppIcon.iconset/icon_512x512@2x.png" "$OCH_ROOT/build/AppIcon.png"

# Keep the production identifier stable so existing settings and permissions survive.
OCH_IDENTITY="${OCH_SIGN_IDENTITY:-${MCM_SIGN_IDENTITY:--}}"
if [[ "$OCH_IDENTITY" == "-" ]]; then
    codesign --force --sign - --identifier "$OCH_BUNDLE_ID" "$OCH_APP"
else
    codesign --force --options runtime --timestamp --sign "$OCH_IDENTITY" "$OCH_APP"
fi
"$OCH_ROOT/scripts/validate-app.sh" "$OCH_APP"
OCH_DESTINATION="$OCH_ROOT/build/$OCH_NAME.app"
if [[ -e "$OCH_DESTINATION" ]]; then rm -rf "$OCH_DESTINATION"; fi
mv "$OCH_APP" "$OCH_DESTINATION"
touch "$OCH_DESTINATION"
printf 'Built %s\n' "$OCH_DESTINATION"
