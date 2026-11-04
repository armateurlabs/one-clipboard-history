# Mac App Store preparation

[Project](../README.md) · [Privacy](../PRIVACY.md)

## Two distributions, shared core

The GitHub distribution keeps all features and the historical identifier
`com.arthur.mcm`. The **OneClipboardHistory Store** target in
`OneClipboardHistory.xcodeproj` uses `com.armateurlabs.oneclipboardhistory` and
a separate sandbox container. Both share the same Swift core.

App Sandbox is required for the Mac App Store. Automatic paste must be tested
inside that target with real permissions. Compiling a sandboxed app establishes
neither cross-app paste behavior nor Apple’s acceptance. A Store restriction
will not remove functionality from the GitHub version.

Apple references: [App Sandbox](https://developer.apple.com/documentation/security/app-sandbox),
[review guidelines](https://developer.apple.com/app-store/review/guidelines/),
[file access](https://developer.apple.com/documentation/security/accessing-files-from-the-macos-app-sandbox),
[event posting](https://developer.apple.com/documentation/coregraphics/cgrequestposteventaccess()).

## Build and archive

```sh
# Locally signed sandbox prototype, without distribution credentials.
./scripts/archive-store.sh --unsigned

# Distribution archive with a configured team and certificates.
OCH_DEVELOPMENT_TEAM=YOURTEAMID ./scripts/archive-store.sh
OCH_DEVELOPMENT_TEAM=YOURTEAMID ./scripts/export-store.sh
```

The archive is written to `build/One Clipboard History Store.xcarchive`.
Local prototype signing is not Apple Distribution signing. These scripts do not
submit the app to the Store. Register the bundle ID in the Apple team before the
first upload.

## Feasibility checks

[VALIDATION.md](VALIDATION.md) records the checks actually performed. Verify in
the sandboxed bundle:

- Global ⌥A, instant opening/hiding, text/HTML/RTF/image capture and numeric
  selection without general keyboard monitoring.
- Explicit event-posting permission request; paste into TextEdit, Brave,
  Terminal, Finder, Word and Excel. Denial retains a manual ⌘V recovery path.
- File references, thumbnails, Finder restoration and access after relaunch
  using security-scoped bookmarks. Distinguish unavailable files from denied
  access; never silently transform formats.
- Consented silent launch at login, respecting a disabled macOS setting.
- Persistence, import, deletion and error recovery under minimal entitlements.

The app does not inspect another app’s editable fields to claim that paste was
accepted. Restoring clipboard bytes and the destination handling a posted paste
are separate checks.

Live testing identified an Excel case where formats, order and hashes remain
identical after restoration, but formulas become values. An unchanged current
copy keeps its clipboard owner; a historical copy with the observed Excel
dependency requires confirmation before any clipboard change. Keep this
limitation visible in metadata and validation notes until resolved.

### Importing early versions

The Store variant offers explicit selection of a legacy **History** folder from
settings. The native open panel grants access. Import validates all source data
before merging, without modifying the source or silently evicting existing
copies. Formats and bytes remain intact. Legacy file paths may require renewed
authorization; importing their bytes does not grant access. Store preferences
are separate from direct-distribution preferences.

## Proposed Store metadata

| Field | English |
| --- | --- |
| Name | One Clipboard History |
| Subtitle | Your copies, a shortcut away |
| Category | Productivity |
| Short description | Find and reuse your copies with a fast native clipboard palette. |
| Support | https://github.com/armateurlabs/one-clipboard-history/issues |
| Privacy | https://github.com/armateurlabs/one-clipboard-history/blob/main/PRIVACY.md |
| Copyright | 2026 Armateur Labs |

**Description:** One Clipboard History keeps your copies on your Mac. Open
history with a shortcut, choose an entry, and restore its text, formatting,
images or file references. Adjust font size, compactness, pointer positioning
and light or dark appearance. History starts at 20 entries; keeping it between
sessions is optional. No account, ads, analytics or network synchronization.

Only advertise automatic paste and Office fidelity for workflows validated in
the Store variant. Submission screenshots must show the real Store bundle if
its behavior differs from the GitHub distribution.

## App Review notes

- No account or server required. The app stays in the menu bar; ⌥A opens
  history. The gear and menus open settings.
- Clipboard access is the primary feature. Event posting is used only for
  paste explicitly requested by a digit, Return or double-click. Denial retains
  manual paste with ⌘V.
- Persistence and launch at login are initially off.
- Copied data stays on the device. GitHub links open only on request. The
  privacy policy is accessible from About.
- Use synthetic rich text, Python, image and file examples for review. Full
  Disk Access and general keyboard monitoring are not requested.

## Signing and publication status

On 4 November 2026, no valid Apple signing certificate was installed on the
development Mac. Prepared configuration and an ad hoc prototype do not validate
a distribution archive. Configure the team, Apple Distribution, provisioning
and App Store Connect record, then validate/export using Xcode. Submission and
App Review’s decision are later steps.

External distribution uses Developer ID and notarization:

```sh
OCH_SIGN_IDENTITY='Developer ID Application: …' ./scripts/build-app.sh
OCH_NOTARY_PROFILE=your-keychain-profile ./scripts/notarize-app.sh 'build/One Clipboard History.app'
```

Notarization uploads to Apple only when that command is run explicitly. Never
commit certificates, keys or tokens.
