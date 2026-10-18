#!/usr/bin/env python3

import io
import json
import plistlib
import tempfile
import unittest
import zipfile
from contextlib import redirect_stderr, redirect_stdout
from pathlib import Path

import registry
import version

URL_BASE = "https://github.com/TableProApp/TablePro/releases/download/v0.82.0/"
PROJECT = """\
targets:
  OracleDriver:
    templates: [DriverPlugin]

aggregateTargets:
  BundledPlugins:
    targets:
      - MySQLDriver
      - SQLiteDriver

  RegistryPlugins:
    targets:
      - OracleDriver
      - ParquetExport
    scheme: {}
"""
METADATA = {
    "retainFromPluginKit": 39,
    "plugins": {
        "OracleDriver": {"name": "Oracle Driver", "iconName": "oracle-icon"},
        "ParquetExport": {"name": "Parquet Export", "iconName": "parquet-icon"},
    },
}


def entry(text="0.82.0", kit=39, system="13.0", sha="a", plugin="com.TablePro.OracleDriver", name="Oracle Driver"):
    return {
        "id": plugin, "name": name, "iconName": "oracle-icon", "databaseTypeIds": ["Oracle"],
        "version": text, "build": version.parse_version(text).build, "pluginKit": kit,
        "minimumSystemVersion": system, "file": f"OracleDriver-{text}.zip", "sha256": sha * 64,
    }


def select(manifest, plugin, channels, kit, system):
    def system_key(text):
        return tuple(int(part) for part in text.split("."))

    releases = next(entry["releases"] for entry in manifest["plugins"] if entry["id"] == plugin)
    eligible = [release for release in releases if release["channel"] in channels and release["pluginKit"] == kit
                and system_key(release["minimumSystemVersion"]) <= system_key(system)]
    return max(eligible, key=lambda release: release["build"])["version"] if eligible else None


class ManifestCase(unittest.TestCase):
    def setUp(self):
        directory = tempfile.TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        self.path = Path(directory.name) / "plugins" / "v3.json"
        self.log = []

    def add(self, entries, channel="stable", retain_from=39):
        return registry.add(self.path, entries, channel, URL_BASE, retain_from, self.log.append)

    def manifest(self):
        return json.loads(self.path.read_text(encoding="utf-8"))

    def builds(self, plugin="com.TablePro.OracleDriver"):
        return [release["build"] for entry in self.manifest()["plugins"] if entry["id"] == plugin
                for release in entry["releases"]]


