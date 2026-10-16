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
        self.assertTrue(checker.check(metadata))

    def test_headless_crates_refuse_gui_dependencies_of_every_kind(self):
        for source in ("tablepro-core", "tablepro-app-services", "tablepro-driver-postgres"):
            for kind in (None, "build", "dev"):
                with self.subTest(source=source, kind=kind):
                    metadata = graph(BASE, ["gtk4"], [(source, "gtk4", kind)])
                    self.assertTrue(checker.check(metadata))

    def test_a_dev_dependency_cannot_reach_gui_through_its_build_dependencies(self):
        metadata = graph(
            BASE,
            ["helper", "glib"],
            [("tablepro-app-services", "helper", "dev"), ("helper", "glib", "build")],
        )
        self.assertTrue(checker.check(metadata))

    def test_a_permitted_workspace_dev_dependency_cannot_reach_gui(self):
        metadata = graph(
            BASE,
            ["gtk4"],
            [("tablepro-driver-postgres", "tablepro-policy", "dev"), ("tablepro-policy", "gtk4", None)],
        )
        problems = checker.check(metadata)
        self.assertTrue(any("tablepro-driver-postgres" in problem for problem in problems))

    def test_an_external_dependency_does_not_compile_its_own_dev_dependencies(self):
        for kind in (None, "build", "dev"):
            with self.subTest(kind=kind):
                metadata = graph(
                    BASE,
                    ["helper", "gtk4"],
                    [("tablepro-app-services", "helper", kind), ("helper", "gtk4", "dev")],
                )
                self.assertEqual(checker.check(metadata), [])

    def test_a_workspace_dependency_does_not_compile_its_own_tests_for_its_consumer(self):
        metadata = graph(
            BASE,
            ["helper", "glib"],
            [("tablepro-driver-postgres", "tablepro-policy", "dev"), ("tablepro-policy", "helper", None),
             ("helper", "glib", "dev")],
        )
        self.assertEqual(checker.check(metadata), [])

    def test_the_application_may_use_gui_in_each_dependency_kind(self):
        for kind in (None, "build", "dev"):
            with self.subTest(kind=kind):
                metadata = graph(BASE, ["gtk4"], [("tablepro-app", "gtk4", kind)])
                self.assertEqual(checker.check(metadata), [])

    def test_gui_reachability_handles_repeated_edges_and_cycles(self):
        metadata = graph(
            BASE,
            ["helper", "other", "gtk4"],
            [("tablepro-app-services", "helper", "dev"), ("tablepro-app-services", "helper", None),
             ("helper", "other", None), ("other", "helper", "build"), ("other", "gtk4", None)],
        )
        problems = checker.check(metadata)
        self.assertEqual(len(problems), 1)
        self.assertIn("tablepro-app-services", problems[0])


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
