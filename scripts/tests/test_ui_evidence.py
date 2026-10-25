import ast
import json
import os
from pathlib import Path
import shutil
import tempfile
import unittest
from unittest.mock import patch


class UiEvidenceTests(unittest.TestCase):
    def run_scenario(self, scenario, artifact_dir, stderr="fixture stderr", shutdown_error=None):
        source = Path(__file__).resolve().parents[2] / "apps/linux/app/tests/gtk_safety.py"
        tree = ast.parse(source.read_text())
        function = next(node for node in tree.body if isinstance(node, ast.FunctionDef) and node.name == "run_scenario")
        def write_fixture(base, **_):
            self.fixture_base = base
            self.addCleanup(shutil.rmtree, base, ignore_errors=True)
            return None, {}

        def stop_application(_):
            if shutdown_error is not None:
                raise AssertionError(shutdown_error)
            return stderr

        namespace = dict(Path=Path, tempfile=tempfile, os=os, json=json, shutil=shutil)
        namespace.update(write_fixture=write_fixture, start_application=lambda *a: object(),
                         open_editor=lambda: None, stop_application=stop_application,
                         accessible_snapshot=lambda: "fixture accessibility")
        exec(compile(ast.Module(body=[function], type_ignores=[]), str(source), "exec"), namespace)
        with patch.dict(os.environ, {"TABLEPRO_GTK_ARTIFACT_DIR": str(artifact_dir)}), patch.object(shutil, "which", return_value=None):
            namespace["run_scenario"]("fixture-binary", scenario)

    def test_successful_scenario_creates_uploadable_evidence(self):
        def successful(*_):
            pass
        with tempfile.TemporaryDirectory() as root:
            directory = Path(root) / "artifacts"
            self.run_scenario(successful, directory)
            report = json.loads((directory / "successful-result.json").read_text())
            self.assertEqual(report, {"scenario": "successful", "status": "passed", "error": None})
            self.assertEqual((directory / "successful-stderr.txt").read_text(), "fixture stderr")

    def test_failed_scenario_keeps_failure_and_diagnostics(self):
        def failing(*_):
            raise ValueError("fixture failure")
        with tempfile.TemporaryDirectory() as root:
            directory = Path(root) / "artifacts"
            with self.assertRaisesRegex(AssertionError, "fixture failure"):
                self.run_scenario(failing, directory)
            report = json.loads((directory / "failing-result.json").read_text())
            self.assertEqual(report["status"], "failed")
            self.assertEqual(report["error"], "fixture failure")
            self.assertEqual((directory / "failing-accessibility.txt").read_text(), "fixture accessibility")


    def test_layout_failure_after_the_body_cannot_leave_a_passed_artifact(self):
        def successful(*_):
            pass
        warning = "a window does not have a minimum size"
        with tempfile.TemporaryDirectory() as root:
            directory = Path(root) / "artifacts"
            with self.assertRaises(AssertionError):
                self.run_scenario(successful, directory, stderr=warning)
            report = json.loads((directory / "successful-result.json").read_text())
            self.assertEqual(report["status"], "failed")
            self.assertTrue(report["error"])
            self.assertEqual((directory / "successful-stderr.txt").read_text(), warning)
            self.assertFalse(self.fixture_base.exists())

    def test_shutdown_failure_is_saved_and_scratch_data_is_removed(self):
        def successful(*_):
            pass
        with tempfile.TemporaryDirectory() as root:
            directory = Path(root) / "artifacts"
            with self.assertRaises(AssertionError):
                self.run_scenario(successful, directory, shutdown_error="application exited with 7: shutdown failure")
            report = json.loads((directory / "successful-result.json").read_text())
            self.assertEqual(report["status"], "failed")
            self.assertIn("shutdown failure", report["error"])
            self.assertIn("shutdown failure", (directory / "successful-stderr.txt").read_text())
            self.assertFalse(self.fixture_base.exists())

    def test_a_shutdown_failure_keeps_the_original_scenario_failure(self):
        def failing(*_):
            raise ValueError("scenario failure")
        with tempfile.TemporaryDirectory() as root:
            directory = Path(root) / "artifacts"
            with self.assertRaises(AssertionError):
                self.run_scenario(failing, directory, shutdown_error="shutdown failure")
            report = json.loads((directory / "failing-result.json").read_text())
            self.assertEqual(report["status"], "failed")
            self.assertEqual(report["error"], "scenario failure")
            self.assertIn("shutdown failure", (directory / "failing-stderr.txt").read_text())
            self.assertFalse(self.fixture_base.exists())


if __name__ == "__main__":
    unittest.main()
