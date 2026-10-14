#!/usr/bin/env python3
"""Fixture tests for check-test-plans.py."""

from __future__ import annotations

import importlib.util
import json
import subprocess
import tempfile
import unittest
from pathlib import Path
from unittest import mock

SPEC = importlib.util.spec_from_file_location("check_test_plans", Path(__file__).with_name("check-test-plans.py"))
check = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(check)

PROJECT = """name: App

targetTemplates:
  PluginTests:
    type: bundle.unit-test
    platform: macOS
  Linkage:
    settings: {}

targets:
  App:
    type: application
  # a comment between entries
  AppTests:
    type: bundle.unit-test
    sources:
      - AppTests
  AppUITests:
    type: bundle.ui-testing
  helper-tool:
    type: tool
  DriverTests:
    templates: [PluginTests, Linkage]
  FormatTests:
    templates:
      - Linkage
      - PluginTests
    sources:
      - FormatTests

schemes:
  App:
    test:
      config: Debug
"""

PACKAGES = {
    "Kit": '.testTarget(name: "KitTests", dependencies: ["Kit"])\n// .testTarget(name: "RetiredTests")',
    "TableProCore": '.testTarget(\n    name: "CoreTypesTests"\n)',
    "TableProOracle": '.testTarget(name: "OracleCoreTests")',
}

UNIT = [
    ("AppTests", "container:TablePro.xcodeproj"),
    ("DriverTests", "container:TablePro.xcodeproj"),
    ("FormatTests", "container:TablePro.xcodeproj"),
    ("KitTests", "container:Packages/Kit"),
]
UI = [("AppUITests", "container:TablePro.xcodeproj")]
DIRECTORIES = ["AppTests", "AppUITests", "Plugins/DriverTests", "FormatTests"]


def plan(entries: list[tuple[str, str]], extra: dict[str, dict] | None = None) -> str:
    return json.dumps({"testTargets": [
        {"target": {"containerPath": path, "name": name}, **(extra or {}).get(name, {})} for name, path in entries
    ]})


