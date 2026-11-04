#!/bin/bash
set -euo pipefail
OCH_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OCH_APP="${1:-$OCH_ROOT/build/One Clipboard History.app}"
if [[ "$#" -gt 1 ]]; then printf 'Usage: %s ["path.app"]\n' "$0" >&2; exit 2; fi
OCH_IDENTITY="${OCH_SIGN_IDENTITY:-${MCM_SIGN_IDENTITY:-}}"
if [[ -z "$OCH_IDENTITY" || "$OCH_IDENTITY" == '-' ]]; then
    printf 'Set OCH_SIGN_IDENTITY to a Developer ID Application signing identity.\n' >&2
    exit 1
fi
"$OCH_ROOT/scripts/validate-app.sh" "$OCH_APP"
codesign --force --options runtime --timestamp --sign "$OCH_IDENTITY" "$OCH_APP"
"$OCH_ROOT/scripts/validate-app.sh" "$OCH_APP"
printf 'Signed %s\n' "$OCH_APP"
