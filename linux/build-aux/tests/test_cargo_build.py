import os
import subprocess
import tempfile
import unittest
from pathlib import Path

SCRIPT = Path(__file__).resolve().parent.parent / "cargo-build.sh"


class CargoBuildTest(unittest.TestCase):
    def test_paths_with_spaces_stay_whole(self):
        with tempfile.TemporaryDirectory() as directory:
            work = Path(directory) / "a source tree"
            built = work / "cargo target" / "release"
            built.mkdir(parents=True)
            outputs = work / "build dir"
            outputs.mkdir()
            cargo = work / "fake cargo"
            arguments = work / "cargo arguments"
            cargo.write_text(
                "#!/bin/sh\n"
                f"printf '%s\\n' \"$@\" > '{arguments}'\n"
                f"printf app > '{built / 'tablepro'}'\n"
                f"printf askpass > '{built / 'tablepro-askpass'}'\n"
            )
            cargo.chmod(0o755)
            manifest = work / "Cargo.toml"

            subprocess.run(
                [
                    "sh",
                    str(SCRIPT),
                    str(built / "tablepro"),
                    str(outputs / "tablepro"),
                    str(built / "tablepro-askpass"),
                    str(outputs / "tablepro-askpass"),
                    "--",
                    str(cargo),
                    "build",
                    "--manifest-path",
                    str(manifest),
                ],
                check=True,
                env=dict(os.environ),
            )

            self.assertEqual(arguments.read_text().splitlines(), ["build", "--manifest-path", str(manifest)])
            self.assertEqual((outputs / "tablepro").read_text(), "app")
            self.assertEqual((outputs / "tablepro-askpass").read_text(), "askpass")

    def test_a_failed_build_copies_nothing(self):
        with tempfile.TemporaryDirectory() as directory:
            work = Path(directory)
            (work / "built").write_text("stale")
            result = subprocess.run(
                ["sh", str(SCRIPT), str(work / "built"), str(work / "output"), "--", "false"],
                check=False,
            )

            self.assertNotEqual(result.returncode, 0)
            self.assertFalse((work / "output").exists())

    def test_an_unpaired_output_is_refused(self):
        result = subprocess.run(
            ["sh", str(SCRIPT), "only-one", "--", "true"],
            check=False,
            capture_output=True,
            text=True,
        )

        self.assertEqual(result.returncode, 2)
        self.assertIn("usage", result.stderr)


if __name__ == "__main__":
    unittest.main()
