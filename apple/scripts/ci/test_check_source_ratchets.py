#!/usr/bin/env python3
"""Fixture tests for check-source-ratchets.py."""

import contextlib
import importlib.util
import io
import json
import tempfile
import unittest
from pathlib import Path

SPEC = importlib.util.spec_from_file_location(
    "check_source_ratchets", Path(__file__).with_name("check-source-ratchets.py")
)
check = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(check)

DATABASE_TYPE = '''struct DatabaseType {
    let rawValue: String
}

extension DatabaseType {
    static let mysql = DatabaseType(rawValue: "MySQL")
    static let mssql = DatabaseType(rawValue: "SQL Server")
    static let kafka = DatabaseType(rawValue: "Kafka")
}
'''

COMPARISONS = '''if type == .mysql {}
if type != DatabaseType.mssql {}
let isKafka = type ==
    .kafka
if type == .mysqlFork {}
if type === .mysql {}
'''

CASE_LISTS = '''switch type {
case .mysql,
     .mssql:
    break
case .kafka where flag:
    break
case DatabaseType.mysql:
    break
case .other, .some(.mysql):
    break
default:
    break
}
if case .kafka = type {}
let known = [.mysql].contains(type)
'''

LITERALS = '''if name == "MySQL" {}
if "SQL Server" != name {}
switch name {
case "Kafka",
     "Other":
    break
default:
    break
}
connect("MySQL")
if name == "MySQL \\(suffix)" {}
'''

HIDDEN = '''// if type == .mysql {}
/* outer /* inner */ type == .mysql */
let a = "type == .mysql"
let b = "\\(f("x)")) == .mysql"
let c = #"raw "== .mysql" case .kafka:"#
let d = """
    case .mysql:
    """
let e = #""""#
if type == .kafka {}
'''

SINGLETONS = '''let a = DatabaseManager.shared
let b = PluginManager.shared.plugins
let c = AppSettingsManager.shared
let d = DatabaseManager.sharedInstance
let e = MyDatabaseManager.shared
// DatabaseManager.shared
let f = "PluginManager.shared"
'''


class CheckSourceRatchetsTests(unittest.TestCase):
    def setUp(self):
        folder = tempfile.TemporaryDirectory()
        self.addCleanup(folder.cleanup)
        self.apple = Path(folder.name) / "apple"
        self.write("TablePro/Models/Connection/DatabaseType.swift", DATABASE_TYPE)
        (self.apple / "scripts/ci").mkdir(parents=True)

    def write(self, relative, text):
        path = self.apple / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text, encoding="utf-8")

    def run_check(self, *args):
        output = io.StringIO()
        with contextlib.redirect_stdout(output):
            status = check.main(["--apple", str(self.apple), *args])
        return status, output.getvalue()

    def listed(self, ratchet):
        status, output = self.run_check("--list")
        self.assertEqual(status, 0)
        return [line.split(f": {ratchet}: ")[1] for line in output.splitlines() if f": {ratchet}: " in line]

    def engines(self, source):
        self.write("TablePro/Core/Example.swift", source)
        return self.listed("engine-name-comparisons")

    def baseline(self, engines, singletons):
        self.write(
            "scripts/ci/source-ratchets.json",
            json.dumps({"engine-name-comparisons": engines, "view-singleton-reads": singletons}),
        )

    def test_comparisons_count(self):
        self.assertEqual(self.engines(COMPARISONS), ["== .mysql", "!= DatabaseType.mssql", "== .kafka"])

    def test_case_list_items_count(self):
        self.assertEqual(
            self.engines(CASE_LISTS),
            ["case .mysql", "case .mssql", "case .kafka", "case DatabaseType.mysql", "case .kafka"],
        )

    def test_raw_value_literals_count_beside_a_comparison_or_in_a_case_list(self):
        self.assertEqual(self.engines(LITERALS), ['== "MySQL"', '"SQL Server" !=', 'case "Kafka"'])

    def test_comments_and_strings_are_skipped(self):
        self.assertEqual(self.engines(HIDDEN), ["== .kafka"])

    def test_an_interpolation_is_code(self):
        source = 'let a = "\\(type == .mysql ? "x" : "y")"\nlet b = Text("Open \\(PluginManager.shared.name)")\n'
        self.assertEqual(self.engines(source), ["== .mysql"])
        self.write("TablePro/Views/Example.swift", source)
        self.assertEqual(self.listed("view-singleton-reads"), ["PluginManager.shared"])

    def test_list_names_the_file_and_line(self):
        self.write("TablePro/Core/Example.swift", "\nif type == .mysql {}\n")
        _, output = self.run_check("--list")
        self.assertEqual(output, "apple/TablePro/Core/Example.swift:2: engine-name-comparisons: == .mysql\n")

    def test_singletons_count_only_in_views_and_view_models(self):
        for folder in ("Views/Main", "ViewModels", "Core"):
            self.write(f"TablePro/{folder}/Example.swift", SINGLETONS)
        found = self.listed("view-singleton-reads")
        self.assertEqual(len(found), 6)
        self.assertEqual(found[:3], ["DatabaseManager.shared", "PluginManager.shared", "AppSettingsManager.shared"])

    def test_a_rise_fails(self):
        self.write("TablePro/Core/Example.swift", "if type == .mysql {}\n")
        self.baseline(0, 0)
        status, output = self.run_check()
        self.assertEqual(status, 1)
        self.assertIn("engine-name-comparisons: 1 (baseline 0)", output)
        self.assertIn("::error::engine-name-comparisons rose from 0 to 1.", output)

    def test_an_equal_count_passes(self):
        self.write("TablePro/Views/Example.swift", "if type == .mysql { DatabaseManager.shared }\n")
        self.baseline(1, 1)
        status, output = self.run_check()
        self.assertEqual(status, 0)
        self.assertNotIn("::", output)

    def test_a_fall_passes_with_a_notice(self):
        self.baseline(2, 0)
        status, output = self.run_check()
        self.assertEqual(status, 0)
        self.assertIn("::notice::engine-name-comparisons fell from 2 to 0.", output)

    def test_a_missing_ratchet_fails(self):
        self.write("scripts/ci/source-ratchets.json", json.dumps({"engine-name-comparisons": 0}))
        status, output = self.run_check()
        self.assertEqual(status, 1)
        self.assertIn("::error::", output)
        self.assertIn("view-singleton-reads", output)

    def test_no_engine_names_fails(self):
        self.write("TablePro/Models/Connection/DatabaseType.swift", "struct DatabaseType {}\n")
        self.baseline(0, 0)
        status, output = self.run_check()
        self.assertEqual(status, 1)
        self.assertIn("::error::", output)

    def test_write_records_the_counts(self):
        self.write("TablePro/Views/Example.swift", "if type == .mysql { DatabaseManager.shared }\n")
        status, _ = self.run_check("--write")
        self.assertEqual(status, 0)
        self.assertEqual(
            (self.apple / "scripts/ci/source-ratchets.json").read_text(encoding="utf-8"),
            '{\n  "engine-name-comparisons": 1,\n  "view-singleton-reads": 1\n}\n',
        )


if __name__ == "__main__":
    unittest.main()
