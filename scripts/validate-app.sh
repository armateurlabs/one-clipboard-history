#!/bin/bash
set -euo pipefail
if [[ "$#" -lt 1 || "$#" -gt 2 || ( "$#" == 2 && "$2" != --store ) ]]; then
    printf 'Usage: %s "path.app" [--store]\n' "$0" >&2
    exit 2
fi
codesign --verify --deep --strict "$1"
python3 - "$@" <<'PY'
import os
from pathlib import Path
import plistlib
import subprocess
import sys

app = Path(sys.argv[1]).resolve()
store = len(sys.argv) == 3
def require(condition, message):
    if not condition:
        raise SystemExit(f"Bundle validation failed: {message}")
def plist(path):
    with path.open('rb') as stream:
        return plistlib.load(stream)

info = plist(app / 'Contents/Info.plist')
identifier = info.get('CFBundleIdentifier')
expected = 'com.armateurlabs.oneclipboardhistory' if store else ('com.arthur.mcm.preview' if info.get('OCHPreviewMode') is True else 'com.arthur.mcm')
require(identifier == expected, f'unexpected bundle ID {identifier!r}')
name = 'One Clipboard History Preview' if info.get('OCHPreviewMode') is True else 'One Clipboard History'
require(info.get('CFBundleName') == name and info.get('CFBundleDisplayName') == name, 'incorrect app name')
require(info.get('CFBundleExecutable') == 'OneClipboardHistory', 'incorrect executable name')
require(info.get('CFBundleShortVersionString') == '0.7.0' and info.get('CFBundleVersion') == '7', 'incorrect release version')
require(info.get('LSUIElement') is True, 'menu bar agent flag is missing')
require(info.get('LSMinimumSystemVersion') == '27.0', 'incorrect deployment target')
require(info.get('LSApplicationCategoryType') == 'public.app-category.productivity', 'app category is missing')
require(bool(info.get('NSHumanReadableCopyright')), 'copyright is missing')
require(bool(info.get('NSPasteboardUsageDescription')), 'clipboard permission explanation is missing')
executable = app / 'Contents/MacOS/OneClipboardHistory'
require(executable.is_file() and os.access(executable, os.X_OK), 'executable is missing or not executable')
resources = app / 'Contents/Resources'
for filename in ('AppIcon.icns', 'LICENSE.txt', 'PRIVACY.txt'):
    path = resources / filename
    require(path.is_file() and path.stat().st_size > 0, f'{filename} is missing or empty')
require('MIT License' in (resources / 'LICENSE.txt').read_text(), 'incorrect bundled license')
for language in ('en', 'fr'):
    localized = resources / f'{language}.lproj/InfoPlist.strings'
    require(localized.is_file(), f'{language} permission localization is missing')
    subprocess.run(['plutil', '-lint', str(localized)], check=True, stdout=subprocess.PIPE)
bundles = list(resources.glob('*_OneClipboardHistoryCore.bundle'))
require(len(bundles) == 1, 'shared Swift package resource bundle is missing or duplicated')
for language in ('en', 'fr'):
    # SwiftPM and Xcode use different resource bundle layouts on macOS.
    candidates = (bundles[0] / f'{language}.lproj/Localizable.strings', bundles[0] / f'Contents/Resources/{language}.lproj/Localizable.strings')
    require(any(path.is_file() for path in candidates), f'{language} app localization is missing')
privacy = plist(resources / 'PrivacyInfo.xcprivacy')
require(privacy.get('NSPrivacyTracking') is False, 'tracking must be disabled')
require(privacy.get('NSPrivacyTrackingDomains') == [], 'unexpected tracking domains')
require(privacy.get('NSPrivacyCollectedDataTypes') == [], 'unexpected data collection declaration')
require(privacy.get('NSPrivacyAccessedAPITypes') == [{'NSPrivacyAccessedAPIType': 'NSPrivacyAccessedAPICategoryUserDefaults', 'NSPrivacyAccessedAPITypeReasons': ['CA92.1']}], 'unexpected UserDefaults privacy declaration')
if store:
    require(info.get('OCHMacAppStoreBuild') is True, 'Store build marker is missing')
    require(not info.get('OCHPreviewMode'), 'Store build must not be preview mode')
    signed = subprocess.run(['codesign', '-d', '--entitlements', '-', '--xml', str(app)], check=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    entitlements = plistlib.loads(signed.stdout)
    for key in ('com.apple.security.app-sandbox', 'com.apple.security.files.user-selected.read-only', 'com.apple.security.files.bookmarks.app-scope'):
        require(entitlements.get(key) is True, f'{key} is missing from the code signature')
    require(not entitlements.get('com.apple.security.get-task-allow'), 'Release archive allows debugging')
    require(not any('temporary-exception' in key or key == 'com.apple.security.accessibility' for key in entitlements), 'unexpected sandbox exception')
print(f'Validated {name} 0.7.0 (7), {identifier}' + (' — sandbox enabled' if store else ''))
PY
