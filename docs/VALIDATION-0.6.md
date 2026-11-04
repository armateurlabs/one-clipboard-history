# mcm validation — November 4, 2026

Validation status of the personal version 0.6.0, intended for macOS 27 on Apple Silicon. The release build and local signature verification succeeded. The full suite passes: **93 tests**, including 43 covering data, persistence, localization and capture permissions, and 50 covering AppKit, settings, launch behavior, placement, appearance and Carbon shortcut routing. This document distinguishes those checks from interactions that still require validation in real applications.

## Automated checks

Verification command:

```sh
swift test
```

The implemented and executed checks cover:

- Initial history of 20 entries and a 256 MiB budget; newest-first ordering, promotion, deletion, strict deduplication and whole-entry eviction.
- Preservation of bytes, multiple representations and item order, including simulated private formats, source metadata and Python with Unicode, tabs and CRLF line endings.
- Materialization of deferred representations before clipboard ownership changes, including a provider in another process with reads on the worker queue.
- Conversion of an Objective-C provider exception into a recoverable failure; an incomplete capture or missing file does not replace the existing clipboard.
- Bounded thumbnails without changing original image data; distinction between referenced file sizes and the sizes of their representations.
- Persistence enabled after an in-memory capture, byte restoration after reopening, backup deletion when persistence is disabled, and no content writes while persistence is disabled.
- Detection of missing or damaged blobs, orphaned file cleanup and preservation of usable in-memory history if SQLite is damaged.
- Palette keyboard handling: digits/AZERTY, selection after rank changes, prevention of pasting a stale selection and opening settings with ⌘,.
- Carbon event routing to mcm, rejection of foreign signatures and removal of the handler during shutdown.
- Initial preferences, window and settings restoration, normalization of numeric limits before calculation and fallback after an invalid saved shortcut.
- Font sizes from 10 to 28 points, consistent text size and row height, normalization of nonfinite values and preferences retained after restarting.
- Initial font size of 12 points and minimum width of 280 points; previously chosen font sizes are retained.
- Compact view initially enabled, with its preference retained; height measured using native controls without reducing fonts or preview dimensions. Tests of fully laid-out cells at 10, 12, 24 and 28 points, with PNG, vertical insets, selection and keyboard paste preserved when switching layouts.
- Four quadrants around the pointer, bottom right by default, a 12-point gap, screen boundaries, screens with negative origins and retention of the quadrant when switching to a fixed position.
- Animations disabled by default, enabled and then disabled, without residual transparency.
- Persistent dark mode on/off/automatic; the palette and actual SwiftUI settings immediately inherit the appearance. Returning to automatic removes the forced appearance and follows macOS. Tests restore the process appearance without changing the system.
- Launch at login: simulated services for enabling, disabling, idempotence, approval, errors, state changed in macOS and preview without real registration. Open and reopen events marked as login/service remain silent; manual launch remains interactive.
- Background capture only with already authorized access, permission requests deferred until history is opened, without reading the general clipboard in tests.
- Complete French/English catalogs, formatting arguments, system language and live language switching without transforming original data.

These fixtures do not prove that Word or Excel will interpret all their private representations exactly as they do during a direct paste.

## Visual verification already performed

The demo application was opened through the macOS UI driver. The palette, numbers, promotion of an entry after numeric selection and access to settings were inspected; the initial value of 20 entries and disabled persistence were verified. The native menu allows the application to quit cleanly. This check uses a private clipboard; no read or paste permission was granted to mcm on the user's behalf.

For version 0.2.0, live switching from the system language to French and back was verified, including menus, the title, entry descriptions and byte sizes. The font slider was tested at 24 and then 14 points; rows adapt without clipping text vertically. The animation setting was enabled and then disabled. Demo preferences were restored to 14 points, system language and disabled animations.

For version 0.3.0, the square selector was visually verified: four buttons around the cursor, bottom right initially selected, buttons disabled in fixed-position mode and then enabled in pointer mode. Choosing top left and returning to bottom right were checked. The preview font was set to 12 points; fixed-position mode and the bottom-right quadrant were restored after verification.

For version 0.4.0, compact rows were visually compared with the roomier presentation: identical text and icons, with reduced vertical margins. The Compact View setting was verified as initially enabled, then disabled and enabled again live; the preview was left in compact mode at the end of the check.

For version 0.5.0, dark mode was visually enabled in the preview: the background, controls, titles, selection and history numbers remained readable. Switching to light mode was verified in settings, then automatic mode was restored. No global macOS appearance setting was changed.

For version 0.6.0, the new General section and its silent-launch option were verified in the preview: initially disabled, then enabled and disabled. This preview uses an in-memory simulated service: no real login item was registered or removed during the tests.

Two deferred-provider fixtures within the test process produce an AppKit thread-affinity warning. The deferred provider tested in a separate process fulfills its promise on its own main thread without this warning; byte retrieval and exception handling are verified.

## Remaining manual validation

| Scenario | Expected result |
| --- | --- |
| Enable automatic launch from `/Applications/mcm.app`, then start a new login session | mcm stays in the menu bar without a window, activation or permission request; the shortcut opens history. This real scenario requires logging out and was not executed automatically. |
| Disable or remove it in System Settings | mcm does not automatically register the option again; settings reflect the current state. |
| Global shortcut on a physical keyboard, including a conflict with Quicksilver | ⌥A opens and hides mcm; a conflict is reported and another shortcut can be recorded. |
| Automatic paste with permissions granted | A digit or Return pastes once into the previous application; the entry moves to the top. |
| Permissions denied or revoked | An indication is displayed; manual paste remains available for a copied entry. |
| Brave, TextEdit, Terminal and Finder | The correct recipient receives the content and formats it supports. |
| Word: styles, lists, tables and images | Compare direct paste with paste through mcm, then repeat after closing the source. |
| Excel: ranges, formulas, number formats, borders and merged cells | Compare with direct paste in Excel and verify the private formats actually exposed. |
| Persistence with real Word/Excel content and images | Obtain the same results after restarting mcm; distinguish a successful byte test from Office's functional fidelity. |
| Multiple displays, Spaces, full screen and display disconnection | The palette remains accessible; moving it pins its location and pointer mode can be reenabled. |
| Sleep and wake | Capture resumes and the shortcut continues to work. |
| Quit immediately after a copy or disabling persistence | Pending operations finish and no deleted backup is recreated. |
| Multiple files, moved/deleted files and unavailable volumes | Usable references can be pasted; unavailable files are reported. |
| Rapid copies and large images | The interface responds during processing; no copy is presented as complete after losing a format. |

## Measurements to collect

Launch the bundle with `--measure`, open an already loaded palette several times and record AppKit opening-path durations. Add observations of actual display and paste behavior, CPU and memory, using text, large images and an increased history size in settings.

The target of a warm-opening 95th percentile below 50 ms **has not yet been validated**. No CPU ceiling is an acceptance criterion. The 200 ms polling interval has a known limit: intermediate copies replaced between two reads may escape capture.
