import ast
import json
import os
from pathlib import Path
import shutil
import tempfile
import unittest
from unittest.mock import patch


class UiEvidenceTests(unittest.TestCase):
    def run_scenario(self, scenario, artifact_dir):
        source = Path(__file__).resolve().parents[2] / "crates/app/tests/gtk_safety.py"
        tree = ast.parse(source.read_text())
        function = next(node for node in tree.body if isinstance(node, ast.FunctionDef) and node.name == "run_scenario")
        namespace = dict(Path=Path, tempfile=tempfile, os=os, json=json, shutil=shutil)
        namespace.update(write_fixture=lambda *a, **k: (None, {}), start_application=lambda *a: object(),
                         open_editor=lambda: None, stop_application=lambda _: "fixture stderr",
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


if __name__ == "__main__":
    unittest.main()
