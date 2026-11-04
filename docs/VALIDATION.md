# One Clipboard History 0.9.0 validation — 4 November 2026

Version **0.9.0 (9)**, macOS 27 on Apple Silicon. This update makes English the
project's working language and adds Spanish, Italian, Russian, Simplified Chinese
and German to the existing English and French interface.

## Automated checks

`swift test`: **139 tests passed**, comprising **79 Core** and **60 AppKit/settings**.

Localization checks cover all seven catalogs: identical sets of 163 keys,
nonempty translations, unchanged printf argument signatures and order, preserved
newlines, complete literal app/status coverage, and actual resource-bundle loading.
Formatting tests retain Unicode source application names and other arguments.

System language resolution covers regional preferences including `es-MX`,
`it-CH`, `ru-RU`, `de-AT`, `zh-CN` and `zh-SG`, plus English fallback. Chinese
support is explicitly Simplified Chinese (`zh-Hans`); Traditional Chinese is
not advertised or selected as a translated script. Every language setting
survives preferences reload without changing history limits, density or persistence.

Both app variants declare seven bundle localizations. The direct packaging script
copies all permission catalogs; the Xcode resource variant group includes all
seven. Bundle validation checks every permission and app catalog and lints each
packaged strings file.

## Real application checks

The preview app was switched through Spanish, Italian, Russian, Simplified
Chinese, German, French and English without restarting. Settings titles,
headings, appearance controls, density options and language selectors were
inspected in the accessibility tree. Russian and Chinese settings were also
inspected visually. Language names use endonyms so the selector remains
recognizable after switching.

The first visual pass found that cached SwiftUI picker options retained their
previous language. Recreating the settings form on language changes fixed this;
the repeated pass confirmed translated density options in Spanish, Italian,
Russian, Chinese and German.

In Chinese history, app-owned type labels and comments changed while synthetic
English clipboard text, Python code, file names and source app names stayed
unchanged. These checks used an isolated preview clipboard and preferences;
personal clipboard data was not published.

## English project and delivery

The canonical README, Store preparation dossier, privacy policy and historical
validation reports are in English. Existing English documentation was promoted
to canonical paths; obsolete duplicate files were removed. Project language
conventions are recorded in `AGENTS.md`. App localization resources and
multilingual test fixtures remain in their target languages.

The direct release and preview bundles are built and verified by
`scripts/validate-app.sh`. The [macOS 27 / Apple Silicon CI](https://github.com/armateurlabs/one-clipboard-history/actions/workflows/ci.yml)
also runs tests, release compilation, bundle checks and sandboxed archiving.
The direct app retains `com.arthur.mcm`, existing preferences and history storage.
Version 0.9.0 is installed at `/Applications/One Clipboard History.app`; the
previous bundle is archived under `build/InstallBackups/`. The release ZIP was
extracted into a fresh directory and passed the same bundle validation.

## Remaining qualification

These are complete initial translations, with automated catalog validation and
live UI inspection; independent native-speaker review and full VoiceOver
navigation in every language remain useful follow-up checks. No new timing
claim or CPU ceiling is introduced.

Format fidelity, Excel's source-context limitation, permission/focus scenarios,
Apple signing and notarization prerequisites remain documented in
[0.7.0 validation](VALIDATION-0.7.md) and [Store preparation](APP_STORE.md).
Density behavior and its earlier checks are preserved in
[0.8.0 validation](VALIDATION-0.8.md).
