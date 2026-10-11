import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
NAME = json.loads((ROOT / "isolated-tests.json").read_text())["gtk"][0][2]
SUMMARY = "test result: ok. 1 passed; 0 failed; 0 ignored; 0 measured; 0 filtered out\n"


class IsolatedRunnerTests(unittest.TestCase):
    def run_fixture(self, output, status=0, diagnostic=""):
        with tempfile.TemporaryDirectory() as directory:
            cargo = Path(directory) / "cargo"
            cargo.write_text(
                "#!/usr/bin/python3\nimport os, sys\n"
                "name = sys.argv[sys.argv.index('--exact') + 1]\n"
                "print(os.environ['FIXTURE_OUTPUT'].replace('__MATCH__', name))\n"
                "print(os.environ['FIXTURE_DIAGNOSTIC'], file=sys.stderr)\n"
                "sys.exit(int(os.environ['FIXTURE_STATUS']))\n"
            )
            cargo.chmod(0o755)
            return subprocess.run(
                ["/usr/bin/python3", str(ROOT / "run-isolated-tests.py"), "gtk"],
                env=os.environ | {"PATH": directory, "FIXTURE_OUTPUT": output, "FIXTURE_STATUS": str(status), "FIXTURE_DIAGNOSTIC": diagnostic},
                capture_output=True, text=True,
            )

    def test_wrong_test_name_cannot_satisfy_a_registered_test(self):
        result = self.run_fixture("test wrong::test ... ok\n" + SUMMARY)
        self.assertNotEqual(result.returncode, 0)

    def test_duplicate_summaries_cannot_satisfy_a_registered_test(self):
        result = self.run_fixture(f"test {NAME} ... ok\n" + SUMMARY + SUMMARY)
        self.assertNotEqual(result.returncode, 0)

    def test_ignored_tests_cannot_satisfy_a_registered_test(self):
        result = self.run_fixture(f"test {NAME} ... ok\n" + SUMMARY.replace("0 ignored", "1 ignored"))
        self.assertNotEqual(result.returncode, 0)

    def test_nonzero_exit_with_valid_output_still_fails(self):
        result = self.run_fixture(f"test {NAME} ... ok\n" + SUMMARY, 101)
        self.assertNotEqual(result.returncode, 0)

    def test_every_registered_name_must_execute(self):
        result = self.run_fixture(f"test {NAME} ... ok\n" + SUMMARY)
        self.assertNotEqual(result.returncode, 0)

    def test_all_registered_tests_with_matching_names_pass(self):
        result = self.run_fixture("test __MATCH__ ... ok\n" + SUMMARY)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_stderr_diagnostics_do_not_change_test_execution_evidence(self):
        result = self.run_fixture("test __MATCH__ ... ok\n" + SUMMARY, diagnostic="test result: FAILED. diagnostic only")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("diagnostic only", result.stderr)


if __name__ == "__main__":
    unittest.main()
