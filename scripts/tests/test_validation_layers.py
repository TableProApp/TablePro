import importlib.util
import json
from pathlib import Path
import re
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location("layers", ROOT / "scripts/run-test-layer.py")
runner = importlib.util.module_from_spec(spec)
spec.loader.exec_module(runner)


class LayerRunnerTests(unittest.TestCase):
    def step(self, code, evidence="exit", timeout=5):
        return {"argv": [sys.executable, "-c", code], "evidence": evidence, "timeout_seconds": timeout}

    def execute(self, step):
        with tempfile.TemporaryDirectory() as temporary:
            return runner.execute(step, Path(temporary) / "step.log")

    def test_catalog_has_real_entrypoints_and_unique_steps(self):
        for name, layer in runner.catalog().items():
            self.assertTrue(layer["purpose"] and layer["prerequisites"] and layer["hosted_gate"], name)
            for step in layer["steps"]:
                for arg in step["argv"]:
                    if arg.startswith("scripts/"):
                        self.assertTrue((ROOT / arg).exists(), arg)

    def test_nonzero_exit_cannot_be_hidden_by_success_text(self):
        result = self.execute(self.step("print('test result: ok. 1 passed; 0 failed;'); raise SystemExit(7)", "rust-tests"))
        self.assertEqual(result["status"], "failed")
        self.assertEqual(result["exit_code"], 7)

    def test_missing_and_zero_rust_test_execution_fail(self):
        for output in ["", "test result: ok. 0 passed; 0 failed; 9 ignored;", "test result: FAILED. 1 passed; 1 failed;"]:
            self.assertFalse(runner.execution_evidence("rust-tests", output))
        self.assertEqual(self.execute(self.step("pass", "rust-tests"))["status"], "failed")

    def test_success_requires_a_nonempty_matching_summary(self):
        self.assertTrue(runner.execution_evidence("rust-tests", "test result: ok. 3 passed; 0 failed; 1 ignored;"))
        self.assertTrue(runner.execution_evidence("python-tests", "Ran 3 tests in 0.01s\n\nOK\n"))
        self.assertFalse(runner.execution_evidence("python-tests", "Ran 0 tests in 0.01s\n\nOK\n"))
        self.assertFalse(runner.execution_evidence("python-tests", "Ran 3 tests in 0.01s\n\nOK (skipped=1)\n"))

    def test_timeout_and_missing_executable_fail_explicitly(self):
        self.assertEqual(self.execute(self.step("import time; time.sleep(60)", timeout=0.05))["status"], "timed_out")
        step = {"argv": ["/missing/bookie-fixture"], "evidence": "exit", "timeout_seconds": 1}
        self.assertEqual(self.execute(step)["status"], "blocked")
        step = dict(self.step("pass"), required_tools=["bookie-missing-prerequisite"])
        self.assertEqual(self.execute(step)["status"], "blocked")

    def test_interruption_is_not_passed(self):
        with patch.object(runner.subprocess, "Popen", side_effect=KeyboardInterrupt):
            self.assertEqual(self.execute(self.step("pass"))["status"], "cancelled")

    def test_failure_keeps_later_layer_evidence(self):
        with tempfile.TemporaryDirectory() as temporary, patch.object(runner, "capture", return_value="fixture"):
            directory = Path(temporary) / "evidence"
            layers = {"bad": {"steps": [self.step("raise SystemExit(9)")]}, "good": {"steps": [self.step("print('done')")]}}
            self.assertEqual(runner.run_layers(list(layers), layers, directory), 1)
            report = json.loads((directory / "report.json").read_text())
            self.assertEqual(report["status"], "failed")
            self.assertEqual(report["layers"]["good"]["status"], "passed")
            self.assertEqual((directory / "good-1.log").read_text().strip(), "done")

    def test_unknown_duplicate_and_empty_selection_fail(self):
        for args in [[], ["missing"], ["harness", "harness"]]:
            result = subprocess.run([sys.executable, str(ROOT / "scripts/run-test-layer.py"), *args], capture_output=True)
            self.assertEqual(result.returncode, 2)

    def test_cancelled_run_marks_later_steps_not_run(self):
        with tempfile.TemporaryDirectory() as temporary, patch.object(runner, "capture", return_value="fixture"):
            directory = Path(temporary) / "evidence"
            layers = {"cancel": {"steps": [self.step("pass"), self.step("pass")]}}
            with patch.object(runner, "execute", return_value={"status": "cancelled"}) as execute:
                self.assertEqual(runner.run_layers(["cancel"], layers, directory), 1)
            self.assertEqual(execute.call_count, 1)
            report = json.loads((directory / "report.json").read_text())
            self.assertEqual(report["layers"]["cancel"]["steps"][1]["status"], "not_run")

    def test_every_script_test_is_discovered_or_explicitly_run(self):
        commands = runner.catalog()["harness"]["steps"] + runner.catalog()["packaging-contracts"]["steps"]
        explicit = {arg for step in commands for arg in step["argv"]}
        for path in (ROOT / "scripts/tests").glob("test_*.py"):
            self.assertTrue("unittest.TestCase" in path.read_text() or f"scripts/tests/{path.name}" in explicit, path.name)

    def test_app_support_fixture_inventory_uses_its_library_test_target(self):
        result = subprocess.run(
            [sys.executable, str(ROOT / "scripts/inventory-ignored-tests.py")],
            capture_output=True,
            text=True,
            check=True,
        )
        self.assertIn("../crates/app/tests/support/value_parse.rs)", result.stdout)
        self.assertIn("value_contract_mongodb_decimal128_grid_edit_preserves_wide_precision", result.stdout)
        self.assertIn("App server", result.stdout)

    def test_linux_workflows_are_all_registered_for_lint(self):
        workflows = ROOT / ".github/workflows"
        expected = {f".github/workflows/{path.name}" for path in workflows.glob("*linux*.yml")}
        expected.add(".github/workflows/gtk-soak.yml")
        selected = set(runner.catalog()["workflow-lint"]["steps"][0]["argv"][1:])
        self.assertEqual(selected, expected)

    def test_busy_checkout_refuses_a_second_runner(self):
        with tempfile.TemporaryDirectory() as temporary, patch.object(runner, "ROOT", Path(temporary)):
            with patch.object(runner, "catalog", return_value={"fixture": {}}), patch.object(sys, "argv", ["runner", "fixture"]):
                with patch.object(runner.fcntl, "flock", side_effect=BlockingIOError), patch.object(runner, "run_layers") as run:
                    with self.assertRaises(SystemExit) as error:
                        runner.main()
                    self.assertEqual(error.exception.code, 2)
                    run.assert_not_called()

    def test_security_and_contract_workflows_use_shared_runner(self):
        workflows = ROOT / ".github/workflows"
        security = (workflows / "linux-security.yml").read_text()
        for text in ["security-policy", "supply-chain", "fail-fast: false", "if: always()", "if-no-files-found: error", "run-test-layer.py"]:
            self.assertIn(text, security)
        self.assertNotIn("continue-on-error:", security)
        build = (workflows / "build-linux.yml").read_text()
        for layer in ["quick", "full", "drivers", "b4-rollback", "tls", "postgres-release", "ui", "widgets", "keyring"]:
            self.assertIn(f"run-test-layer.py {layer}", build)
        self.assertNotIn("if-no-files-found: ignore", build)
        contracts = (workflows / "linux-ci-contracts.yml").read_text()
        self.assertIn("run-test-layer.py harness", contracts)
        for script in ["preflight.sh", "ci-local.sh"]:
            self.assertIn("scripts/test-harness.sh", (ROOT / "scripts" / script).read_text())

    def test_driver_layer_timeout_fits_hosted_integration_job(self):
        workflow = (ROOT / ".github/workflows/build-linux.yml").read_text()
        integration = re.search(r"(?ms)^  integration:\n(.*?)(?=^  [a-z][a-z-]*:\n)", workflow)
        self.assertIsNotNone(integration)
        job_timeout = re.search(r"(?m)^    timeout-minutes:\s+(\d+)$", integration.group(1))
        self.assertIsNotNone(job_timeout)
        layer_timeout = runner.catalog()["drivers"]["steps"][0]["timeout_seconds"]
        self.assertGreaterEqual(int(job_timeout.group(1)) * 60, layer_timeout + 300)

    def test_local_scripts_run_every_script_test(self):
        harness = (ROOT / "scripts/test-harness.sh").read_text()
        self.assertIn("unittest discover -s scripts/tests", harness)
        for path in (ROOT / "scripts/tests").glob("test_*.py"):
            if "unittest.TestCase" not in path.read_text():
                self.assertIn(f"scripts/tests/{path.name}", harness)

    def test_layer_steps_own_the_evidence_report(self):
        step = self.step("import os; raise SystemExit(os.environ.get('BOOKIE_CI_REPORT_ACTIVE') != '1')")
        self.assertEqual(self.execute(step)["status"], "passed")


if __name__ == "__main__":
    unittest.main()
