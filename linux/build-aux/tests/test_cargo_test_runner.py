import os
import subprocess
import tempfile
import unittest
from pathlib import Path

SCRIPT = Path(__file__).resolve().parent.parent / "cargo-test-runner.sh"


class CargoTestRunnerTest(unittest.TestCase):
    def run_test(self, mode, package, crate):
        with tempfile.TemporaryDirectory() as directory:
            ran = Path(directory) / "ran"
            test = Path(directory) / "a test"
            test.write_text(f"#!/bin/sh\nprintf '%s\\n' \"$@\" > '{ran}'\n")
            test.chmod(0o755)
            env = dict(os.environ)
            env.pop("CARGO_PKG_NAME", None)
            if crate is not None:
                env["CARGO_PKG_NAME"] = crate
            result = subprocess.run(
                ["sh", str(SCRIPT), mode, package, str(test), "--exact", "a filter"],
                check=False,
                capture_output=True,
                text=True,
                env=env,
            )
            arguments = ran.read_text().splitlines() if ran.exists() else None
            return result, arguments

    def test_only_runs_the_package_with_its_arguments(self):
        result, arguments = self.run_test("only", "tablepro", "tablepro")

        self.assertEqual(result.returncode, 0)
        self.assertEqual(arguments, ["--exact", "a filter"])

    def test_only_passes_over_another_package(self):
        result, arguments = self.run_test("only", "tablepro", "tablepro-core")

        self.assertEqual(result.returncode, 0)
        self.assertIsNone(arguments)

    def test_skip_passes_over_the_package(self):
        result, arguments = self.run_test("skip", "tablepro", "tablepro")

        self.assertEqual(result.returncode, 0)
        self.assertIsNone(arguments)

    def test_skip_runs_another_package(self):
        result, arguments = self.run_test("skip", "tablepro", "tablepro-core")

        self.assertEqual(result.returncode, 0)
        self.assertEqual(arguments, ["--exact", "a filter"])

    def test_a_run_outside_cargo_fails(self):
        result, arguments = self.run_test("only", "tablepro", None)

        self.assertNotEqual(result.returncode, 0)
        self.assertIsNone(arguments)

    def test_an_unknown_mode_is_refused(self):
        result, arguments = self.run_test("some", "tablepro", "tablepro")

        self.assertEqual(result.returncode, 2)
        self.assertIn("usage", result.stderr)
        self.assertIsNone(arguments)

    def test_a_failing_test_fails_the_runner(self):
        result = subprocess.run(
            ["sh", str(SCRIPT), "only", "tablepro", "false"],
            check=False,
            env={**os.environ, "CARGO_PKG_NAME": "tablepro"},
        )

        self.assertNotEqual(result.returncode, 0)


if __name__ == "__main__":
    unittest.main()