class AddTests(ManifestCase):
    def test_creates_the_manifest_and_an_entry(self):
        self.assertTrue(self.add([entry()]))
        self.assertEqual(self.manifest(), {
            "schemaVersion": 3,
            "retainFromPluginKit": 39,
            "plugins": [{
                "id": "com.TablePro.OracleDriver", "name": "Oracle Driver", "iconName": "oracle-icon",
                "databaseTypeIds": ["Oracle"],
                "releases": [{
                    "version": "0.82.0", "build": 820099, "channel": "stable", "pluginKit": 39,
                    "minimumSystemVersion": "13.0", "url": URL_BASE + "OracleDriver-0.82.0.zip", "sha256": "a" * 64,
                }],
            }],
        })

    def test_a_rerun_is_a_no_op(self):
        self.add([entry()])
        written = self.path.read_bytes()
        self.assertFalse(self.add([entry()]))
        self.assertEqual(self.path.read_bytes(), written)

    def test_a_changed_sha256_for_the_same_build_is_an_error(self):
        self.add([entry()])
        with self.assertRaisesRegex(registry.RegistryError, "already has build 820099"):
            self.add([entry(sha="b")])

    def test_keeps_two_builds_per_channel_kit_and_system(self):
        for text in ("0.82.0", "0.82.1", "0.82.2"):
            self.add([entry(text)])
        self.assertEqual(self.builds(), [820299, 820199])

    def test_a_beta_goes_once_a_higher_stable_shares_its_kit_and_system(self):
        self.add([entry("0.82.0-beta.1")], channel="beta")
        self.add([entry("0.82.0-beta.2")], channel="beta")
        self.assertEqual(self.builds(), [820002, 820001])
        self.add([entry("0.82.0")])
        self.assertEqual(self.builds(), [820099])

    def test_a_beta_on_another_kit_survives_a_stable(self):
        self.add([entry("0.83.0-beta.1", kit=40)], channel="beta")
        self.add([entry("0.82.1")])
        self.assertEqual(self.builds(), [830001, 820199])

    def test_a_higher_minimum_system_keeps_the_older_build(self):
        self.add([entry("0.82.0")])
        self.add([entry("0.82.1", system="14.0")])
        self.add([entry("0.82.2", system="14.0")])
        self.assertEqual(self.builds(), [820299, 820199, 820099])
        manifest = self.manifest()
        self.assertEqual(select(manifest, "com.TablePro.OracleDriver", {"stable"}, 39, "13.5"), "0.82.0")
        self.assertEqual(select(manifest, "com.TablePro.OracleDriver", {"stable"}, 39, "14.1"), "0.82.2")

    def test_releases_below_the_floor_are_pruned(self):
        self.add([entry("0.82.0", kit=38)], retain_from=38)
        self.add([entry("0.83.0", kit=39)], retain_from=39)
        self.assertEqual(self.builds(), [830099])
        self.assertEqual(self.manifest()["retainFromPluginKit"], 39)

    def test_an_older_line_never_lowers_the_floor(self):
        self.add([entry("0.83.0", kit=40)], retain_from=40)
        self.add([entry("0.82.1", kit=40)], retain_from=39)
        self.assertEqual(self.manifest()["retainFromPluginKit"], 40)

    def test_a_release_pruned_on_arrival_is_a_logged_no_op(self):
        self.add([entry("0.83.0", kit=40)], retain_from=40)
        written = self.path.read_bytes()
        self.assertFalse(self.add([entry("0.82.1", kit=39)], retain_from=39))
        self.assertEqual(self.path.read_bytes(), written)
        self.assertIn("com.TablePro.OracleDriver 0.82.1: pruned on arrival by retention, not added", self.log)

    def test_metadata_comes_only_from_the_highest_build(self):
        newer = entry("0.83.0-beta.1", kit=40)
        newer["name"] = "Oracle"
        self.add([newer], channel="beta")
        older = entry("0.82.1")
        older["name"] = "Oracle Driver (old)"
        self.add([older])
        self.assertEqual(self.manifest()["plugins"][0]["name"], "Oracle")
        newest = entry("0.83.0", kit=40)
        newest["name"] = "Oracle Database"
        self.add([newest])
        self.assertEqual(self.manifest()["plugins"][0]["name"], "Oracle Database")

    def test_plugins_sort_by_id_and_releases_by_build(self):
        self.add([entry("0.82.0", plugin="com.TablePro.ZDriver"), entry("0.82.0", plugin="com.TablePro.ADriver")])
        self.add([entry("0.82.1", plugin="com.TablePro.ADriver")])
        manifest = self.manifest()
        self.assertEqual([plugin["id"] for plugin in manifest["plugins"]],
                         ["com.TablePro.ADriver", "com.TablePro.ZDriver"])
        self.assertEqual([release["build"] for release in manifest["plugins"][0]["releases"]], [820199, 820099])

    def test_another_schema_is_refused(self):
        self.path.parent.mkdir(parents=True)
        self.path.write_text(json.dumps({"schemaVersion": 4, "retainFromPluginKit": 39, "plugins": []}))
        with self.assertRaisesRegex(registry.RegistryError, "schemaVersion 4"):
            self.add([entry()])

    def test_a_build_that_is_not_the_versions_build_is_refused(self):
        wrong = entry()
        wrong["build"] = 140
        with self.assertRaisesRegex(registry.RegistryError, "build 140 is not 820099"):
            self.add([wrong])

    def test_a_version_on_the_wrong_channel_is_refused(self):
        with self.assertRaisesRegex(registry.RegistryError, "belongs to the beta channel"):
            self.add([entry("0.82.0-beta.1")], channel="stable")


