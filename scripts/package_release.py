#!/usr/bin/env python3
"""Build and verify a direct-distribution release package without publishing it."""

from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path, PurePosixPath
import plistlib
import re
import shutil
import stat
import subprocess
import sys
import tempfile
import uuid
import zipfile


APP_NAME = "One Clipboard History.app"
EXECUTABLE = f"{APP_NAME}/Contents/MacOS/OneClipboardHistory"
INFO_PLIST = f"{APP_NAME}/Contents/Info.plist"
MANIFEST_KEYS = {
    "schema", "tag", "version", "build", "commit", "dirty", "archive",
    "sha256", "notes", "notes_sha256", "signing",
}
VERSION_PATTERN = re.compile(r"(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)\Z")
HASH_PATTERN = re.compile(r"[0-9a-f]{64}\Z")
COMMIT_PATTERN = re.compile(r"[0-9a-f]{40}\Z")


def _require(condition: bool, message: str) -> None:
    if not condition:
        raise ValueError(message)


def _digest(path: Path) -> str:
    value = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            value.update(chunk)
    return value.hexdigest()


def _regular_file(path: Path) -> None:
    _require(not path.is_symlink() and path.is_file(), f"Not a regular package file: {path.name}")


def _unique_object(pairs: list[tuple[str, object]]) -> dict:
    result = {}
    for key, value in pairs:
        _require(key not in result, f"Duplicate manifest key: {key}")
        result[key] = value
    return result


def _safe_zip_members(archive: zipfile.ZipFile) -> dict[str, zipfile.ZipInfo]:
    members = {}
    for member in archive.infolist():
        name = member.orig_filename
        _require("\x00" not in name and "\\" not in name, "Invalid ZIP member name")
        parts = name.rstrip("/").split("/")
        _require(all(part not in ("", ".", "..") for part in parts), f"Unsafe ZIP member: {name}")
        _require(parts[0] in (APP_NAME, "__MACOSX"), f"Unexpected ZIP root: {name}")
        _require(name not in members, f"Duplicate ZIP member: {name}")
        mode = member.external_attr >> 16
        kind = stat.S_IFMT(mode)
        _require(kind in (0, stat.S_IFREG, stat.S_IFDIR, stat.S_IFLNK), f"Unsupported ZIP member type: {name}")
        if kind == stat.S_IFLNK:
            target = archive.read(member).decode("utf-8")
            _require(target and not target.startswith("/") and "\\" not in target and "\x00" not in target,
                     f"Unsafe ZIP symlink: {name}")
            destination = list(PurePosixPath(name).parent.parts)
            for component in target.split("/"):
                if component in ("", "."):
                    continue
                if component == "..":
                    _require(len(destination) > 1, f"ZIP symlink escapes its root: {name}")
                    destination.pop()
                else:
                    destination.append(component)
            _require(destination[0] == parts[0], f"ZIP symlink escapes its root: {name}")
        members[name] = member
    return members


def _verify_zip(path: Path, manifest: dict) -> None:
    with zipfile.ZipFile(path) as archive:
        members = _safe_zip_members(archive)
        _require(INFO_PLIST in members and EXECUTABLE in members, "ZIP does not contain the canonical app bundle")
        executable = members[EXECUTABLE]
        mode = executable.external_attr >> 16
        _require(stat.S_IFMT(mode) == stat.S_IFREG and mode & 0o111 != 0,
                 "ZIP did not retain the app executable permissions")
        info = plistlib.loads(archive.read(INFO_PLIST))
        _require(isinstance(info, dict), "ZIP app Info.plist is invalid")
        _require(info.get("CFBundleIdentifier") == "com.arthur.mcm", "Only the direct-distribution app may be released")
        _require(not info.get("OCHPreviewMode") and not info.get("OCHMacAppStoreBuild"),
                 "Preview and Store prototype bundles cannot be released here")
        _require(info.get("CFBundleExecutable") == "OneClipboardHistory", "ZIP app executable name is incorrect")
        _require(info.get("CFBundleShortVersionString") == manifest["version"]
                 and info.get("CFBundleVersion") == manifest["build"], "ZIP app version does not match its manifest")
        damaged = archive.testzip()
        _require(damaged is None, f"ZIP integrity check failed: {damaged}")


