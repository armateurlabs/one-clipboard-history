"""Publication must stop before exposing an inconsistent or incomplete package."""

import hashlib
import json
from pathlib import Path
import plistlib
import shutil
import stat
import sys
import tempfile
import unittest
import zipfile

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from publish_release import PublicationError, publish_package


COMMIT = "a" * 40


def fixture(directory, *, commit=COMMIT, dirty=False):
    directory.mkdir(parents=True, exist_ok=True)
    archive = "one-clipboard-history-1.0.0-macos-arm64.zip"
    info = {"CFBundleIdentifier": "com.arthur.mcm", "CFBundleExecutable": "OneClipboardHistory",
            "CFBundleShortVersionString": "1.0.0", "CFBundleVersion": "10"}
    with zipfile.ZipFile(directory / archive, "w") as bundle:
        bundle.writestr("One Clipboard History.app/Contents/Info.plist", plistlib.dumps(info))
        executable = zipfile.ZipInfo("One Clipboard History.app/Contents/MacOS/OneClipboardHistory")
        executable.create_system = 3
        executable.external_attr = (stat.S_IFREG | 0o755) << 16
        bundle.writestr(executable, b"fixture executable")
    notes = b"Ad hoc signed test package; not notarized.\n"
    (directory / "release-notes.md").write_bytes(notes)
    digest = hashlib.sha256((directory / archive).read_bytes()).hexdigest()
    manifest = {"schema": 1, "tag": "v1.0.0", "version": "1.0.0", "build": "10",
                "commit": commit, "dirty": dirty, "archive": archive, "sha256": digest,
                "notes": "release-notes.md", "notes_sha256": hashlib.sha256(notes).hexdigest(),
                "signing": "ad-hoc"}
    (directory / "release.json").write_text(json.dumps(manifest))
    (directory / "SHA256SUMS.txt").write_text(f"{digest}  {archive}\n")
    return manifest


class FakeGitHub:
    def __init__(self, assets, *, draft=None, remote_commit=COMMIT, corrupt=False, extras=False):
        self.assets = assets
        self.state = None if draft is None else {
            "draft": draft, "prerelease": False, "html_url": "https://example.test/release",
            "assets": [{"name": "unexpected.txt"}] if extras else []}
        self.remote_commit = remote_commit
        self.corrupt = corrupt
        self.writes = []

    def tag_commit(self, tag):
        return self.remote_commit

    def release(self, tag):
        return self.state

    def create_draft(self, *arguments):
        self.writes.append("create draft")
        self.state = {"draft": True, "prerelease": False,
                      "html_url": "https://example.test/release", "assets": []}

    def update_draft(self, *arguments):
        self.writes.append("update draft")

    def upload(self, tag, files):
        self.writes.append("upload")

    def download(self, tag, names, directory):
        for name in names:
            shutil.copyfile(self.assets / name, directory / name)
        if self.corrupt:
            (directory / "release-notes.md").write_text("corrupted transfer")

    def publish(self, tag):
        self.writes.append("publish")
        self.state["draft"] = False


class PublicationTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name)
        (self.root / "Resources").mkdir()
        (self.root / "Resources/Info.plist").write_bytes(plistlib.dumps({
            "CFBundleShortVersionString": "1.0.0", "CFBundleVersion": "10"}))
        (self.root / "AppStore").mkdir()
        (self.root / "AppStore/Base.xcconfig").write_text(
            "MARKETING_VERSION = 1.0.0\nCURRENT_PROJECT_VERSION = 10\n")
        self.package = self.root / "package"
        fixture(self.package)

    def tearDown(self):
        self.temporary.cleanup()

    def publish(self, client, *, tag="v1.0.0", commit=COMMIT):
        return publish_package(self.package, tag, commit, self.root, client)

    def test_assets_are_verified_before_draft_becomes_public(self):
        client = FakeGitHub(self.package)
        self.assertEqual(self.publish(client), "https://example.test/release")
        self.assertEqual(client.writes, ["create draft", "upload", "publish"])

    def test_dirty_or_wrong_commit_package_never_mutates_github(self):
        for dirty, commit in [(True, COMMIT), (False, "b" * 40)]:
            with self.subTest(dirty=dirty, commit=commit):
                fixture(self.package, dirty=dirty, commit=commit)
                client = FakeGitHub(self.package)
                with self.assertRaises(PublicationError):
                    self.publish(client)
                self.assertEqual(client.writes, [])

    def test_remote_tag_must_identify_the_validated_commit(self):
        client = FakeGitHub(self.package, remote_commit="b" * 40)
        with self.assertRaises(PublicationError):
            self.publish(client)
        self.assertEqual(client.writes, [])

    def test_mismatched_tag_is_rejected_before_github_mutation(self):
        client = FakeGitHub(self.package)
        with self.assertRaises(ValueError):
            self.publish(client, tag="v2.0.0")
        self.assertEqual(client.writes, [])

    def test_corrupt_remote_asset_leaves_release_unpublished(self):
        client = FakeGitHub(self.package, corrupt=True)
        with self.assertRaises(ValueError):
            self.publish(client)
        self.assertEqual(client.writes, ["create draft", "upload"])
        self.assertTrue(client.state["draft"])

    def test_retry_resumes_an_existing_draft(self):
        client = FakeGitHub(self.package, draft=True)
        self.publish(client)
        self.assertEqual(client.writes, ["update draft", "upload", "publish"])

    def test_published_assets_are_verified_without_any_overwrite(self):
        client = FakeGitHub(self.package, draft=False)
        self.assertIn("Already published", self.publish(client))
        self.assertEqual(client.writes, [])

    def test_published_wrong_source_and_unknown_draft_assets_are_preserved(self):
        old_package = self.root / "old-package"
        fixture(old_package, commit="b" * 40)
        clients = [FakeGitHub(old_package, draft=False),
                   FakeGitHub(self.package, draft=True, extras=True)]
        for client in clients:
            with self.assertRaises(PublicationError):
                self.publish(client)
            self.assertEqual(client.writes, [])


if __name__ == "__main__":
    unittest.main()
