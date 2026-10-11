import importlib.util
from pathlib import Path
import unittest
import tempfile
import sys
from unittest.mock import patch

path = Path(__file__).resolve().parents[1] / "test-value-contracts.py"
sys.path.insert(0, str(path.parent))
spec = importlib.util.spec_from_file_location("value_runner", path)
runner = importlib.util.module_from_spec(spec)
spec.loader.exec_module(runner)

cleanup_path = Path(__file__).resolve().parents[1] / "cleanup-testcontainers.py"
cleanup_spec = importlib.util.spec_from_file_location("cleanup_testcontainers", cleanup_path)
cleanup_runner = importlib.util.module_from_spec(cleanup_spec)
cleanup_spec.loader.exec_module(cleanup_runner)


class ValueRunnerTests(unittest.TestCase):
    def test_all_drivers_have_required_suites(self):
        suites = runner.expected_suites(gtk=True, duckdb=True)
        self.assertEqual(sum(target == "integration" for target in suites.values()), 8)
        self.assertEqual(len(suites), 11)

    def test_build_selection_is_explicit_and_locked(self):
        self.assertIn("--locked", runner.build_command())
        self.assertIn("tablepro-app", runner.build_command())
        self.assertIn("tablepro-driver-duckdb", runner.build_command())
        self.assertNotIn("--exclude", runner.build_command(gtk=True, duckdb=True))

    def test_combined_gtk_duckdb_run_enables_app_duckdb_consumer_tests(self):
        command = runner.build_command(gtk=True, duckdb=True)
        self.assertIn("tablepro-app/duckdb", command)
        self.assertNotIn("tablepro-app/duckdb", runner.build_command(gtk=True))
        self.assertNotIn("tablepro-app/duckdb", runner.build_command(duckdb=True))

    def test_a_suite_with_no_matching_tests_is_a_failure(self):
        with tempfile.TemporaryDirectory() as root:
            directory = Path(root)
            executable = directory / "empty-suite"
            executable.write_text("#!/bin/sh\nexit 0\n")
            executable.chmod(0o755)
            result = runner.run_suite("crates/core/Cargo.toml", str(executable), directory)
            self.assertEqual(result["tests"], 0)
            self.assertNotEqual(result["exit_code"], 0)

    def test_a_timed_out_suite_is_reported_as_failure(self):
        listed = runner.subprocess.CompletedProcess([], 0, "value_contract_case: test\n", "")
        expired = runner.subprocess.TimeoutExpired("fixture", runner.SUITE_TIMEOUT_SECONDS)
        with tempfile.TemporaryDirectory() as root, patch.object(runner.subprocess, "run", side_effect=[listed, expired]):
            result = runner.run_suite("crates/core/Cargo.toml", "/tmp/fixture", Path(root))
            self.assertEqual(result["tests"], 1)
            self.assertEqual(result["exit_code"], 124)

    def test_only_expected_test_executables_are_selected(self):
        message = {"reason": "compiler-artifact", "executable": "/tmp/test", "manifest_path": str(runner.ROOT / "crates/core/Cargo.toml"), "target": {"name": "tablepro_core"}, "profile": {"test": True}}
        self.assertEqual(runner.select_artifact(message, runner.expected_suites()), ("crates/core/Cargo.toml", "/tmp/test"))
        message["profile"]["test"] = False
        self.assertIsNone(runner.select_artifact(message, runner.expected_suites()))

    def test_shared_container_cleanup_removes_only_the_run_label(self):
        with patch.object(cleanup_runner.subprocess, "run") as run:
            run.return_value.stdout = "one\ntwo\n"
            cleanup_runner.cleanup("run-123")
        self.assertEqual(run.call_count, 2)
        self.assertEqual(run.call_args_list[0].args[0], [
            "docker", "ps", "-aq", "--filter", "label=com.tablepro.test-run=run-123"
        ])
        self.assertEqual(run.call_args_list[1].args[0], ["docker", "rm", "-f", "one", "two"])

    def test_shared_container_cleanup_does_not_remove_other_runs(self):
        with patch.object(cleanup_runner.subprocess, "run") as run:
            run.return_value.stdout = ""
            cleanup_runner.cleanup("run-123")
        run.assert_called_once()

    def test_success_requires_every_listed_test_to_pass(self):
        listed = runner.subprocess.CompletedProcess([], 0, "value_contract_case: test\n", "")
        for output in ["", "test result: ok. 0 passed; 0 failed; 0 ignored; 0 measured; 0 filtered out\n",
                       "test result: ok. 0 passed; 0 failed; 1 ignored; 0 measured; 0 filtered out\n",
                       "test value_contract_other ... ok\ntest result: ok. 1 passed; 0 failed; 0 ignored; 0 measured; 0 filtered out\n"]:
            def execute(*args, **kwargs):
                kwargs["stdout"].write(output)
                return runner.subprocess.CompletedProcess([], 0)
            with self.subTest(output=output), tempfile.TemporaryDirectory() as root:
                with patch.object(runner.subprocess, "run") as run:
                    run.side_effect = lambda *args, **kwargs: listed if "capture_output" in kwargs else execute(*args, **kwargs)
                    result = runner.run_suite("crates/core/Cargo.toml", "/tmp/fixture", Path(root))
                self.assertNotEqual(result["exit_code"], 0)

    def test_completed_test_names_and_summary_must_agree(self):
        output = "test value_contract_case ... ok\ntest result: ok. 1 passed; 0 failed; 0 ignored; 0 measured; 12 filtered out\n"
        self.assertTrue(runner.completed_tests(output, ["value_contract_case"]))
        self.assertFalse(runner.completed_tests(output + output, ["value_contract_case"]))
        self.assertFalse(runner.completed_tests(output, ["value_contract_case", "value_contract_missing"]))
        self.assertFalse(runner.completed_tests(
            "test result: ok. 0 passed; 0 failed; 0 ignored; 0 measured; 0 filtered out\n", []))
        duplicate = "test value_contract_case ... ok\n" * 2 + "test result: ok. 2 passed; 0 failed; 0 ignored; 0 measured; 0 filtered out\n"
        self.assertFalse(runner.completed_tests(duplicate, ["value_contract_case"] * 2))

    def test_nonzero_exit_is_never_overridden_by_success_output(self):
        listed = runner.subprocess.CompletedProcess([], 0, "value_contract_case: test\n", "")
        def execute(*args, **kwargs):
            if "capture_output" in kwargs:
                return listed
            kwargs["stdout"].write("test value_contract_case ... ok\ntest result: ok. 1 passed; 0 failed; 0 ignored; 0 measured; 0 filtered out\n")
            return runner.subprocess.CompletedProcess([], 101)
        with tempfile.TemporaryDirectory() as root, patch.object(runner.subprocess, "run", side_effect=execute):
            result = runner.run_suite("crates/core/Cargo.toml", "/tmp/fixture", Path(root))
            self.assertEqual(result["exit_code"], 101)


if __name__ == "__main__":
    unittest.main()
