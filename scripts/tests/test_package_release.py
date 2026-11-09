"""Portable release verification tests; actual macOS round trips run in CI."""

import hashlib
import json
from pathlib import Path
import plistlib
import stat
import sys
import tempfile
import unittest
from unittest.mock import patch
import zipfile

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import package_release


class PackageVerificationTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.directory = Path(self.temporary.name)
        self.manifest = {
            "schema": 1,
            "tag": "v1.0.0",
            "version": "1.0.0",
            "build": "10",
            "commit": "a" * 40,
            "dirty": False,
            "archive": "one-clipboard-history-1.0.0-macos-arm64.zip",
            "sha256": "",
            "notes": "release-notes.md",
            "notes_sha256": "",
            "signing": "ad-hoc",
        }
        self.info = {
            "CFBundleIdentifier": "com.arthur.mcm",
            "CFBundleExecutable": "OneClipboardHistory",
            "CFBundleShortVersionString": "1.0.0",
            "CFBundleVersion": "10",
        }
        (self.directory / "release-notes.md").write_text("A synthetic release. Ad hoc signed.\n", encoding="utf-8")
        self.write_archive()

    def write_archive(self, *, executable_mode=0o100755, extra=None):
        path = self.directory / self.manifest["archive"]
        with zipfile.ZipFile(path, "w", compression=zipfile.ZIP_DEFLATED) as archive:
            archive.writestr(package_release.INFO_PLIST, plistlib.dumps(self.info))
            binary = zipfile.ZipInfo(package_release.EXECUTABLE)
            binary.create_system = 3
            binary.external_attr = executable_mode << 16
            archive.writestr(binary, b"synthetic executable bytes")
            if extra:
                for info, data in extra:
                    archive.writestr(info, data)
        self.write_manifest()

    def write_manifest(self):
        self.manifest["sha256"] = hashlib.sha256((self.directory / self.manifest["archive"]).read_bytes()).hexdigest()
        self.manifest["notes_sha256"] = hashlib.sha256((self.directory / self.manifest["notes"]).read_bytes()).hexdigest()
        (self.directory / "SHA256SUMS.txt").write_text(
            f"{self.manifest['sha256']}  {self.manifest['archive']}\n", encoding="utf-8")
        (self.directory / "release.json").write_text(json.dumps(self.manifest), encoding="utf-8")

    def test_valid_package_is_verified_portably(self):
        self.assertEqual(package_release.verify_package(self.directory), self.manifest)

    def test_archive_tampering_fails_before_use(self):
        with (self.directory / self.manifest["archive"]).open("ab") as stream:
            stream.write(b"tampered")
        with self.assertRaisesRegex(ValueError, "archive checksum mismatch"):
            package_release.verify_package(self.directory)

    def test_notes_and_checksum_tampering_are_rejected(self):
        with self.subTest("notes"):
            (self.directory / "release-notes.md").write_text("Different notes\n", encoding="utf-8")
            with self.assertRaisesRegex(ValueError, "notes checksum mismatch"):
                package_release.verify_package(self.directory)
        self.write_manifest()
        with self.subTest("checksums"):
            (self.directory / "SHA256SUMS.txt").write_text("anything\n", encoding="utf-8")
            with self.assertRaisesRegex(ValueError, "SHA256SUMS"):
                package_release.verify_package(self.directory)

    def test_manifest_cannot_select_external_files(self):
        self.manifest["archive"] = "../one-clipboard-history-1.0.0-macos-arm64.zip"
        (self.directory / "release.json").write_text(json.dumps(self.manifest), encoding="utf-8")
        with self.assertRaisesRegex(ValueError, "archive file name"):
            package_release.verify_package(self.directory)

    def test_manifest_tag_types_schema_and_commit_are_checked(self):
        cases = [("tag", "v2.0.0"), ("version", "01.0.0"), ("build", "0"),
                 ("schema", True), ("dirty", "false"), ("commit", "branch-name"),
                 ("signing", "notarized")]
        for key, value in cases:
            with self.subTest(key=key):
                original = self.manifest[key]
                self.manifest[key] = value
                (self.directory / "release.json").write_text(json.dumps(self.manifest), encoding="utf-8")
                with self.assertRaises(ValueError):
                    package_release.verify_package(self.directory)
                self.manifest[key] = original

    def test_duplicate_manifest_fields_are_rejected(self):
        text = json.dumps(self.manifest).replace('"schema": 1', '"schema": 2, "schema": 1')
        (self.directory / "release.json").write_text(text, encoding="utf-8")
        with self.assertRaisesRegex(ValueError, "Duplicate manifest key"):
            package_release.verify_package(self.directory)

    def test_archive_retains_executable_mode(self):
        self.write_archive(executable_mode=0o100644)
        with self.assertRaisesRegex(ValueError, "executable permissions"):
            package_release.verify_package(self.directory)

    def test_preview_store_and_wrong_versions_are_rejected(self):
        cases = [("OCHPreviewMode", True), ("OCHMacAppStoreBuild", True),
                 ("CFBundleIdentifier", "com.armateurlabs.oneclipboardhistory"),
                 ("CFBundleShortVersionString", "0.9.0"), ("CFBundleVersion", "9")]
        original = dict(self.info)
        for key, value in cases:
            with self.subTest(key=key):
                self.info = {**original, key: value}
                self.write_archive()
                with self.assertRaises(ValueError):
                    package_release.verify_package(self.directory)

    def test_zip_traversal_absolute_paths_and_other_roots_are_rejected(self):
        for name in ["../escape", "/absolute", "Other.app/file", f"{package_release.APP_NAME}/../escape"]:
            with self.subTest(name=name):
                self.write_archive(extra=[(name, b"invalid")])
                with self.assertRaises(ValueError):
                    package_release.verify_package(self.directory)

    def test_zip_symlinks_must_stay_inside_app(self):
        link = zipfile.ZipInfo(f"{package_release.APP_NAME}/Contents/Resources/link")
        link.create_system = 3
        link.external_attr = (stat.S_IFLNK | 0o777) << 16
        for target in [b"../../../outside", b"/etc/passwd"]:
            with self.subTest(target=target):
                self.write_archive(extra=[(link, target)])
                with self.assertRaisesRegex(ValueError, "symlink"):
                    package_release.verify_package(self.directory)
        self.write_archive(extra=[(link, b"../MacOS/OneClipboardHistory")])
        self.assertEqual(package_release.verify_package(self.directory), self.manifest)

    def test_duplicate_zip_members_and_special_files_are_rejected(self):
        duplicate = zipfile.ZipInfo(package_release.EXECUTABLE)
        with self.assertWarns(UserWarning):
            self.write_archive(extra=[(duplicate, b"duplicate")])
        with self.assertRaisesRegex(ValueError, "Duplicate ZIP member"):
            package_release.verify_package(self.directory)
        device = zipfile.ZipInfo(f"{package_release.APP_NAME}/Contents/device")
        device.create_system = 3
        device.external_attr = (stat.S_IFCHR | 0o600) << 16
        self.write_archive(extra=[(device, b"")])
        with self.assertRaisesRegex(ValueError, "Unsupported ZIP member type"):
            package_release.verify_package(self.directory)

    def test_sidecars_cannot_be_symlinks(self):
        notes = self.directory / "release-notes.md"
        notes.rename(self.directory / "elsewhere.md")
        notes.symlink_to("elsewhere.md")
        with self.assertRaisesRegex(ValueError, "Not a regular package file"):
            package_release.verify_package(self.directory)

    def test_dirty_source_is_recorded_but_publisher_decides_admission(self):
        self.manifest["dirty"] = True
        self.write_manifest()
        self.assertTrue(package_release.verify_package(self.directory)["dirty"])