class WithdrawTests(ManifestCase):
    def test_a_withdraw_brings_the_previous_build_back_into_selection(self):
        self.add([entry("0.82.0")])
        self.add([entry("0.82.1")])
        self.assertEqual(select(self.manifest(), "com.TablePro.OracleDriver", {"stable"}, 39, "26.0"), "0.82.1")
        self.assertTrue(registry.withdraw(self.path, "0.82.1", self.log.append))
        self.assertEqual(select(self.manifest(), "com.TablePro.OracleDriver", {"stable"}, 39, "26.0"), "0.82.0")

    def test_withdrawing_a_missing_version_changes_nothing(self):
        self.add([entry("0.82.0")])
        written = self.path.read_bytes()
        self.assertFalse(registry.withdraw(self.path, "0.82.5", self.log.append))
        self.assertEqual(self.path.read_bytes(), written)

    def test_a_plugin_left_with_no_release_leaves_the_manifest(self):
        self.add([entry("0.82.0")])
        registry.withdraw(self.path, "0.82.0", self.log.append)
        self.assertEqual(self.manifest()["plugins"], [])


class TargetsTests(unittest.TestCase):
    def test_reads_the_bundled_aggregate(self):
        self.assertEqual(registry.bundled_targets(PROJECT), {"MySQLDriver", "SQLiteDriver"})

    def test_reads_the_bundled_aggregate_of_this_repository(self):
        bundled = registry.bundled_targets(registry.PROJECT.read_text(encoding="utf-8"))
        self.assertIn("MySQLDriver", bundled)
        self.assertNotIn("OracleDriver", bundled)

    def test_prints_the_publish_set(self):
        with tempfile.TemporaryDirectory() as directory:
            metadata, project = Path(directory) / "registry.json", Path(directory) / "project.yml"
            metadata.write_text(json.dumps(METADATA))
            project.write_text(PROJECT)
            with redirect_stdout(io.StringIO()) as output:
                self.assertEqual(registry.main(["targets", "--metadata", str(metadata), "--project", str(project)]), 0)
        self.assertEqual(output.getvalue(), "OracleDriver\nParquetExport\n")

    def test_refuses_a_bundled_target(self):
        metadata = {"retainFromPluginKit": 39, "plugins": {**METADATA["plugins"],
                                                           "MySQLDriver": {"name": "MySQL", "iconName": "mysql"}}}
        with self.assertRaisesRegex(registry.RegistryError, "the app bundles MySQLDriver"):
            registry.publish_set(metadata, registry.bundled_targets(PROJECT))

    def test_refuses_metadata_in_another_shape(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "registry.json"
            path.write_text(json.dumps({"plugins": {"oracle": {"target": "OracleDriver"}}}))
            with self.assertRaisesRegex(registry.RegistryError, "shape"):
                registry.load_metadata(path)


class DescribeTests(unittest.TestCase):
    def setUp(self):
        directory = tempfile.TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        self.zips = Path(directory.name)

    def plugin(self, target, **overrides):
        info = {
            "CFBundleIdentifier": f"com.TablePro.{target}", "CFBundleShortVersionString": "0.82.0",
            "CFBundleVersion": "820099", "TableProPluginKitVersion": 39, "LSMinimumSystemVersion": "13.0",
            "TableProProvidesDatabaseTypeIds": ["Oracle"],
        }
        info.update(overrides)
        info = {key: value for key, value in info.items() if value is not None}
        path = self.zips / f"{target}-0.82.0.zip"
        with zipfile.ZipFile(path, "w") as archive:
            archive.writestr(f"{target}.tableplugin/Contents/Info.plist", plistlib.dumps(info))
            archive.writestr(f"{target}.tableplugin/Contents/MacOS/{target}", b"binary")
        return path

    def describe(self, metadata=None):
        return registry.describe(self.zips, "0.82.0", 820099, 39, metadata or METADATA,
                                 registry.bundled_targets(PROJECT))

    def test_reads_each_zip(self):
        self.plugin("OracleDriver")
        self.plugin("ParquetExport", CFBundleIdentifier="com.TablePro.ParquetExportPlugin",
                    TableProProvidesDatabaseTypeIds=None, TableProProvidesExportFormatIds=["parquet"])
        oracle, parquet = self.describe()
        self.assertEqual(oracle["id"], "com.TablePro.OracleDriver")
        self.assertEqual(oracle["databaseTypeIds"], ["Oracle"])
        self.assertEqual((oracle["version"], oracle["build"], oracle["pluginKit"], oracle["minimumSystemVersion"]),
                         ("0.82.0", 820099, 39, "13.0"))
        self.assertEqual(oracle["file"], "OracleDriver-0.82.0.zip")
        self.assertRegex(oracle["sha256"], "^[0-9a-f]{64}$")
        self.assertEqual((parquet["id"], parquet["databaseTypeIds"], parquet["name"]),
                         ("com.TablePro.ParquetExportPlugin", [], "Parquet Export"))

    def test_rejects_a_wrong_version_build_or_kit(self):
        cases = [
            ({"CFBundleShortVersionString": "0.81.0"}, "CFBundleShortVersionString is '0.81.0'"),
            ({"CFBundleVersion": "140"}, "CFBundleVersion is '140'"),
            ({"TableProPluginKitVersion": 38}, "TableProPluginKitVersion is 38"),
            ({"TableProPluginKitVersion": "39"}, "TableProPluginKitVersion is '39'"),
        ]
        self.plugin("ParquetExport", TableProProvidesExportFormatIds=["parquet"])
        for overrides, message in cases:
            with self.subTest(overrides=overrides):
                self.plugin("OracleDriver", **overrides)
                with self.assertRaisesRegex(registry.RegistryError, message):
                    self.describe()

    def test_rejects_a_plugin_that_provides_nothing(self):
        self.plugin("OracleDriver", TableProProvidesDatabaseTypeIds=None)
        self.plugin("ParquetExport", TableProProvidesExportFormatIds=["parquet"])
        with self.assertRaisesRegex(registry.RegistryError, "OracleDriver-0.82.0.zip: it declares none of"):
            self.describe()

    def test_rejects_a_missing_zip(self):
        self.plugin("OracleDriver")
        with self.assertRaisesRegex(registry.RegistryError, "ParquetExport-0.82.0.zip does not exist"):
            self.describe()

    def test_rejects_two_plugins_with_one_bundle_id(self):
        self.plugin("OracleDriver")
        self.plugin("ParquetExport", CFBundleIdentifier="com.TablePro.OracleDriver")
        with self.assertRaisesRegex(registry.RegistryError, "share the bundle id"):
            self.describe()

    def test_the_cli_writes_entries_that_add_reads(self):
        self.plugin("OracleDriver")
        self.plugin("ParquetExport", TableProProvidesExportFormatIds=["parquet"])
        metadata, project = self.zips / "registry.json", self.zips / "project.yml"
        metadata.write_text(json.dumps(METADATA))
        project.write_text(PROJECT)
        entries, manifest = self.zips / "entries.json", self.zips / "v3.json"
        with redirect_stdout(io.StringIO()), redirect_stderr(io.StringIO()):
            self.assertEqual(registry.main([
                "describe", "--zips", str(self.zips), "--version", "0.82.0", "--build", "820099", "--kit", "39",
                "--metadata", str(metadata), "--project", str(project), "--out", str(entries)]), 0)
            self.assertEqual(registry.main([
                "add", "--manifest", str(manifest), "--entries", str(entries), "--channel", "stable",
                "--url-base", URL_BASE, "--retain-from", "39"]), 0)
            self.assertEqual(registry.main(["withdraw", "--manifest", str(manifest), "--version", "0.82.0"]), 0)
        self.assertEqual(json.loads(manifest.read_text())["plugins"], [])


if __name__ == "__main__":
    unittest.main()