def verify_package(directory: Path) -> dict:
    """Verify a downloaded package using only Python's standard library.

    This is deliberately portable: the publish job must not execute the macOS
    binary or rebuild source with its write-scoped GitHub token.
    """
    directory = Path(directory)
    _require(not directory.is_symlink() and directory.is_dir(), "Package directory is missing or is a symlink")
    manifest_path = directory / "release.json"
    _regular_file(manifest_path)
    manifest = json.loads(manifest_path.read_text(encoding="utf-8"), object_pairs_hook=_unique_object)
    _require(isinstance(manifest, dict) and set(manifest) == MANIFEST_KEYS, "Unexpected release manifest fields")
    _require(type(manifest["schema"]) is int and manifest["schema"] == 1, "Unsupported release manifest schema")
    for field in MANIFEST_KEYS - {"schema", "dirty"}:
        _require(isinstance(manifest[field], str), f"Manifest {field} must be a string")
    _require(type(manifest["dirty"]) is bool, "Manifest dirty must be a boolean")
    _require(VERSION_PATTERN.fullmatch(manifest["version"]) is not None, "Invalid release version")
    _require(re.fullmatch(r"[1-9][0-9]*", manifest["build"]) is not None, "Invalid release build")
    _require(manifest["tag"] == "v" + manifest["version"], "Release tag does not match its version")
    _require(COMMIT_PATTERN.fullmatch(manifest["commit"]) is not None, "Invalid source commit")
    _require(HASH_PATTERN.fullmatch(manifest["sha256"]) is not None
             and HASH_PATTERN.fullmatch(manifest["notes_sha256"]) is not None, "Invalid package digest")
    _require(manifest["signing"] in ("ad-hoc", "developer-id", "other"), "Invalid signing category")
    expected_archive = f"one-clipboard-history-{manifest['version']}-macos-arm64.zip"
    _require(manifest["archive"] == expected_archive, "Unexpected archive file name")
    _require(manifest["notes"] == "release-notes.md", "Unexpected release notes file name")
    archive_path = directory / manifest["archive"]
    notes_path = directory / manifest["notes"]
    checksum_path = directory / "SHA256SUMS.txt"
    for path in (archive_path, notes_path, checksum_path):
        _regular_file(path)
    _require(_digest(archive_path) == manifest["sha256"], "Release archive checksum mismatch")
    _require(_digest(notes_path) == manifest["notes_sha256"], "Release notes checksum mismatch")
    _require(notes_path.read_text(encoding="utf-8").strip() != "", "Release notes are empty")
    _require(checksum_path.read_text(encoding="utf-8") == f"{manifest['sha256']}  {manifest['archive']}\n",
             "SHA256SUMS.txt does not match the release manifest")
    _verify_zip(archive_path, manifest)
    return manifest


def _require_arm64(architectures: str) -> None:
    _require(architectures.split() == ["arm64"], "The release executable must contain only the arm64 architecture")


def _signing_category(description: str) -> str:
    lines = description.splitlines()
    if "Signature=adhoc" in lines:
        return "ad-hoc"
    if any(line.startswith("Authority=Developer ID Application:") for line in lines):
        return "developer-id"
    return "other"


def _command(arguments: list[str], *, cwd: Path | None = None, capture: bool = False) -> str:
    result = subprocess.run(arguments, cwd=cwd, check=True, text=True,
                            stdout=subprocess.PIPE if capture else sys.stderr,
                            stderr=subprocess.PIPE if capture else None)
    return result.stdout + result.stderr if capture else ""


def _validate_direct_app(app: Path, root: Path, metadata: dict) -> str:
    _require(app.name == APP_NAME and app.is_dir(), "Package the canonical One Clipboard History.app bundle")
    with (app / "Contents/Info.plist").open("rb") as stream:
        info = plistlib.load(stream)
    _require(info.get("CFBundleIdentifier") == "com.arthur.mcm"
             and not info.get("OCHPreviewMode") and not info.get("OCHMacAppStoreBuild"),
             "Only the direct-distribution app may be packaged")
    _require(info.get("CFBundleShortVersionString") == metadata["version"]
             and info.get("CFBundleVersion") == metadata["build"], "App version does not match release metadata")
    _command([str(root / "scripts/validate-app.sh"), str(app)])
    executable = app / "Contents/MacOS/OneClipboardHistory"
    _require_arm64(_command(["lipo", "-archs", str(executable)], capture=True))
    return _signing_category(_command(["codesign", "-d", "--verbose=4", str(app)], capture=True))


