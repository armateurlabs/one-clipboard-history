# One Clipboard History validation — November 4, 2026

Version **0.7.0 (7)**, macOS 27, Apple Silicon, Xcode 27.1.
This report distinguishes completed checks from validations that still require
permissions, hardware or distribution signing. The historical validation of
mcm 0.6.0 is preserved in [VALIDATION-0.6.md](VALIDATION-0.6.md).

## Automated tests

`swift test`: **134 tests passed**, including **78 Core** and **56 AppKit/settings**.
Opening measurement is an additional test, disabled by default.

The suite covers bytes and multiple representations, item and format ordering,
strict deduplication, deferred formats, Python with Unicode/tabs/CRLF,
persistence and corruption, whole-entry limits, settings, palette keyboard
handling, placement, appearances, translations and silent-launch events.

The [GitHub macOS 27 / Apple Silicon CI](https://github.com/armateurlabs/one-clipboard-history/actions/runs/41824814530)
also passed: tests, release build, bundle validation, sandboxed Store archive
and ZIP artifact retention. The executed code is `c38f1fe`; the following
publication fix only reencodes the screenshots as PNG and completes this report.

This version's additions specifically verify:

- Compatibility with old backups without bookmarks, with access metadata
  separate from original data and from the content used for deduplication.
- Access denial, missing/moved files, invalid or stale bookmarks, renewal and
  balanced release of security scopes.
- Read-only import, merging without overwriting, early rejection of limits,
  reading one blob at a time, duplicates, corruption, path traversal, rollback
  and cleanup after a transaction.
- Preservation of clipboard ownership when order and bytes are still identical,
  including data changed without a new change counter.
- Rejection of context-dependent Excel restoration before any clipboard change;
  explicit consent allows all formats to be restored without removing the OLE
  marker or changing the data.
- License, privacy and About-panel links; an isolated preview with synthetic
  text, Python, rich content, an original image and files.

## Real application checks

| Check | Observed result |
| --- | --- |
| Direct release build and preview | Passed; local signature, version, resources, translations, icon, license and privacy policy verified. |
| Xcode Store archive | Native archive produced with sandboxing, selected-file read access and app-scoped bookmarks; no Accessibility entitlement or temporary exception. Ad hoc feasibility signing. |
| Native sandbox import | Explicit test-folder selection in NSOpenPanel, followed by import of three old-schema entries without bookmarks: Unicode text, Python and an Excel copy. The four source files remain identical according to SHA-256. |
| Excel protection in the sandbox | Imported entry marked, native warning shown on double-click; Cancel closes the warning and keeps history visible without starting restoration. |
| About and license | Name, version/build, Armateur Labs and GitHub/MIT/privacy links inspected in the native panel; license readable in a local, noneditable window. |
| French, light and dark | Verified in the preview application; three real screenshots in `docs/screenshots/`, using synthetic data only. |
| Numeric input and ranking | Python entry copied to the preview's private clipboard, then found at rank 1. |
| TextEdit | Unicode fixture captured and restored in a temporary document using manual ⌘V recovery. |
| Word | Text and bold restored through native copy/paste commands; style verified on a selected character, rather than only at the final insertion point. Plain text retrieved after closing the source document. |
| Excel | Multicolumn range, text and bold restored. Functional formula loss on historical replay reproduced and protected as described below. |
| Automatic return to the target application | Event-posting permission absent during the check: manual-recovery message verified. No macOS permission granted by the agent. |
| Existing launch at login | Previous installation observed as disabled; no automatic enabling or registration performed during migration. |
| Final installation | `/Applications/One Clipboard History.app` validated and opened; About shows 0.7.0 (7), MIT and GitHub. The old `mcm.app` moved to `build/Legacy/`, without deleting preferences or data. The Store test variant was removed from Applications. |

Keyboard commands directed by the UI driver are not proof of the global shortcut
on a physical keyboard. Carbon tests verify routing and conflicts; physical
validation remains separate. Likewise, accessibility-tree inspection does not
replace a VoiceOver walkthrough.

## Reproduced Excel case

A synthetic range containing two formulas was copied using Excel's native
command. Direct paste preserves relative formulas. After history restoration,
Excel may insert their calculated values.

The comparison covers **18 canonical types**, their sizes, order, SHA-256 hashes
and clipboard aliases: they are identical before and after restoration. The
`com.microsoft.Embed-Source` container does contain an OOXML package with
**two formula elements**. No formula data was therefore removed during capture.

Two experiments on this fixture alone did not correct the behavior: Quicksilver-style
deferred publication and experimental removal of the OLE owner marker alone.
These experiments remain in the build directory, outside the shipped software;
no format is removed in production.

The application applies these protections:

1. A copy still identical to the current clipboard retains its owner and context:
   no rewrite is needed.
2. The observed Excel signature is indicated in the entry description.
3. When reconstruction is necessary, a confirmation explains that formulas may
   become values; **Cancel is the default choice**.
4. Clipboard changes between preflight and writing are checked again; refusal
   preserves the existing clipboard. An authorized restoration restores every
   original type and byte.

Byte equality does not establish that the source application's live private
context can be reconstructed. Full historical Excel fidelity, including merged
cells, borders, links and complex formats, remains to be qualified.

## Responsiveness

Command:

```sh
OCH_RUN_BENCHMARKS=1 swift test --filter OpeningPerformanceTests
```

Local measurement: 10 warm-up openings, then 100 openings with 20 preloaded
text entries, 12-point font, compact view and animations disabled.

| Metric | Milliseconds |
| --- | ---: |
| p50 | 4.400 |
| p95 | 7.210 |
| Maximum | 7.730 |

This measurement covers opening, layout and AppKit display submission. It does
not measure the first complete frame actually presented by the compositor, or
paste into a third-party application. The 50 ms target for that complete display
remains to be verified. **No CPU ceiling is imposed.**

After closing information windows, a point-in-time reading of the installed
application showed **0.0% CPU** and **126,960 KiB RSS** (about 124 MiB), after
43 seconds of execution. This idle reading is neither an average nor a
consumption limit, and does not characterize large-image processing.

## GitHub delivery

The sources and their history are published on the `main` branch of the
[public repository](https://github.com/armateurlabs/one-clipboard-history).
The three screenshots are genuine PNG files, captured from the preview
application with synthetic data.

The `one-clipboard-history-0.7.0-macos-arm64.zip` archive contains the direct
arm64 bundle, its license, translations and privacy policy. A fresh extraction
was validated with `scripts/validate-app.sh`. It uses an ad hoc signature,
without notarization, and is delivered as a validation prerelease.

ZIP SHA-256:

```text
10dc8e7234db2ac3031b6818e2fa358ea7564f01e5aa86e5d59ea7ac13d992f2
```

## Prerequisites and remaining validation

- Developer ID signing, notarization and distribution Gatekeeper validation:
  no valid Apple certificate installed at the time of validation.
- Apple Distribution signing, provisioning, final export and App Review:
  preparation provided, no submission performed.
- Automatic paste with permission granted in Brave, TextEdit, Terminal, Finder,
  Word and Excel; permission revocation and real focus changes.
- Word: lists, tables, images, fields and links; fully quitting Word and
  restarting with persistence. The simple bold check does not validate these cases.
- Excel: full historical functional fidelity despite private formats; retain
  the warning while the reproduced case remains unresolved.
- External files and bookmarks after relaunch in the Store distribution with
  actual permissions; simulated tests do not prove that the sandbox and App Review
  accept the complete workflow.
- Real login session, sleep/wake, multiple displays, Spaces, full screen and
  complete VoiceOver navigation, without disrupting the user's working session.

The 200 ms polling interval retains its known limitation: a copy replaced
between two reads may not be captured.
