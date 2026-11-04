#!/bin/bash
set -euo pipefail
OCH_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
if [[ "$#" != 0 ]]; then printf 'Usage: %s\n' "$0" >&2; exit 2; fi
if [[ -z "${OCH_DEVELOPMENT_TEAM:-}" ]]; then
    printf 'Set OCH_DEVELOPMENT_TEAM. Export requires an App Store distribution certificate and provisioning profile.\n' >&2
    exit 1
fi
OCH_ARCHIVE="$OCH_ROOT/build/One Clipboard History Store.xcarchive"
"$OCH_ROOT/scripts/validate-app.sh" "$OCH_ARCHIVE/Products/Applications/One Clipboard History.app" --store
OCH_OPTIONS="$(mktemp -t och-export-options)"
trap 'rm -f "$OCH_OPTIONS"' EXIT
cp "$OCH_ROOT/AppStore/ExportOptions.plist" "$OCH_OPTIONS"
/usr/libexec/PlistBuddy -c "Add :teamID string $OCH_DEVELOPMENT_TEAM" "$OCH_OPTIONS"
xcodebuild -exportArchive -archivePath "$OCH_ARCHIVE" \
    -exportOptionsPlist "$OCH_OPTIONS" -exportPath "$OCH_ROOT/build/AppStoreExport"
printf 'Exported locally to %s (nothing uploaded)\n' "$OCH_ROOT/build/AppStoreExport"
