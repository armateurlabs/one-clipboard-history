# One Clipboard History 1.0.1 validation — 9 November 2026

Version **1.0.1 (11)** fixes shortcut registration recovery and interrupted
shortcut recording. The reported incident occurred on another Mac without
Quicksilver; its exact runtime cause has not been established from this Mac.
Previous application and release checks remain in
[VALIDATION-1.0.md](VALIDATION-1.0.md) and its linked reports.

## State and behavior

`AppSettings.shortcut` remains the persisted requested key combination.
`GlobalHotkey` owns native registrations; `AppController.configureHotkey` no
longer uses a separate successful-registration cache as proof of current state.
Keyboard code and modifiers identify a physical binding independently of its
display label.

Recording temporarily releases the current key. `RecorderButton.cancelRecording`
balances that suspension on Escape, acceptance, responder/key-window loss,
window close, detachment and SwiftUI dismantling. Failure to acquire a first
responder never suspends the existing shortcut. Ending recording, waking and
activating the app request a native refresh, including re-recording the same key.

Carbon registration is exclusive: another owner's conflicting registration must
produce an error instead of a silent nonexclusive success. A failed change keeps
or attempts to restore the previous registration; the UI distinguishes a retained
registration from failed restoration with none retained. A retained native handle
alone cannot prove physical key delivery. Failed unregister operations retain
their native handles, and incomplete rollback suppresses dispatch until cleanup.
The screenshot preview no longer registers a global shortcut.

## Executed checks

- **157 Swift tests passed:** 79 Core and 78 AppKit/settings tests.
- **35 Python release tests passed.**
- The shortcut suites cover 20 registration/lifecycle cases, including physical
  key equality, exclusive conflicts, real Carbon ownership/release on an unused
  modified F19 combination, forced refresh, transient/stale-reference recovery,
  failed rollback and cleanup, window close/detach/dismantle and keyboard cancel.
- Real NSWindow lifecycle checks confirm balanced recording callbacks. Native
  Carbon registration tests complement synthetic event routing; neither is a
  substitute for physical keyboard delivery in the affected session.
- Seven localization catalogs retain matching keys, format arguments and
  nonempty translations, including the accurate no-active-shortcut error.
- In the real preview UI, starting recording changed the label to the capture
  prompt; Escape restored the saved shortcut label. The preview was then quit.

The current settings and stored shortcut were inspected locally. A local
conflicting clipboard trigger was identified separately; this does not establish
the cause on the other Mac. Personal clipboard contents are not included in
commits, screenshots or release assets.

## Delivery and remaining checks

The [tag workflow](https://github.com/armateurlabs/one-clipboard-history/actions/workflows/ci.yml)
checks the source, app bundle, extracted ZIP and sandbox prototype before
publishing. Existing preferences and clipboard payload formats remain compatible.
Fully quit the old process before replacing the app; closing its history window
does not quit the clipboard manager.

The affected Mac still needs a physical shortcut check after installing 1.0.1,
including re-recording and closing settings while recording. No remote hardware
or sleep/wake test is claimed. The existing Office, focus, signing/notarization
and Store qualification limits remain unchanged. No CPU ceiling was introduced.
