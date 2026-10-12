#!/usr/bin/env python3
"""Fixture tests for check-hub-ratchet.py."""

from __future__ import annotations

import importlib.util
import io
import json
import shutil
import sys
import tempfile
import unittest
from contextlib import redirect_stdout
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location("check_hub_ratchet", Path(__file__).with_name("check-hub-ratchet.py"))
ratchet = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(ratchet)

MINIMAL_TREE = {
    "TablePro/Infrastructure/MainSplitViewController+MenuValidation.swift": (
        "struct MenuValidationContext: Equatable {\n"
        "    var isConnected = false\n"
        "}\n\n"
        "extension MainSplitViewController {\n"
        "    static func resolved(_ selector: Selector) -> Bool? {\n"
        "        switch selector {\n"
        "        case #selector(refresh(_:)),\n"
        "             #selector(close(_:)):\n"
        "            return true\n"
        "        default:\n"
        "            return nil\n"
        "        }\n"
        "    }\n"
        "}\n"
    ),
    "TablePro/Models/KeyboardShortcutModels.swift": "enum ShortcutAction: String {\n    case newConnection\n}\n",
    "TablePro/Models/QueryTabState.swift": "enum TabType: Codable {\n    case query\n}\n",
    "TablePro/Views/SettingsView.swift": "enum SettingsPane: String {\n    case general\n}\n",
    "TablePro/Views/MainContentCoordinator.swift": "enum ActiveSheet {\n    case sqlPreview\n}\n",
    "TablePro/Core/LaunchIntent.swift": "enum LaunchIntent {\n    case openConnection(UUID)\n}\n",
    "TablePro/Views/MainContentCoordinator+Rewind.swift": "extension MainContentCoordinator {}\n",
    "TablePro/Views/MainContentCoordinator+TabRestore.swift": "extension MainContentCoordinator {}\n",
    "TablePro/AppDelegate.swift": (
        "class AppDelegate: NSObject {\n"
        "    func start() {\n"
        "        SoftwareUpdater.shared.start()\n"
        "        SoftwareUpdater.shared.check()\n"
        "        NSApp.activate()\n"
        "    }\n"
        "}\n\n"
        "private struct NotificationDelivery {}\n"
    ),
    "TablePro/Core/SoftwareUpdater.swift": "final class SoftwareUpdater {}\n",
    "TablePro/Core/Unused.swift": "final class NotNamedByAppDelegate {}\n",
    "TablePro/Core/Dashboard/MySQLDashboardProvider.swift": "struct MySQLDashboardProvider {}\n",
}


class Fixture(unittest.TestCase):
    def setUp(self) -> None:
        self.root = Path(tempfile.mkdtemp())
        (self.root / ".github").mkdir()
        for path, text in MINIMAL_TREE.items():
            self.write(path, text)

    def tearDown(self) -> None:
        shutil.rmtree(self.root)

    def write(self, path: str, text: str) -> None:
        target = self.root / path
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text(text, encoding="utf-8")

    def run_check(self, **options: bool) -> tuple[int, str]:
        output = io.StringIO()
        with redirect_stdout(output):
            status = ratchet.run(self.root, **options)
        return status, output.getvalue()

    def counts(self) -> dict[str, int]:
        return ratchet.measure(self.root)