class MacPackagingGuardTests(unittest.TestCase):
    def test_only_arm64_architecture_is_admitted(self):
        package_release._require_arm64("arm64\n")
        for value in ["x86_64", "arm64 x86_64", ""]:
            with self.subTest(value=value), self.assertRaisesRegex(ValueError, "only the arm64"):
                package_release._require_arm64(value)

    def test_signing_category_does_not_infer_notarization(self):
        self.assertEqual(package_release._signing_category("Signature=adhoc\n"), "ad-hoc")
        self.assertEqual(package_release._signing_category("Authority=Developer ID Application: Example\n"), "developer-id")
        self.assertEqual(package_release._signing_category("Authority=Apple Distribution: Example\n"), "other")

    def test_release_notes_report_signing_limits(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            notes = root / "docs/releases/1.0.0.md"
            notes.parent.mkdir(parents=True)
            notes.write_text("Version-specific release notes.\n", encoding="utf-8")
            generated = package_release._release_notes(root, {"version": "1.0.0", "build": "10"}, "ad-hoc")
            self.assertTrue(generated.startswith("Version-specific release notes."))
            self.assertIn("ad hoc signed", generated)
            self.assertIn("does not notarize", generated)
            self.assertIn("not a submitted Mac App Store package", generated)

    def test_packaging_is_not_available_on_non_macos(self):
        with patch.object(package_release.sys, "platform", "linux"):
            with self.assertRaisesRegex(ValueError, "requires macOS"):
                package_release.package_release(Path("."), Path("app"), Path("build/release"))


if __name__ == "__main__":
    unittest.main()
