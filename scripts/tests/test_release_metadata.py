"""Release metadata safety checks; standard-library-only and platform independent."""

from pathlib import Path
import plistlib
import sys
import tempfile
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from release_metadata import MetadataError, load_metadata


class ReleaseMetadataTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory(prefix="och-metadata-")
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name)
        (self.root / "Resources").mkdir()
        (self.root / "AppStore").mkdir()
        self.write_metadata()

    def write_metadata(self, version="1.0.0", build="10", store_version="1.0.0", store_build="10"):
        with (self.root / "Resources/Info.plist").open("wb") as stream:
            plistlib.dump({"CFBundleShortVersionString": version, "CFBundleVersion": build}, stream)
        (self.root / "AppStore/Base.xcconfig").write_text(
            f"MARKETING_VERSION = {store_version}\nCURRENT_PROJECT_VERSION = {store_build}\n",
            encoding="utf-8",
        )

    def test_matching_metadata_without_tag(self):
        self.assertEqual(load_metadata(self.root), {"version": "1.0.0", "build": "10", "tag": None})

    def test_matching_release_tag(self):
        self.assertEqual(load_metadata(self.root, "v1.0.0"), {"version": "1.0.0", "build": "10", "tag": "v1.0.0"})

    def test_mismatched_or_noncanonical_tags_are_rejected(self):
        for tag in ("v0.9.0", "1.0.0", "v1.0.0-rc.1", "v1.0.0+10", "v1.0.0\n", "", "v1.0.0;echo no"):
            with self.subTest(tag=tag), self.assertRaisesRegex(MetadataError, "Release tag"):
                load_metadata(self.root, tag)

    def test_mismatched_store_marketing_version_is_rejected(self):
        self.write_metadata(store_version="0.9.0")
        with self.assertRaisesRegex(MetadataError, "MARKETING_VERSION"):
            load_metadata(self.root)

    def test_mismatched_store_build_is_rejected(self):
        self.write_metadata(store_build="9")
        with self.assertRaisesRegex(MetadataError, "CURRENT_PROJECT_VERSION"):
            load_metadata(self.root)

    def test_invalid_marketing_versions_are_rejected(self):
        for version in ("1", "1.0", "v1.0.0", "1.0.0-rc.1", "01.0.0", "1.0.0\n", "1.-1.0", 1):
            with self.subTest(version=version):
                self.write_metadata(version=version)
                with self.assertRaisesRegex(MetadataError, "CFBundleShortVersionString"):
                    load_metadata(self.root)

    def test_invalid_builds_are_rejected(self):
        for build in ("", "0", "01", "-1", "1.0", "10beta", "10\n", 10, True):
            with self.subTest(build=build):
                self.write_metadata(build=build)
                with self.assertRaisesRegex(MetadataError, "CFBundleVersion"):
                    load_metadata(self.root)

    def test_missing_and_duplicate_store_fields_are_rejected(self):
        path = self.root / "AppStore/Base.xcconfig"
        for source in (
            "MARKETING_VERSION = 1.0.0\n",
            "CURRENT_PROJECT_VERSION = 10\n",
            "MARKETING_VERSION = 1.0.0\nMARKETING_VERSION = 1.0.0\nCURRENT_PROJECT_VERSION = 10\n",
            "MARKETING_VERSION = 1.0.0\nCURRENT_PROJECT_VERSION = 10\nCURRENT_PROJECT_VERSION = 11\n",
        ):
            with self.subTest(source=source):
                path.write_text(source, encoding="utf-8")
                with self.assertRaises(MetadataError):
                    load_metadata(self.root)

    def test_config_spacing_and_comments_do_not_change_values(self):
        (self.root / "AppStore/Base.xcconfig").write_text(
            "// Release metadata\n  MARKETING_VERSION  =  1.0.0 // Public version\n"
            "CURRENT_PROJECT_VERSION = 10\nPRODUCT_NAME = Example\n",
            encoding="utf-8",
        )
        self.assertEqual(load_metadata(self.root, "v1.0.0")["version"], "1.0.0")

    def test_missing_or_invalid_canonical_plist_is_rejected(self):
        path = self.root / "Resources/Info.plist"
        path.unlink()
        with self.assertRaisesRegex(MetadataError, "canonical release metadata"):
            load_metadata(self.root)
        for source in (b"not a plist", b"<plist><dict>"):
            with self.subTest(source=source):
                path.write_bytes(source)
                with self.assertRaisesRegex(MetadataError, "canonical release metadata"):
                    load_metadata(self.root)


if __name__ == "__main__":
    unittest.main()
