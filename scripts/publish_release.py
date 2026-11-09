#!/usr/bin/env python3
"""Publish a verified tag package without rebuilding or replacing a published release."""

from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path
import re
import subprocess
import sys
import tempfile
import zipfile

from package_release import verify_package
from release_metadata import load_metadata


class PublicationError(ValueError):
    """The package or remote release does not match the requested publication."""


def validate_request(manifest: dict, metadata: dict, tag: str, commit: str) -> None:
    if re.fullmatch(r"[0-9a-f]{40}", commit) is None:
        raise PublicationError("Expected source commit must be a full lowercase Git SHA")
    if manifest["dirty"]:
        raise PublicationError("Refusing to publish a package built from a dirty checkout")
    for key, expected in (("tag", tag), ("commit", commit),
                          ("version", metadata["version"]), ("build", metadata["build"])):
        if manifest[key] != expected:
            raise PublicationError(f"Package {key} does not match the requested release")


class GitHub:
    def __init__(self, repository: str):
        if re.fullmatch(r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+", repository) is None:
            raise PublicationError("Repository must use owner/name syntax")
        self.repository = repository

    def run(self, *arguments: str) -> str:
        result = subprocess.run(["gh", *arguments], text=True, capture_output=True)
        if result.returncode:
            raise PublicationError(result.stderr.strip() or "GitHub CLI request failed")
        return result.stdout

    def tag_commit(self, tag: str) -> str:
        item = json.loads(self.run("api", f"repos/{self.repository}/git/ref/tags/{tag}"))["object"]
        for _ in range(8):
            if item["type"] == "commit":
                return item["sha"]
            if item["type"] != "tag":
                break
            item = json.loads(self.run("api", f"repos/{self.repository}/git/tags/{item['sha']}"))["object"]
        raise PublicationError("Release tag does not resolve to a commit")

    def release(self, tag: str) -> dict | None:
        # Listing includes drafts; the release-by-tag REST endpoint does not.
        pages = json.loads(self.run("api", "--paginate", "--slurp",
                                    f"repos/{self.repository}/releases?per_page=100"))
        matches = [release for page in pages for release in page if release["tag_name"] == tag]
        if len(matches) > 1:
            raise PublicationError("Multiple releases refer to the requested tag")
        return matches[0] if matches else None

    def create_draft(self, tag: str, commit: str, title: str, notes: Path) -> None:
        self.run("release", "create", tag, "--repo", self.repository, "--verify-tag",
                 "--target", commit, "--title", title, "--notes-file", str(notes),
                 "--draft", "--latest=false")

    def update_draft(self, tag: str, commit: str, title: str, notes: Path) -> None:
        self.run("release", "edit", tag, "--repo", self.repository, "--verify-tag",
                 "--target", commit, "--title", title, "--notes-file", str(notes),
                 "--draft=true", "--prerelease=false")

    def upload(self, tag: str, files: list[Path]) -> None:
        self.run("release", "upload", tag, *(str(path) for path in files),
                 "--repo", self.repository, "--clobber")

    def download(self, tag: str, names: list[str], directory: Path) -> None:
        arguments = ["release", "download", tag, "--repo", self.repository, "--dir", str(directory)]
        for name in names:
            arguments.extend(("--pattern", name))
        self.run(*arguments)

    def publish(self, tag: str) -> None:
        self.run("release", "edit", tag, "--repo", self.repository, "--verify-tag",
                 "--draft=false", "--prerelease=false", "--latest=true")


def release_files(manifest: dict) -> list[str]:
    return [manifest["archive"], "SHA256SUMS.txt", "release.json", manifest["notes"]]


def verify_remote(client: GitHub, tag: str, manifest: dict, metadata: dict,
                  commit: str, local_package: Path | None = None) -> None:
    with tempfile.TemporaryDirectory(prefix="och-release-download-") as folder:
        directory = Path(folder)
        client.download(tag, release_files(manifest), directory)
        downloaded = verify_package(directory)
        validate_request(downloaded, metadata, tag, commit)
        if local_package is not None:
            for name in release_files(manifest):
                expected = hashlib.sha256((local_package / name).read_bytes()).digest()
                actual = hashlib.sha256((directory / name).read_bytes()).digest()
                if expected != actual:
                    raise PublicationError(f"Uploaded asset differs from the validated package: {name}")


def publish_package(directory: Path, tag: str, commit: str, root: Path, client: GitHub) -> str:
    metadata = load_metadata(root, tag)
    manifest = verify_package(directory)
    validate_request(manifest, metadata, tag, commit)
    if client.tag_commit(tag) != commit:
        raise PublicationError("Remote tag does not identify the validated source commit")

    release = client.release(tag)
    if release is not None and not release["draft"]:
        if release["prerelease"]:
            raise PublicationError("Existing published release is a prerelease; refusing to change it")
        # ZIP timestamps can differ on a rerun. Preserve published bytes and
        # verify their recorded source and checksums instead of replacing them.
        verify_remote(client, tag, manifest, metadata, commit)
        return "Already published; verified existing assets and left them unchanged"

    names = set(release_files(manifest))
    if release is not None and any(asset["name"] not in names for asset in release["assets"]):
        raise PublicationError("Existing draft contains unexpected assets; review it before retrying")
    title = f"One Clipboard History {manifest['version']}"
    notes = directory / manifest["notes"]
    if release is None:
        client.create_draft(tag, commit, title, notes)
    else:
        client.update_draft(tag, commit, title, notes)
    client.upload(tag, [directory / name for name in release_files(manifest)])
    verify_remote(client, tag, manifest, metadata, commit, local_package=directory)
    client.publish(tag)
    published = client.release(tag)
    if published is None or published["draft"] or published["prerelease"]:
        raise PublicationError("GitHub did not publish the expected stable release")
    return published["html_url"]


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--package", type=Path, required=True)
    parser.add_argument("--repo", required=True)
    parser.add_argument("--tag", required=True)
    parser.add_argument("--commit", required=True)
    arguments = parser.parse_args()
    try:
        result = publish_package(arguments.package.resolve(), arguments.tag, arguments.commit,
                                 Path(__file__).resolve().parents[1], GitHub(arguments.repo))
    except (ValueError, OSError, subprocess.SubprocessError, zipfile.BadZipFile) as error:
        print(f"Release publication failed: {error}", file=sys.stderr)
        return 1
    print(result)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
