#!/usr/bin/env python3
"""Read and validate release metadata shared by both macOS distributions."""

from __future__ import annotations

import argparse
import json
from pathlib import Path
import plistlib
import re
import sys
from xml.parsers.expat import ExpatError


class MetadataError(ValueError):
    """Release metadata is missing, invalid or inconsistent."""


VERSION_PATTERN = re.compile(r"(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)")
BUILD_PATTERN = re.compile(r"[1-9][0-9]*")


def _configuration_versions(path: Path) -> dict[str, str]:
    try:
        lines = path.read_text(encoding="utf-8").splitlines()
    except (OSError, UnicodeError) as error:
        raise MetadataError(f"Cannot read Store version configuration: {path}") from error
    values: dict[str, str] = {}
    for line in lines:
        # These release fields must be literal, unconditional assignments.
        assignment = line.split("//", 1)[0].strip()
        match = re.fullmatch(r"(MARKETING_VERSION|CURRENT_PROJECT_VERSION)\s*=\s*(.*)", assignment)
        if match is None:
            continue
        key, value = match.groups()
        if key in values:
            raise MetadataError(f"Store configuration contains duplicate {key} assignments")
        values[key] = value.strip()
    for key in ("MARKETING_VERSION", "CURRENT_PROJECT_VERSION"):
        if key not in values:
            raise MetadataError(f"Store configuration is missing {key}")
    return values


def load_metadata(root: Path, tag: str | None = None) -> dict[str, str | None]:
    """Return canonical version/build after checking the Store values and optional tag.

    Resources/Info.plist is canonical. Both marketing versions must use numeric
    x.y.z syntax and builds must be positive integers, without leading zeroes.
    A supplied tag must be exactly v<marketing-version>.
    """
    root = Path(root)
    path = root / "Resources/Info.plist"
    try:
        with path.open("rb") as stream:
            info = plistlib.load(stream)
    except (OSError, ValueError, TypeError, ExpatError) as error:
        raise MetadataError(f"Cannot read canonical release metadata: {path}") from error
    if not isinstance(info, dict):
        raise MetadataError("Canonical release metadata must be a plist dictionary")

    version = info.get("CFBundleShortVersionString")
    build = info.get("CFBundleVersion")
    if not isinstance(version, str) or VERSION_PATTERN.fullmatch(version) is None:
        raise MetadataError("CFBundleShortVersionString must be a canonical numeric x.y.z version")
    if not isinstance(build, str) or BUILD_PATTERN.fullmatch(build) is None:
        raise MetadataError("CFBundleVersion must be a positive integer string without leading zeroes")

    store = _configuration_versions(root / "AppStore/Base.xcconfig")
    if store["MARKETING_VERSION"] != version:
        raise MetadataError(
            f"Store MARKETING_VERSION {store['MARKETING_VERSION']!r} does not match canonical version {version!r}"
        )
    if store["CURRENT_PROJECT_VERSION"] != build:
        raise MetadataError(
            f"Store CURRENT_PROJECT_VERSION {store['CURRENT_PROJECT_VERSION']!r} does not match canonical build {build!r}"
        )
    expected_tag = f"v{version}"
    if tag is not None and tag != expected_tag:
        raise MetadataError(f"Release tag {tag!r} must exactly match {expected_tag!r}")

    return {"version": version, "build": build, "tag": tag}


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--tag", help="Require an exact v<marketing-version> release tag")
    arguments = parser.parse_args()
    try:
        metadata = load_metadata(Path(__file__).resolve().parents[1], arguments.tag)
    except MetadataError as error:
        print(f"Release metadata error: {error}", file=sys.stderr)
        return 1
    print(json.dumps(metadata, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
