#!/bin/bash
set -euo pipefail
OCH_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
exec "$OCH_ROOT/scripts/build-app.sh" --preview
