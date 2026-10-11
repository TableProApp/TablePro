import copy
import importlib.util
from pathlib import Path
import unittest
import sys

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))
SPEC = importlib.util.spec_from_file_location("run_change_contract_tests", ROOT / "run-change-contract-tests.py")
CHECKER = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(CHECKER)


class ChangeContractTests(unittest.TestCase):
    def test_exact_test_map_rejects_a_stale_rust_function_name(self):
        data = copy.deepcopy(CHECKER.load_map())
        data["exact_tests"]["crates/core/src/sql_dialect.rs"]["tests"][0] = (
            "sql_dialect::tests::postgres_text_array_updates_cast_through_text_to_a_builtin_array_type"
        )
        with self.assertRaisesRegex(ValueError, "exact-test selector has no Rust function"):
            CHECKER.validate_exact_test_names(data)

    def test_row_edit_source_maps_to_its_required_regressions(self):
        actions = CHECKER.select_actions(["crates/app/src/ui/browse_tab/row_ops.rs"], CHECKER.load_map())
        self.assertEqual(len(actions), 1)
        self.assertEqual(actions[0]["package"], "tablepro-app")
        self.assertEqual(actions[0]["target"], "--lib")
        self.assertFalse(actions[0]["full_suite"])
        self.assertEqual(len(actions[0]["required_tests"]), 4)

    def test_clickhouse_source_maps_to_shape_regressions(self):
        data = CHECKER.load_map()
        actions = CHECKER.select_actions(["crates/drivers/clickhouse/src/lib.rs"], data)
        self.assertEqual(len(actions), 1)
        self.assertEqual(actions[0]["package"], "tablepro-driver-clickhouse")
        self.assertEqual(actions[0]["target"], "--lib")
        self.assertEqual(
            actions[0]["required_tests"],
            sorted(data["exact_tests"]["crates/drivers/clickhouse/src/lib.rs"]["tests"]),
        )

    def test_json_export_path_maps_to_its_exact_value_contracts(self):
        actions = CHECKER.select_actions(["crates/core/src/export/json.rs"], CHECKER.load_map())
        self.assertEqual(len(actions), 1)
        self.assertFalse(actions[0]["full_suite"])
        self.assertIn(
            "export::json::tests::value_contract_single_row_json_export_preserves_value_types",
            actions[0]["required_tests"],
        )

    def test_stream_export_path_maps_to_its_exact_value_contracts(self):
        actions = CHECKER.select_actions(["crates/core/src/export/stream_tests.rs"], CHECKER.load_map())
        self.assertEqual(len(actions), 1)
        self.assertFalse(actions[0]["full_suite"])
        self.assertEqual(
            actions[0]["required_tests"],
            sorted(CHECKER.load_map()["exact_tests"]["crates/core/src/export/stream_tests.rs"]["tests"]),
        )

    def test_extended_temporal_path_maps_to_its_exact_value_contracts(self):
        actions = CHECKER.select_actions(
            ["crates/core/src/import/extended_temporal.rs"], CHECKER.load_map()
        )
        self.assertEqual(len(actions), 1)
        self.assertFalse(actions[0]["full_suite"])
        self.assertEqual(
            actions[0]["required_tests"],
            sorted(
                CHECKER.load_map()["exact_tests"]["crates/core/src/import/extended_temporal.rs"]["tests"]
            ),
        )

    def test_other_value_path_maps_to_its_package_suite(self):
        actions = CHECKER.select_actions(["crates/core/src/value.rs"], CHECKER.load_map())
        self.assertEqual(actions, [{
            "package": "tablepro-core",
            "target": "--lib",
            "full_suite": True,
            "required_tests": [],
        }])

    def test_driver_integration_test_files_stay_in_the_docker_layer(self):
        actions = CHECKER.select_actions(["crates/drivers/mysql/tests/integration.rs"], CHECKER.load_map())
        self.assertEqual(actions, [])

    def test_exact_app_integration_regression_selects_only_its_test_target(self):
        actions = CHECKER.select_actions(["crates/app/tests/stale_grid_update.rs"], CHECKER.load_map())
        self.assertEqual(len(actions), 1)
        self.assertEqual(actions[0]["target"], "--test=stale_grid_update")
        self.assertEqual(actions[0]["required_tests"], [
            "stale_sqlite_grid_update_rolls_back_the_batch_and_preserves_the_original_value"
        ])

    def test_git_paths_are_normalized_to_the_linux_workspace(self):
        self.assertEqual(CHECKER.workspace_relative("crates/core/src/query.rs", "linux/"),
                         "crates/core/src/query.rs")
        self.assertEqual(CHECKER.workspace_relative(".github/workflows/build-linux.yml", "linux/"),
                         ".github/workflows/build-linux.yml")

    def test_test_summary_requires_a_passing_test_and_no_failures(self):
        valid = "test result: ok. 2 passed; 0 failed; 0 ignored; 8 filtered out\n"
        self.assertTrue(CHECKER.rust_test_evidence(valid))
        self.assertFalse(CHECKER.rust_test_evidence("test result: ok. 0 passed; 0 failed; 0 ignored\n"))
        self.assertFalse(CHECKER.rust_test_evidence("test result: FAILED. 1 passed; 1 failed; 0 ignored\n"))

    def test_exact_regression_must_appear_once_in_passed_output(self):
        name = "module::regression"
        valid = f"test {name} ... ok\ntest result: ok. 1 passed; 0 failed; 0 ignored; 0 measured; 0 filtered out\n"
        self.assertTrue(CHECKER.exact_test_evidence(valid, name))
        self.assertFalse(CHECKER.exact_test_evidence("test result: ok. 1 passed; 0 failed; 0 ignored\n", name))
        duplicate = f"test {name} ... ok\ntest {name} ... ok\ntest result: ok. 2 passed; 0 failed; 0 ignored\n"
        self.assertFalse(CHECKER.exact_test_evidence(duplicate, name))

    def test_exact_regression_rejects_ignored_measured_and_multiple_summaries(self):
        name = "module::regression"
        line = f"test {name} ... ok\n"
        for summary in [
            "test result: ok. 1 passed; 0 failed; 1 ignored; 0 measured; 0 filtered out\n",
            "test result: ok. 1 passed; 0 failed; 0 ignored; 1 measured; 0 filtered out\n",
            "test result: ok. 1 passed; 0 failed; 0 ignored; 0 measured; 0 filtered out\n"
            "test result: ok. 0 passed; 0 failed; 0 ignored; 0 measured; 0 filtered out\n",
        ]:
            with self.subTest(summary=summary):
                self.assertFalse(CHECKER.exact_test_evidence(line + summary, name))
