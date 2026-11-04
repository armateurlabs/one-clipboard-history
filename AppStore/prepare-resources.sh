#!/bin/bash
set -euo pipefail
OCH_DESTINATION="$TARGET_BUILD_DIR/$UNLOCALIZED_RESOURCES_FOLDER_PATH"
mkdir -p "$OCH_DESTINATION" "$DERIVED_FILE_DIR/OneClipboardHistoryIcon"
swift "$SRCROOT/scripts/make-icon.swift" "$DERIVED_FILE_DIR/OneClipboardHistoryIcon"
iconutil -c icns "$DERIVED_FILE_DIR/OneClipboardHistoryIcon/AppIcon.iconset" -o "$OCH_DESTINATION/AppIcon.icns"
cp "$SRCROOT/LICENSE" "$OCH_DESTINATION/LICENSE.txt"
cp "$SRCROOT/PRIVACY.md" "$OCH_DESTINATION/PRIVACY.txt"