def _release_notes(root: Path, metadata: dict, signing: str) -> str:
    version = metadata["version"]
    source = root / "docs/releases" / f"{version}.md"
    introduction = source.read_text(encoding="utf-8").strip() if source.is_file() else (
        f"One Clipboard History {version} ({metadata['build']}), for macOS 27 on Apple Silicon."
    )
    if signing == "ad-hoc":
        status = ("This bundle is **ad hoc signed**, without a Developer ID Application signature. "
                  "This workflow does not notarize it; it is not a Gatekeeper-validated distribution.")
    elif signing == "developer-id":
        status = ("A Developer ID Application signature is present. "
                  "This workflow does not validate notarization or Gatekeeper acceptance.")
    else:
        status = ("A code signature is present, but this workflow does not establish Developer ID signing, "
                  "notarization or Gatekeeper acceptance.")
    return (introduction + "\n\n## Download and signing status\n\n"
            + "Download the macOS arm64 ZIP and use `SHA256SUMS.txt` to check its SHA-256 digest. "
              "Quit the previous version before moving `One Clipboard History.app` into Applications.\n\n"
            + status + "\n\n"
              "The sandboxed Store archive is a CI prototype, not a submitted Mac App Store package. "
              "See the [README](https://github.com/armateurlabs/one-clipboard-history/blob/main/README.md) "
              "and [validation report](https://github.com/armateurlabs/one-clipboard-history/blob/main/docs/VALIDATION.md) "
              "for supported behavior and remaining qualification.\n")


def package_release(root: Path, app: Path, output_dir: Path, tag: str | None = None) -> dict:
    if sys.platform != "darwin":
        raise ValueError("Building a release package requires macOS")
    from release_metadata import load_metadata

    root = root.resolve()
    app = app.resolve()
    _require(not output_dir.is_symlink(), "Release output cannot be a symlink")
    output_dir = output_dir.resolve()
    build_dir = (root / "build").resolve()
    _require(output_dir != build_dir and output_dir.is_relative_to(build_dir),
             "Release output must be a dedicated directory beneath the repository's build directory")
    metadata = load_metadata(root, tag)
    signing = _validate_direct_app(app, root, metadata)
    commit = _command(["git", "rev-parse", "HEAD"], cwd=root, capture=True).strip()
    _require(COMMIT_PATTERN.fullmatch(commit) is not None, "Cannot identify the source commit")
    dirty = bool(_command(["git", "status", "--porcelain", "--untracked-files=normal"], cwd=root, capture=True).strip())
    output_dir.parent.mkdir(parents=True, exist_ok=True)
    stage = Path(tempfile.mkdtemp(prefix=".release-stage-", dir=output_dir.parent))
    backup = None
    try:
        archive_name = f"one-clipboard-history-{metadata['version']}-macos-arm64.zip"
        archive_path = stage / archive_name
        _command(["ditto", "-c", "-k", "--sequesterRsrc", "--keepParent", str(app), str(archive_path)])
        with tempfile.TemporaryDirectory(prefix="och-release-extract-") as folder:
            _command(["ditto", "-x", "-k", str(archive_path), folder])
            restored_signing = _validate_direct_app(Path(folder) / APP_NAME, root, metadata)
            _require(restored_signing == signing, "ZIP round-trip changed the signing category")
        notes_path = stage / "release-notes.md"
        notes_path.write_text(_release_notes(root, metadata, signing), encoding="utf-8")
        manifest = {
            "schema": 1,
            "tag": metadata["tag"] or "v" + metadata["version"],
            "version": metadata["version"],
            "build": metadata["build"],
            "commit": commit,
            "dirty": dirty,
            "archive": archive_name,
            "sha256": _digest(archive_path),
            "notes": "release-notes.md",
            "notes_sha256": _digest(notes_path),
            "signing": signing,
        }
        (stage / "SHA256SUMS.txt").write_text(f"{manifest['sha256']}  {archive_name}\n", encoding="utf-8")
        (stage / "release.json").write_text(json.dumps(manifest, indent=2, sort_keys=True) + "\n", encoding="utf-8")
        verify_package(stage)
        if output_dir.exists():
            _require(not output_dir.is_symlink() and output_dir.is_dir(), "Existing release output is not a directory")
            previous = verify_package(output_dir)
            _require(set(path.name for path in output_dir.iterdir()) ==
                     {previous["archive"], "release.json", "release-notes.md", "SHA256SUMS.txt"},
                     "Existing release output contains unrelated files")
            backup = output_dir.with_name(f".release-backup-{uuid.uuid4().hex}")
            output_dir.rename(backup)
        try:
            stage.rename(output_dir)
        except BaseException:
            if backup is not None:
                backup.rename(output_dir)
                backup = None
            raise
        if backup is not None:
            shutil.rmtree(backup)
        return manifest
    finally:
        if stage.exists():
            shutil.rmtree(stage)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--app", required=True, type=Path)
    parser.add_argument("--tag")
    parser.add_argument("--output-dir", type=Path, default=Path("build/release"))
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[1]
    output = args.output_dir if args.output_dir.is_absolute() else root / args.output_dir
    try:
        manifest = package_release(root, args.app, output, args.tag)
    except (ValueError, OSError, subprocess.CalledProcessError, zipfile.BadZipFile) as error:
        print(f"Release packaging failed: {error}", file=sys.stderr)
        return 1
    print(json.dumps(manifest, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
