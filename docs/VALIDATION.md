# One Clipboard History 1.1.0 validation — 20 November 2026

Version **1.1.0 (13)** adds the CGEventTap hotkey backend and fixes the
system alert sound that the focused app played when the shortcut fired.
Previous application and release checks remain in
[VALIDATION-1.0.2.md](VALIDATION-1.0.2.md) and its linked reports.

## State and behavior

`GlobalHotkey` selects a backend at start-up. With the default constructor it
probes a CGEventTap registration; on success the `CGEventTapHotkey` backend
is used, otherwise the Carbon `EventHotKey` backend. The probe result is
cached for the process lifetime, and a custom backend passed to
`GlobalHotkey.init` is used as-is.

The CGEventTap backend taps session key-down, flags-changed and tap-disabled
events. A key-down that matches the registered combination is swallowed by
returning nil from the tap callback, including its auto-repeat, so the
focused app receives no character and no unhandled combination. The handler
fires once per physical press. Modifier state is tracked from flags-changed
events and compared against the Carbon modifier constants. When macOS
auto-disables the tap (timeout or user input) the callback re-enables it.

Secure-input detection uses the session dictionary check only. While secure
input is active the CGEventTap path reports the shortcut as temporarily
unavailable through `onSecureInputDetected` instead of delivering the press.

The register-replacement contract now switches the bound combination when a
tap is already active, matching the Carbon backend behavior.

## Checks

- `swift build` and `swift test` pass on macOS 27 / Apple Silicon, including
  the CGEventTap backend conformance, backend selection and fallback, the
  `onPressed` bridge, secure-input handling and the register-replacement
  contract.
- `python3 scripts/release_metadata.py --tag v1.1.0` accepts the version
  metadata; the Store configuration matches the canonical
  `Resources/Info.plist` values.
- The CI workflow builds and validates the direct app and the sandboxed
  Store archive on macOS 27 / Apple Silicon for the tagged commit, then
  publishes the release with its checksums.

## Limits

- The CGEventTap backend requires Accessibility permission for event
  tapping; without it the probe fails and the Carbon backend is used.
- Secure-input contexts block all global keyboard observation by design;
  the shortcut cannot fire there.
- The swallow behavior was verified by unit tests and a manual check on the
  developer machine; it has not been exercised across every application.