class LexerTests(unittest.TestCase):
    def test_comments_and_strings_are_blanked_and_newlines_kept(self) -> None:
        source = (
            'let a = "}{ \\(items.map { "}" }) {"\n'
            'let b = #"a "}" b"#\n'
            'let c = """\n    }\n    """\n'
            "/* outer /* inner } */ { */\n"
            "// case hidden, also\n"
            "struct Kept {}\n"
        )
        code = ratchet.blank_literals(source)
        self.assertEqual(code.count("\n"), source.count("\n"))
        self.assertEqual(code.count("{"), 1)
        self.assertEqual(code.count("}"), 1)
        self.assertIn("struct Kept {}", code)
        self.assertNotIn("case", code)

    def test_enum_cases_count_names_not_lines(self) -> None:
        body = ratchet.blank_literals(
            "\n"
            "    case a, b, c\n"
            "    case d(x: Int, y: String)\n"
            "    case e(\n"
            "        first: Int,\n"
            "        second: String\n"
            "    )\n"
            '    case f = "g, h"\n'
            "    // case commented, out\n"
            "    var title: String {\n"
            "        switch self {\n"
            "        case .a, .b: return \"\"\n"
            "        default: return \"\"\n"
            "        }\n"
            "    }\n"
            "    enum Nested {\n"
            "        case inner\n"
            "    }\n"
        )
        self.assertEqual(ratchet.enum_case_count(body), 6)

    def test_stored_properties_skip_computed_static_and_locals(self) -> None:
        body = ratchet.blank_literals(
            "\n"
            "    var a = false\n"
            "    var b: Int?\n"
            "    let c: String\n"
            "    private(set) var d = 0\n"
            "    @Published var e = 1\n"
            "    nonisolated(unsafe) var f = 0\n"
            "    var g = 0 {\n"
            "        didSet { a = true }\n"
            "    }\n"
            "    var h = 0, i = false\n"
            "    var j: [String: Int] = [:], k: Dictionary<String, Int> = [:]\n"
            "    let l = { 1 }()\n"
            "    var m: () -> Void = {}\n"
            "    var n = items\n"
            "        .filter { $0 > 1 }\n"
            "    var computed: Bool { a && c.isEmpty }\n"
            "    var getter: Int {\n"
            "        get { 1 }\n"
            "    }\n"
            "    var braceOnNextLine: Bool\n"
            "    {\n"
            "        a\n"
            "    }\n"
            "    static let shared = 1\n"
            '    let text = "var notAProperty = 1"\n'
            "    func work() {\n"
            "        var local = 0\n"
            "        let other = 1\n"
            "    }\n"
        )
        self.assertEqual(ratchet.stored_property_count(body), 15)

    def test_module_and_engine_words_match_at_camel_case_boundaries(self) -> None:
        for suffix in ("AIQueryActions", "AgentPanes", "AIConversations", "HighlightRules", "Redis", "ERDiagram"):
            self.assertTrue(ratchet.names_module(suffix), suffix)
        for suffix in ("TabRestore", "MAINMenu", "Charter", "TabSwitch", "Explain", "Favorites"):
            self.assertFalse(ratchet.names_module(suffix), suffix)


