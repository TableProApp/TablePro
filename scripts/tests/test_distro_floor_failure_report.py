import subprocess
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
REPORTER = ROOT / "scripts/report-gtk-failure.sh"


class DistroFloorFailureReportTests(unittest.TestCase):
    def run_reporter(self, command):
        with tempfile.TemporaryDirectory() as directory:
            log = Path(directory) / "gtk-safety.log"
            with log.open("w") as output:
                failure = subprocess.run(
                    ["bash", "-c", command],
                    stdout=output,
                    stderr=subprocess.STDOUT,
                    check=False,
                )
            result = subprocess.run(
                ["bash", str(REPORTER), str(log), str(failure.returncode)],
                capture_output=True,
                text=True,
                check=False,
            )
            return failure, result

    def test_unexpected_startup_failure_is_visible_and_preserves_status(self):
        failure, result = self.run_reporter("printf '%s\\n' 'GTK startup failed: display socket unavailable'; exit 17")

        self.assertEqual(failure.returncode, 17)
        self.assertEqual(result.returncode, 17)
        self.assertIn("GTK startup failed: display socket unavailable", result.stdout)

    def test_scenario_failure_summary_is_visible_and_preserves_status(self):
        failure, result = self.run_reporter("printf '%s\\n' 'FAILED: restart_restores_active_editor'; exit 17")

        self.assertEqual(failure.returncode, 17)
        self.assertEqual(result.returncode, 17)
        self.assertIn("FAILED: restart_restores_active_editor", result.stdout)

    def test_passed_summary_does_not_hide_an_unexpected_failure(self):
        failure, result = self.run_reporter("printf '%s\\n' 'passed: first_scenario' 'unexpected portal startup error'; exit 19")
        self.assertEqual(failure.returncode, 19)
        self.assertEqual(result.returncode, 19)
        self.assertIn("unexpected portal startup error", result.stdout)

    def test_empty_log_is_reported_and_preserves_status(self):
        failure, result = self.run_reporter("exit 17")

        self.assertEqual(failure.returncode, 17)
        self.assertEqual(result.returncode, 17)
        self.assertIn("GTK suite produced no output", result.stdout)


if __name__ == "__main__":
    unittest.main()
