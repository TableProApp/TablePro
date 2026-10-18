#!/usr/bin/env python3
"""Fixture tests for check-plugin-provides.py."""

import contextlib
import importlib.util
import io
import tempfile
import unittest
from pathlib import Path

SPEC = importlib.util.spec_from_file_location("check_plugin_provides", Path(__file__).with_name("check-plugin-provides.py"))
check = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(check)

HEADER = """<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
\t<key>TableProPluginKitVersion</key>
\t<integer>TABLEPRO_PLUGINKIT_VERSION</integer>
"""
FOOTER = "</dict>\n</plist>\n"

DRIVER = """import TableProPluginKit

final class ExamplePlugin: NSObject, TableProPlugin, DriverPlugin {
    public static let databaseTypeId = "Example"
    static let additionalDatabaseTypeIds: [String] = [
        "ExampleCloud",
        "ExampleLite"
    ]
}
"""

EXPORTER = """final class ExampleExportPlugin: ObservableObject, ExportFormatPlugin, SettablePlugin {
    static let formatId = "ex"
}
"""

ODD_DRIVER = "final class Odd: NSObject, DriverPlugin {\n    static var databaseTypeId: String { name }\n}\n"

IMPORTER = """final class ExampleImportPlugin: ObservableObject, ImportFormatPlugin {
    static let formatId = "ex"
}
"""


def provides(key, values):
    items = "".join(f"\t\t<string>{value}</string>\n" for value in values)
    return f"\t<key>{key}</key>\n\t<array>\n{items}\t</array>\n"


DRIVER_PLIST = HEADER + provides(check.DATABASE_KEY, ["Example", "ExampleCloud", "ExampleLite"]) + FOOTER


class CheckPluginProvidesTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.plugins = Path(self.temp.name)

    def tearDown(self):
        self.temp.cleanup()

    def plugin(self, name, swift, plist):
        directory = self.plugins / name
        (directory / "Sub").mkdir(parents=True)
        (directory / "Sub" / f"{name}.swift").write_text(swift, encoding="utf-8")
        (directory / "Info.plist").write_text(plist, encoding="utf-8")
        return directory

    def run_main(self, *argv):
        out, err = io.StringIO(), io.StringIO()
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
            code = check.main(["--plugins", str(self.plugins), *argv])
        return code, out.getvalue(), err.getvalue()

    def test_a_driver_lists_its_primary_id_first(self):
        directory = self.plugin("ExampleDriverPlugin", DRIVER, DRIVER_PLIST)
        self.assertEqual(check.problems_in(directory), [])

    def test_a_driver_with_no_keys_is_reported(self):
        directory = self.plugin("ExampleDriverPlugin", DRIVER, HEADER + FOOTER)
        problems = check.problems_in(directory)
        self.assertEqual(len(problems), 1)
        self.assertIn("has no TableProProvidesDatabaseTypeIds", problems[0])

    def test_a_missing_additional_id_is_reported(self):
        plist = HEADER + provides(check.DATABASE_KEY, ["Example", "ExampleCloud"]) + FOOTER
        directory = self.plugin("ExampleDriverPlugin", DRIVER, plist)
        self.assertEqual(len(check.problems_in(directory)), 1)

    def test_a_different_primary_id_is_reported(self):
        plist = HEADER + provides(check.DATABASE_KEY, ["ExampleCloud", "Example", "ExampleLite"]) + FOOTER
        directory = self.plugin("ExampleDriverPlugin", DRIVER, plist)
        self.assertEqual(len(check.problems_in(directory)), 1)

    def test_a_key_the_class_does_not_provide_is_reported(self):
        plist = DRIVER_PLIST.replace(FOOTER, provides(check.EXPORT_KEY, ["ex"]) + FOOTER)
        directory = self.plugin("ExampleDriverPlugin", DRIVER, plist)
        problems = check.problems_in(directory)
        self.assertEqual(len(problems), 1)
        self.assertIn("the class provides none", problems[0])

    def test_exporters_and_importers_use_their_own_keys(self):
        exporter = self.plugin("ExampleExportPlugin", EXPORTER, HEADER + provides(check.EXPORT_KEY, ["ex"]) + FOOTER)
        importer = self.plugin("ExampleImportPlugin", IMPORTER, HEADER + provides(check.IMPORT_KEY, ["ex"]) + FOOTER)
        swapped = self.plugin("SwappedImportPlugin", IMPORTER, HEADER + provides(check.EXPORT_KEY, ["ex"]) + FOOTER)
        self.assertEqual(check.problems_in(exporter), [])
        self.assertEqual(check.problems_in(importer), [])
        self.assertEqual(len(check.problems_in(swapped)), 2)

    def test_a_format_id_without_a_format_conformance_is_unreadable(self):
        swift = 'final class Odd: NSObject {\n    static let formatId = "ex"\n}\n'
        directory = self.plugin("OddPlugin", swift, HEADER + FOOTER)
        with self.assertRaisesRegex(check.Unreadable, "conforms to"):
            check.problems_in(directory)

    def test_a_class_with_no_literal_ids_is_unreadable(self):
        directory = self.plugin("OddDriverPlugin", ODD_DRIVER, HEADER + FOOTER)
        with self.assertRaisesRegex(check.Unreadable, "neither databaseTypeId nor formatId"):
            check.problems_in(directory)

    def test_two_primary_ids_are_unreadable(self):
        directory = self.plugin("ExampleDriverPlugin", DRIVER, DRIVER_PLIST)
        (directory / "Other.swift").write_text('enum Other {\n    static let databaseTypeId = "Other"\n}\n', encoding="utf-8")
        with self.assertRaisesRegex(check.Unreadable, "declares databaseTypeId 2 times"):
            check.problems_in(directory)

    def test_a_plist_that_does_not_parse_is_unreadable(self):
        directory = self.plugin("ExampleDriverPlugin", DRIVER, HEADER)
        with self.assertRaisesRegex(check.Unreadable, "does not parse"):
            check.problems_in(directory)

    def test_folders_without_an_info_plist_are_not_plugins(self):
        self.plugin("ExampleDriverPlugin", DRIVER, DRIVER_PLIST)
        (self.plugins / "Shared").mkdir()
        (self.plugins / "Shared" / "Helper.swift").write_text("enum Helper {}\n", encoding="utf-8")
        code, out, _ = self.run_main()
        self.assertEqual(code, 0)
        self.assertIn("1 plugin Info.plists", out)

    def test_main_fails_and_names_the_fix(self):
        self.plugin("ExampleDriverPlugin", DRIVER, HEADER + FOOTER)
        code, _, err = self.run_main()
        self.assertEqual(code, 1)
        self.assertIn("::error::ExampleDriverPlugin", err)
        self.assertIn("--write", err)

    def test_main_fails_on_an_unreadable_plugin_without_offering_write(self):
        self.plugin("OddDriverPlugin", ODD_DRIVER, HEADER + FOOTER)
        code, _, err = self.run_main()
        self.assertEqual(code, 1)
        self.assertIn("::error::OddDriverPlugin: declares neither", err)
        self.assertNotIn("--write", err)

    def test_write_stamps_the_keys_in_the_source_format_and_keeps_the_macro(self):
        driver = self.plugin("ExampleDriverPlugin", DRIVER, HEADER + provides(check.EXPORT_KEY, ["stale"]) + FOOTER)
        self.assertEqual(self.run_main("--write")[0], 0)
        self.assertEqual((driver / "Info.plist").read_text(encoding="utf-8"), DRIVER_PLIST)
        self.assertEqual(self.run_main()[0], 0)

    def test_write_fails_on_an_unreadable_plugin_and_leaves_its_plist(self):
        odd = self.plugin("OddDriverPlugin", ODD_DRIVER, HEADER + FOOTER)
        driver = self.plugin("ExampleDriverPlugin", DRIVER, HEADER + FOOTER)
        code, out, err = self.run_main("--write")
        self.assertEqual(code, 1)
        self.assertEqual(out, "stamped ExampleDriverPlugin/Info.plist\n")
        self.assertIn("::error::OddDriverPlugin: declares neither", err)
        self.assertEqual((odd / "Info.plist").read_text(encoding="utf-8"), HEADER + FOOTER)
        self.assertEqual((driver / "Info.plist").read_text(encoding="utf-8"), DRIVER_PLIST)

    def test_write_leaves_a_correct_plist_untouched(self):
        exporter = self.plugin("ExampleExportPlugin", EXPORTER, HEADER + provides(check.EXPORT_KEY, ["ex"]) + "\n" + FOOTER)
        before = (exporter / "Info.plist").read_text(encoding="utf-8")
        self.run_main("--write")
        self.assertEqual((exporter / "Info.plist").read_text(encoding="utf-8"), before)

    def test_an_empty_plugins_folder_fails(self):
        with self.assertRaises(SystemExit):
            self.run_main()


if __name__ == "__main__":
    unittest.main()
