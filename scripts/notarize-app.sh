#!/bin/bash
set -euo pipefail
OCH_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OCH_APP="${1:-$OCH_ROOT/build/One Clipboard History.app}"
if [[ "$#" -gt 1 ]]; then printf 'Usage: %s ["path.app"]\n' "$0" >&2; exit 2; fi
if [[ -z "${OCH_NOTARY_PROFILE:-}" ]]; then
    printf 'Set OCH_NOTARY_PROFILE to an existing notarytool keychain profile. Running this script uploads the signed app to Apple.\n' >&2
    exit 1
fi
"$OCH_ROOT/scripts/validate-app.sh" "$OCH_APP"
OCH_SIGNATURE="$(codesign -d --verbose=4 "$OCH_APP" 2>&1)"
if [[ "$OCH_SIGNATURE" != *'Authority=Developer ID Application:'* || "$OCH_SIGNATURE" != *'runtime'* ]]; then
    printf 'Notarization requires a Developer ID Application signature with hardened runtime. Run scripts/sign-app.sh first.\n' >&2
    exit 1
fi
mkdir -p "$OCH_ROOT/build"
OCH_STAGE="$(mktemp -d "$OCH_ROOT/build/.notary-stage.XXXXXX")"
trap 'rm -rf "$OCH_STAGE"' EXIT
OCH_ZIP="$OCH_STAGE/One Clipboard History.zip"
ditto -c -k --sequesterRsrc --keepParent "$OCH_APP" "$OCH_ZIP"
xcrun notarytool submit "$OCH_ZIP" --keychain-profile "$OCH_NOTARY_PROFILE" --wait --output-format json > "$OCH_STAGE/notarization.json"
python3 - "$OCH_STAGE/notarization.json" <<'PY'
import json
import sys
with open(sys.argv[1]) as stream:
    result = json.load(stream)
if result.get('status') != 'Accepted':
    raise SystemExit(f"Notarization was not accepted (submission {result.get('id', 'unknown')}, status {result.get('status', 'unknown')}). Retrieve its log with notarytool before distributing.")
PY
cp "$OCH_STAGE/notarization.json" "$OCH_ROOT/build/notarization.json"
xcrun stapler staple "$OCH_APP"
xcrun stapler validate "$OCH_APP"
spctl --assess --type execute "$OCH_APP"
ditto -c -k --sequesterRsrc --keepParent "$OCH_APP" "$OCH_ROOT/build/One Clipboard History.zip"
printf 'Notarized archive: %s\n' "$OCH_ROOT/build/One Clipboard History.zip"