class MeasureTests(Fixture):
    def test_the_minimal_tree_is_counted(self) -> None:
        counts = self.counts()
        self.assertEqual(counts["MenuValidationContext stored properties"], 1)
        self.assertEqual(counts["menu validation `case #selector` arms"], 1)
        self.assertEqual(counts["TabType cases"], 1)
        self.assertEqual(counts["shell extensions named for a module or engine"], 1)
        self.assertEqual(counts["MainContentCoordinator+ files"], 2)
        self.assertEqual(counts["app types AppDelegate names"], 1)
        self.assertEqual(counts["files under TablePro/ named for MySQL"], 1)
        self.assertEqual(counts["files under TablePro/ named for SQLite"], 0)

    def test_selector_arms_outside_the_main_split_view_controller_are_not_counted(self) -> None:
        self.write(
            "TablePro/Views/WelcomeWindowController.swift",
            "func validate(_ s: Selector) -> Bool {\n    switch s {\n    case #selector(open(_:)): return true\n"
            "    default: return false\n    }\n}\n",
        )
        self.assertEqual(self.counts()["menu validation `case #selector` arms"], 1)

    def test_a_nested_namesake_is_not_the_hub(self) -> None:
        self.write(
            "TablePro/ViewModels/UsersRolesViewModel.swift",
            "final class UsersRolesViewModel {\n    enum ActiveSheet {\n        case one, two, three\n    }\n}\n",
        )
        self.assertEqual(self.counts()["ActiveSheet cases"], 1)

    def test_a_feature_extension_on_any_shell_type_counts(self) -> None:
        self.write("TablePro/Infrastructure/MainSplitViewController+DataFiles.swift", "extension MainSplitViewController {}\n")
        self.write("TablePro/Views/MainContentCommandActions+Focus.swift", "extension MainContentCommandActions {}\n")
        self.assertEqual(self.counts()["shell extensions named for a module or engine"], 2)

    def test_postgresql_server_version_is_not_a_sql_server_file(self) -> None:
        self.write("TablePro/Core/PostgreSQLServerVersion.swift", "struct PostgreSQLServerVersion {}\n")
        self.write("TablePro/Core/AutocommitOnlyStatement+SQLServer.swift", "extension AutocommitOnlyStatement {}\n")
        counts = self.counts()
        self.assertEqual(counts["files under TablePro/ named for PostgreSQL"], 1)
        self.assertEqual(counts["files under TablePro/ named for SQL Server"], 1)

    def test_a_missing_hub_declaration_fails_loudly(self) -> None:
        (self.root / "TablePro/Models/QueryTabState.swift").unlink()
        status, output = self.run_check()
        self.assertEqual(status, 1)
        self.assertIn("expected one top-level `enum TabType`", output)


class RatchetTests(Fixture):
    def test_a_grown_count_fails_and_a_lower_one_passes(self) -> None:
        self.assertEqual(self.run_check(update=True)[0], 0)
        self.assertEqual(self.run_check(), (0, ""))

        self.write("TablePro/Models/QueryTabState.swift", "enum TabType: Codable {\n    case query, table\n}\n")
        status, output = self.run_check()
        self.assertEqual(status, 1)
        self.assertIn("FAIL: TabType cases: 2, up from 1", output)
        self.assertIn("may only go down", output)

        self.write("TablePro/Models/QueryTabState.swift", "enum TabType: Codable {\n    case query\n}\n")
        (self.root / "TablePro/Views/MainContentCoordinator+Rewind.swift").unlink()
        status, output = self.run_check()
        self.assertEqual(status, 0)
        self.assertIn("lower: MainContentCoordinator+ files: 1, down from 2", output)
        self.assertIn("--update", output)

    def test_update_lowers_the_baseline_and_never_raises_it(self) -> None:
        self.assertEqual(self.run_check(update=True)[0], 0)
        self.write("TablePro/Models/QueryTabState.swift", "enum TabType: Codable {\n    case query, table\n}\n")
        (self.root / "TablePro/Views/MainContentCoordinator+Rewind.swift").unlink()
        self.assertEqual(self.run_check(update=True)[0], 0)
        baseline = json.loads((self.root / ratchet.BASELINE).read_text(encoding="utf-8"))
        self.assertEqual(baseline["TabType cases"], 1)
        self.assertEqual(baseline["MainContentCoordinator+ files"], 1)
        self.assertEqual(self.run_check()[0], 1)

    def test_a_count_without_a_baseline_entry_and_a_stale_entry_both_fail(self) -> None:
        failures, lowered = ratchet.compare({"gone": 1, "kept": 2}, {"kept": 2, "new": 0})
        self.assertEqual(lowered, [])
        self.assertEqual(len(failures), 2)
        self.assertTrue(any(line.startswith("new:") for line in failures))
        self.assertTrue(any(line.startswith("gone:") for line in failures))


class RepositoryTests(unittest.TestCase):
    def test_the_repository_is_within_its_baseline(self) -> None:
        output = io.StringIO()
        with redirect_stdout(output):
            status = ratchet.run(ROOT)
        self.assertEqual(status, 0, output.getvalue())


if __name__ == "__main__":
    sys.exit(unittest.main())
