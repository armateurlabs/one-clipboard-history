# One Clipboard History

A native clipboard history for **macOS 27 on Apple Silicon**, built with Swift, AppKit and SwiftUI settings. Inspired by Quicksilver’s fast workflow: **⌥A → a number → paste**.

[Français](README.md) · [Downloads](https://github.com/armateurlabs/one-clipboard-history/releases) · [MIT license](LICENSE) · [Privacy](PRIVACY.md)

| Light appearance | Dark appearance |
| --- | --- |
| ![Compact clipboard history with synthetic text, code, image and file entries](docs/screenshots/history-light.png) | ![The same history using the native dark appearance](docs/screenshots/history-dark.png) |

Screenshots show the real application with synthetic examples, never personal clipboard contents.

## Use

1. Copy text, rich content, an image or files as usual.
2. Press **⌥A** to show or hide history.
3. Press **1–9** to paste that entry into the previously active app.

Arrow keys select an entry; **Return** or a double-click pastes it; **Escape** hides the window. Use the gear or **⌘,** for settings. The shortcut is configurable, including to avoid a conflict with Quicksilver.

- Newest copy first. Exact duplicates move to the top; different formatting stays distinct.
- Preserve the bytes of plain text, HTML, RTF, images, file references and available private representations. Thumbnails and summaries never replace original data.
- Defaults: **20 entries**, **256 MiB**, **12 pt**, compact rows, previews and sizes visible.
- Instant window display with no fade by default; optional native animations. Minimum width: 280 points.
- Remember a fixed position or open by the pointer in one of four quadrants; bottom right by default. Moving the window pins its location.
- Dark mode **on / off / automatic**, live French/English localization, adjustable 10–28 pt text.
- Persistence and silent launch at login are **off by default**.

![Native One Clipboard History settings](docs/screenshots/settings.png)

## Install

Download the ZIP from [Releases](https://github.com/armateurlabs/one-clipboard-history/releases), extract it and move **One Clipboard History.app** into Applications. Quit the previous version before replacing it.

**Version 0.7.0 status:** the personal build is locally signed (ad hoc). Developer ID signing and notarization require an Apple certificate; a local build is not a Gatekeeper-validated distribution. A Mac App Store variant is being prepared, without claiming Store availability. See [Store preparation](docs/APP_STORE.en.md) and [validation evidence](docs/VALIDATION.md).

The app starts in the menu bar. Closing its window keeps capture running; **Quit One Clipboard History** stops it. Settings → General offers optional silent launch at login and respects changes made in macOS.

## Permissions and privacy

- Allow clipboard access when macOS asks. Background startup defers permission prompts until an explicit interaction.
- Allow event posting in macOS privacy settings for automatic paste. If denied, an entry is still copied and can be pasted manually with **⌘V**.
- Finder files remain **references to originals**, not independent archives. Availability and access are checked before pasting.
- No account, advertisements, analytics or transmission of clipboard content. GitHub links open only when you choose them.

History stays in memory and disappears when the app exits unless persistence is enabled. Enabling persistence saves locally; disabling it deletes the saved history while retaining the current in-memory session. Storage is not encrypted by the app. Clearing history never deletes referenced original files.

For compatibility with early versions, direct distribution retains bundle identifier `com.arthur.mcm` and `~/Library/Application Support/mcm/History/`. The sandboxed variant has its own container and offers explicit import from a legacy History folder without changing the source.

Read the full [privacy policy](PRIVACY.md), also available from About.

## Build

Requirements: macOS 27, Apple Silicon and Xcode 27 with its command-line tools selected.

```sh
git clone https://github.com/armateurlabs/one-clipboard-history.git
cd one-clipboard-history
swift test
./scripts/build-app.sh
open 'build/One Clipboard History.app'
```

The build script generates original icon artwork and a locally signed app with translations, license and privacy policy. Set `OCH_SIGN_IDENTITY` to use a signing identity in your keychain; the legacy `MCM_SIGN_IDENTITY` variable is also accepted.

```sh
./scripts/validate-app.sh 'build/One Clipboard History.app'
./scripts/preview-app.sh
open 'build/One Clipboard History Preview.app'
```

The preview uses a private pasteboard, separate preferences and a simulated login service. It supports examining and photographing the interface without capturing real history.

The **OneClipboardHistory Store** Xcode target prepares sandboxing and archiving. See [APP_STORE.en.md](docs/APP_STORE.en.md) for commands, signing requirements and feasibility results.

## Fidelity, performance and limitations

Capture polls every **200 ms** on a dedicated queue. Intermediate copies replaced between polls may be missed. Deferred formats are materialized during capture; incomplete entries are identified and cannot be pasted. Budget eviction removes whole entries, never selected formats within an entry.

Restoration creates independent AppKit objects. Private Word and Excel formats may depend on their source application; byte-fidelity tests alone do not establish full Office paste fidelity. [VALIDATION.md](docs/VALIDATION.md) distinguishes verified results from remaining scenarios.

**Observed Excel limitation:** an older copy can paste calculated values instead of formulas even when all format bytes are preserved. Affected entries display a note and require confirmation before restoration. If the copy is still unchanged on the clipboard, the app keeps its owner and native paste behavior. Original formats are never removed as a workaround.

No CPU quota is imposed. The target is warm opening below 50 ms at the 95th percentile; measurements document exactly what was timed. The `--measure` mode logs durations only, never clipboard contents.

## Contribute

Open an [issue](https://github.com/armateurlabs/one-clipboard-history/issues) with your macOS version, app version and reproduction steps. Use synthetic examples; do not publish secrets or personal history. Run `swift test` and bundle validation before proposing changes.

Copyright © 2026 **Armateur Labs**. Released under the [MIT license](LICENSE).
