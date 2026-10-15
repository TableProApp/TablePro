import importlib.util
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location("check_crate_boundaries", ROOT / "scripts/check-crate-boundaries.py")
checker = importlib.util.module_from_spec(spec)
spec.loader.exec_module(checker)


def graph(workspace, external, edges):
    ids = {name: f"{name} 0.1.0" for name in [*workspace, *external]}
    deps = {name: [] for name in ids}
    for source, target, kind in edges:
        deps[source].append({"pkg": ids[target], "dep_kinds": [{"kind": kind}]})
    return {
        "workspace_members": [ids[name] for name in workspace],
        "packages": [{"id": ids[name], "name": name} for name in ids],
        "resolve": {"nodes": [{"id": ids[name], "deps": deps[name]} for name in ids]},
    }


BASE = ["tablepro-core", "tablepro-policy", "tablepro-driver-postgres", "tablepro-app-services", "tablepro-app"]


class CrateBoundaryTests(unittest.TestCase):
    def test_the_documented_direction_passes(self):
        metadata = graph(
            BASE,
            ["gtk4"],
            [
                ("tablepro-policy", "tablepro-core", None),
                ("tablepro-driver-postgres", "tablepro-core", None),
                ("tablepro-app-services", "tablepro-core", None),
                ("tablepro-app", "tablepro-app-services", None),
                ("tablepro-app", "gtk4", None),
            ],
        )
        self.assertEqual(checker.check(metadata), [])

    def test_a_gui_crate_reached_through_another_crate_is_refused(self):
        metadata = graph(
            BASE,
            ["relm4", "glib"],
            [("tablepro-app-services", "relm4", None), ("relm4", "glib", None)],
        )
        problems = checker.check(metadata)
        self.assertTrue(any("tablepro-app-services" in problem and "glib" in problem for problem in problems), problems)

    def test_a_driver_may_not_depend_on_policy_except_in_tests(self):
        normal = graph(BASE, [], [("tablepro-driver-postgres", "tablepro-policy", None)])
        self.assertTrue(checker.check(normal))
        development = graph(BASE, [], [("tablepro-driver-postgres", "tablepro-policy", "dev")])
        self.assertEqual(checker.check(development), [])

    def test_no_crate_may_depend_on_the_application(self):
        for kind in (None, "dev"):
            metadata = graph(BASE, [], [("tablepro-policy", "tablepro-app", kind)])
            self.assertTrue(checker.check(metadata), kind)

    def test_core_depends_on_no_workspace_crate(self):
        metadata = graph(BASE, [], [("tablepro-core", "tablepro-policy", None)])
        self.assertTrue(checker.check(metadata))

    def test_a_new_workspace_crate_must_be_classified(self):
        metadata = graph([*BASE, "tablepro-newcomer"], [], [])
        problems = checker.check(metadata)
        self.assertTrue(any("tablepro-newcomer" in problem for problem in problems), problems)

    def test_an_external_crate_cannot_hide_a_forbidden_edge_behind_a_dev_dependency(self):
        metadata = graph(BASE, ["gtk4"], [("tablepro-core", "gtk4", "dev")])
        self.assertEqual(checker.check(metadata), [])


class PreflightListTests(unittest.TestCase):
    SCRIPT = "CRATES=(\n  tablepro-core\n  tablepro-policy\n)\n"

    def test_a_workspace_crate_missing_from_the_preflight_list_is_reported(self):
        metadata = graph(["tablepro-core", "tablepro-policy", "tablepro-app-services"], [], [])
        problems = checker.unlisted_in_preflight(metadata, self.SCRIPT)
        self.assertEqual(problems, ["tablepro-app-services is missing from CRATES in scripts/preflight.sh"])

    def test_the_application_and_the_optional_duckdb_driver_are_exempt(self):
        metadata = graph(["tablepro-core", "tablepro-policy", "tablepro-app", "tablepro-driver-duckdb"], [], [])
        self.assertEqual(checker.unlisted_in_preflight(metadata, self.SCRIPT), [])


if __name__ == "__main__":
    unittest.main()