class CheckTestPlansTests(unittest.TestCase):
    def problems(self, unit=UNIT, ui=UI, packages=None, directories=DIRECTORIES, extra=None) -> list[str]:
        with tempfile.TemporaryDirectory() as work:
            root = Path(work)
            subprocess.run(["git", "init", "--quiet", str(root)], check=True, capture_output=True)
            for directory in directories:
                (root / directory).mkdir(parents=True)
                (root / directory / "SomeTests.swift").write_text("")
            (root / "project.yml").write_text(PROJECT)
            for name, manifest in (packages if packages is not None else PACKAGES).items():
                (root / "Packages" / name).mkdir(parents=True)
                (root / "Packages" / name / "Package.swift").write_text(manifest)
            (root / "TestPlans").mkdir()
            (root / "TestPlans/Unit.xctestplan").write_text(plan(unit, extra))
            (root / "TestPlans/UI.xctestplan").write_text(plan(ui, extra))
            with mock.patch.object(check, "ROOT", root):
                return check.problems()

    def test_complete_plans_pass(self) -> None:
        self.assertEqual(self.problems(), [])

    def test_a_target_typed_by_a_template_is_required(self) -> None:
        self.assertEqual(
            self.problems(unit=[entry for entry in UNIT if entry[0] != "FormatTests"]),
            ["TestPlans/Unit.xctestplan: missing FormatTests, so it never runs"],
        )

    def test_an_app_test_target_missing_from_its_plan_fails(self) -> None:
        self.assertEqual(
            self.problems(unit=UNIT[1:]),
            ["TestPlans/Unit.xctestplan: missing AppTests, so it never runs"],
        )

    def test_a_ui_test_target_missing_from_its_plan_fails(self) -> None:
        self.assertEqual(self.problems(ui=[]), ["TestPlans/UI.xctestplan: missing AppUITests, so it never runs"])

    def test_a_package_test_target_missing_from_the_unit_plan_fails(self) -> None:
        self.assertEqual(
            self.problems(unit=UNIT[:-1]),
            ["TestPlans/Unit.xctestplan: missing KitTests, so it never runs"],
        )

    def test_a_package_added_later_must_join_the_unit_plan(self) -> None:
        packages = dict(PACKAGES, TableProMacCore='.testTarget(name: "MacCoreTests")')
        self.assertEqual(
            self.problems(packages=packages),
            ["TestPlans/Unit.xctestplan: missing MacCoreTests, so it never runs"],
        )
        self.assertEqual(
            self.problems(unit=UNIT + [("MacCoreTests", "container:Packages/TableProMacCore")], packages=packages),
            [],
        )

    def test_swift_test_packages_stay_out_of_the_plan(self) -> None:
        self.assertEqual(
            self.problems(unit=UNIT + [("CoreTypesTests", "container:Packages/TableProCore")]),
            ["TestPlans/Unit.xctestplan: CoreTypesTests runs under swift test with TableProCore, remove it"],
        )

    def test_a_plan_entry_for_a_deleted_target_fails(self) -> None:
        self.assertEqual(
            self.problems(unit=UNIT + [("GoneTests", "container:TablePro.xcodeproj")]),
            ["TestPlans/Unit.xctestplan: no such target GoneTests"],
        )

    def test_a_commented_out_package_test_target_is_not_a_target(self) -> None:
        self.assertEqual(
            self.problems(unit=UNIT + [("RetiredTests", "container:Packages/Kit")]),
            ["TestPlans/Unit.xctestplan: no such target RetiredTests"],
        )

    def test_a_target_in_the_wrong_plan_fails(self) -> None:
        self.assertEqual(
            self.problems(ui=UI + [("AppTests", "container:TablePro.xcodeproj")]),
            ["TestPlans/UI.xctestplan: AppTests belongs in TestPlans/Unit.xctestplan"],
        )

    def test_a_wrong_container_fails(self) -> None:
        unit = UNIT[:-1] + [("KitTests", "container:Packages/Other")]
        self.assertEqual(
            self.problems(unit=unit),
            ["TestPlans/Unit.xctestplan: KitTests has containerPath container:Packages/Other, expected container:Packages/Kit"],
        )

    def test_a_target_listed_twice_fails(self) -> None:
        self.assertEqual(
            self.problems(unit=UNIT + UNIT[:1]),
            ["TestPlans/Unit.xctestplan: AppTests is listed more than once"],
        )

    def test_a_project_target_needs_a_directory_of_its_own_name(self) -> None:
        directories = [d for d in DIRECTORIES if d != "Plugins/DriverTests"] + ["Plugins/DriverPluginTests"]
        self.assertEqual(
            self.problems(directories=directories),
            ["TestPlans/Unit.xctestplan: DriverTests has no directory named DriverTests, so verify.sh cannot find its tests"],
        )

    def test_a_disabled_entry_fails(self) -> None:
        self.assertEqual(
            self.problems(extra={"KitTests": {"enabled": False}}),
            ["TestPlans/Unit.xctestplan: KitTests is disabled, so it never runs"],
        )

    def test_skipped_tests_in_the_plan_fail(self) -> None:
        self.assertEqual(
            self.problems(extra={"AppTests": {"skippedTests": ["SlowTests"]}}),
            ["TestPlans/Unit.xctestplan: AppTests skips tests in the plan; mark known failures in code"],
        )

    def test_selected_tests_in_the_plan_fail(self) -> None:
        self.assertEqual(
            self.problems(extra={"AppUITests": {"selectedTests": ["LaunchTests"]}}),
            ["TestPlans/UI.xctestplan: AppUITests runs only its selectedTests"],
        )

    def test_main_exits_non_zero_on_a_problem(self) -> None:
        with mock.patch.object(check, "problems", return_value=["x"]), mock.patch("sys.stderr"):
            self.assertEqual(check.main(), 1)
        with mock.patch.object(check, "problems", return_value=[]):
            self.assertEqual(check.main(), 0)


if __name__ == "__main__":
    unittest.main()
