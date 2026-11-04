# One Clipboard History 0.8.0 validation — 4 November 2026

Version **0.8.0 (8)**, macOS 27 on Apple Silicon. This update adds three density
modes without changing clipboard data. Format, sandbox, import, permission and
Office checks from the previous version are recorded in
[VALIDATION-0.7.md](VALIDATION-0.7.md).

## Executed checks

`swift test`: **137 tests passed**, comprising **78 Core** and **59 AppKit/settings**.

Density checks cover:

- Compact by default for new installations; migration of the previous compact
  preference to Normal and the previous roomy layout to Large.
- Persistence of all three choices, safe fallback for invalid values, settings
  notifications, and preservation of font, preview and size preferences.
- A single Compact line with optional size, no preview or icon, and a rank block
  matching the text height at font sizes from 10 to 28 points.
- Metadata retained in tooltips and accessibility labels.
- Normal and Large retaining font sizes and image preview dimensions.
- Reused cells across multiple density changes, restored previews and metadata,
  retained selection and Return pasting the same entry.

In the real preview app, Compact → Normal → Large → Compact was exercised with
eight synthetic entries: images and icons were absent in Compact and restored
in the other modes. The selector exposes all three choices; the preview option
is disabled in Compact without erasing its saved value. The screenshot
`docs/screenshots/settings.png` shows the new real settings without personal
content. Existing history screenshots show the mode now named Normal.

Compact also avoids generating thumbnails in the background. The cache and
enrichment tasks are invalidated when thumbnail requirements change. Original
bytes and incomplete-capture or Excel-context alerts are unaffected by density.

## Build and delivery

The release and preview bundles are built and verified by
`scripts/validate-app.sh`. The [macOS 27 / Apple Silicon CI](https://github.com/armateurlabs/one-clipboard-history/actions/workflows/ci.yml)
runs tests, release compilation and sandboxed target archiving. Dated results
are available in its runs.

The direct bundle is installed at `/Applications/One Clipboard History.app`.
It retains `com.arthur.mcm`, preferences and the existing history location.
The previous copy is archived locally under `build/InstallBackups/`. The
prerelease ZIP is ad hoc signed; Apple signing and notarization prerequisites
remain unchanged.

## Limitations and remaining checks

Scenarios still requiring qualification in the [0.7.0 report](VALIDATION-0.7.md)
remain open: granted permissions and physical focus, a real global shortcut,
full VoiceOver navigation, complex Office content, login, sleep/wake, displays
and Spaces. Some Excel formulas still depend on their source context; the
warning remains in place.

The previous opening measurement applies to the mode now named Normal. The
optional benchmark explicitly selects it to retain comparability. This version
introduces no new timing result or CPU ceiling.
