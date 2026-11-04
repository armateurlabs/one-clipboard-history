#!/bin/bash
set -euo pipefail
OCH_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OCH_SIGNING=()
if [[ "${1:-}" == '--unsigned' && "$#" == 1 ]]; then
    # Ad hoc signing keeps the real sandbox entitlements for local feasibility checks.
    # This archive is not eligible for App Store upload.
    OCH_SIGNING=(CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM= PROVISIONING_PROFILE_SPECIFIER=)
elif [[ "$#" != 0 ]]; then
    printf 'Usage: %s [--unsigned]\n' "$0" >&2
    exit 2
elif [[ -z "${OCH_DEVELOPMENT_TEAM:-}" ]]; then
    printf 'Set OCH_DEVELOPMENT_TEAM for a signed archive, or use --unsigned for a local sandbox prototype.\n' >&2
    exit 1
else
    OCH_SIGNING=("DEVELOPMENT_TEAM=$OCH_DEVELOPMENT_TEAM")
fi
OCH_ARCHIVE="$OCH_ROOT/build/One Clipboard History Store.xcarchive"
xcodebuild -project "$OCH_ROOT/OneClipboardHistory.xcodeproj" \
    -scheme 'OneClipboardHistory Store' -configuration Release \
    -destination 'generic/platform=macOS' \
    -derivedDataPath "$OCH_ROOT/build/StoreDerivedData" \
    -archivePath "$OCH_ARCHIVE" \
    "${OCH_SIGNING[@]}" archive
"$OCH_ROOT/scripts/validate-app.sh" "$OCH_ARCHIVE/Products/Applications/One Clipboard History.app" --store
printf 'Archived %s\n' "$OCH_ARCHIVE"
