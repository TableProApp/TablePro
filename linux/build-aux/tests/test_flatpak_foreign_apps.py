import json
import re
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
MANIFESTS = [
    ROOT / "build-aux" / "flatpak" / "app.tablepro.TablePro.json",
    ROOT / "build-aux" / "flatpak" / "app.tablepro.TablePro.Devel.json",
]
APPS = ROOT.parent / "core" / "crates" / "foreign-import" / "src" / "apps"

# The ways the core names another app's Flatpak id: a path under ~/.var/app in a string, or a constant.
ID_PATTERNS = [
    re.compile(r"\.var/app/([A-Za-z0-9_.-]+)"),
    re.compile(r"FLATPAK_ID:\s*&str\s*=\s*\"([A-Za-z0-9_.-]+)\""),
    re.compile(r"flatpak\(\"([A-Za-z0-9_.-]+)\"\)"),
]
GRANT = re.compile(r"^--filesystem=~/\.var/app/([^:/]+)(:ro)?$")


def searched_ids():
    found = set()
    for source in APPS.rglob("*.rs"):
        text = source.read_text(encoding="utf-8")
        for pattern in ID_PATTERNS:
            found.update(pattern.findall(text))
    return found


def granted(manifest):
    grants = {}
    for argument in json.loads(manifest.read_text(encoding="utf-8"))["finish-args"]:
        match = GRANT.match(argument)
        if match:
            grants[match.group(1)] = match.group(2) == ":ro"
    return grants


class FlatpakForeignAppsTest(unittest.TestCase):
    def test_the_core_names_the_flatpak_apps_it_reads(self):
        self.assertTrue(
            {"io.dbeaver.DBeaverCommunity", "com.jetbrains.DataGrip"} <= searched_ids(),
            "the scan of the core's importers found none of the ids it should",
        )

    def test_each_manifest_reads_every_flatpak_app_the_core_searches_and_no_other(self):
        wanted = searched_ids()
        for manifest in MANIFESTS:
            with self.subTest(manifest=manifest.name):
                grants = granted(manifest)
                self.assertEqual(set(grants), wanted)
                writable = sorted(app for app, read_only in grants.items() if not read_only)
                self.assertEqual(writable, [], "another app's folder is granted for writing")


if __name__ == "__main__":
    unittest.main()
