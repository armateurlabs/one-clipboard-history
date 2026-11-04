#!/bin/bash
set -euo pipefail

MCM_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$MCM_ROOT"
swift build -c release
MCM_BIN="$(swift build -c release --show-bin-path)"
MCM_APP="$MCM_ROOT/build/mcm.app"
mkdir -p "$MCM_APP/Contents/MacOS" "$MCM_APP/Contents/Resources"
cp "$MCM_BIN/mcm" "$MCM_APP/Contents/MacOS/mcm"
cp Resources/Info.plist "$MCM_APP/Contents/Info.plist"
cp -R "$MCM_BIN/mcm_MCMCore.bundle" "$MCM_APP/Contents/Resources/"
cp -R Resources/en.lproj Resources/fr.lproj "$MCM_APP/Contents/Resources/"
swift scripts/make-icon.swift "$MCM_ROOT/build"
iconutil -c icns "$MCM_ROOT/build/AppIcon.iconset" -o "$MCM_APP/Contents/Resources/AppIcon.icns"
MCM_IDENTITY="${MCM_SIGN_IDENTITY:--}"
if [[ "$MCM_IDENTITY" == "-" ]]; then
    codesign --force --sign - --identifier com.arthur.mcm "$MCM_APP"
else
    codesign --force --options runtime --timestamp --sign "$MCM_IDENTITY" "$MCM_APP"
fi
codesign --verify --strict "$MCM_APP"
printf 'Built %s\n' "$MCM_APP"
