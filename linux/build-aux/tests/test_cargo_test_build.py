import subprocess
import tempfile
import unittest
from pathlib import Path

SCRIPT = Path(__file__).resolve().parent.parent / "cargo-test-build.sh"


class CargoTestBuildTest(unittest.TestCase):
    def test_a_build_writes_the_stamp_and_keeps_arguments_whole(self):
        with tempfile.TemporaryDirectory() as directory:
            work = Path(directory) / "a build dir"
            work.mkdir()
            arguments = work / "cargo arguments"
            cargo = work / "fake cargo"
            cargo.write_text(f"#!/bin/sh\nprintf '%s\\n' \"$@\" > '{arguments}'\n")
            cargo.chmod(0o755)
            stamp = work / "app tests.stamp"

            subprocess.run(
                ["sh", str(SCRIPT), str(stamp), "--", str(cargo), "test", "--no-run", "-p", "a crate"],
                check=True,
            )

            self.assertEqual(arguments.read_text().splitlines(), ["test", "--no-run", "-p", "a crate"])
            self.assertTrue(stamp.is_file())

    def test_a_failed_build_writes_no_stamp(self):
        with tempfile.TemporaryDirectory() as directory:
            stamp = Path(directory) / "tests.stamp"
            result = subprocess.run(["sh", str(SCRIPT), str(stamp), "--", "false"], check=False)

            self.assertNotEqual(result.returncode, 0)
            self.assertFalse(stamp.exists())

    def test_a_missing_separator_is_refused(self):
        result = subprocess.run(
            ["sh", str(SCRIPT), "tests.stamp", "true"],
            check=False,
            capture_output=True,
            text=True,
        )

        self.assertEqual(result.returncode, 2)
        self.assertIn("usage", result.stderr)


if __name__ == "__main__":
    unittest.main()
