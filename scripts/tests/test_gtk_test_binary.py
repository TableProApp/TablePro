import os
from pathlib import Path
import stat
import subprocess
import tempfile
import unittest

SOURCE = Path(__file__).resolve().parents[2]

FAKE_CARGO = """#!/bin/bash
set -eu
echo "$*" >> "$CARGO_LOG"
profile=release
while [ $# -gt 0 ]; do
  case "$1" in
    --release) profile=release ;;
    --profile) shift; profile="$1" ;;
  esac
  shift
done
mkdir -p "$CARGO_TARGET_DIR/$profile"
printf '#!/bin/sh\\necho %s\\n' "$profile" > "$CARGO_TARGET_DIR/$profile/tablepro-app"
chmod +x "$CARGO_TARGET_DIR/$profile/tablepro-app"
"""


class GtkTestBinaryTests(unittest.TestCase):
    def _run(self, extra_env: dict[str, str]) -> tuple[subprocess.CompletedProcess, Path]:
        temporary = tempfile.TemporaryDirectory(prefix="bookie-gtk-binary-")
        self.addCleanup(temporary.cleanup)
        root = Path(temporary.name)
        bin_dir = root / "bin"
        bin_dir.mkdir()
        cargo = bin_dir / "cargo"
        cargo.write_text(FAKE_CARGO)
        cargo.chmod(cargo.stat().st_mode | stat.S_IEXEC)
        env = {
            key: value
            for key, value in os.environ.items()
            if key not in {"TABLEPRO_GTK_BINARY", "TABLEPRO_GTK_BUILD_PROFILE"}
        }
        env.update(
            {
                "PATH": f"{bin_dir}:{env['PATH']}",
                "CARGO_LOG": str(root / "cargo.log"),
                "CARGO_TARGET_DIR": str(root / "target"),
                **extra_env,
            }
        )
        result = subprocess.run(
            ["bash", str(SOURCE / "scripts/gtk-test-binary.sh")], env=env, capture_output=True, text=True
        )
        return result, root

    def _built_profile(self, result: subprocess.CompletedProcess) -> str:
        binary = result.stdout.strip().splitlines()[-1]
        return subprocess.run([binary], capture_output=True, text=True, check=True).stdout.strip()

    def test_gui_scenarios_build_the_app_with_the_faster_ci_profile(self) -> None:
        result, root = self._run({})
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("--profile ci", (root / "cargo.log").read_text())
        self.assertEqual(self._built_profile(result), "ci")

    def test_profiling_can_still_measure_an_optimized_release_build(self) -> None:
        result, _ = self._run({"TABLEPRO_GTK_BUILD_PROFILE": "release"})
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self._built_profile(result), "release")

    def test_a_supplied_binary_is_used_without_building(self) -> None:
        supplied = Path(tempfile.mkdtemp(prefix="bookie-gtk-supplied-")) / "bookie"
        self.addCleanup(lambda: supplied.unlink(missing_ok=True) or supplied.parent.rmdir())
        supplied.write_text("#!/bin/sh\necho supplied\n")
        supplied.chmod(0o755)
        result, root = self._run({"TABLEPRO_GTK_BINARY": str(supplied)})
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse((root / "cargo.log").exists())
        self.assertEqual(result.stdout.strip(), str(supplied))

    def test_an_unknown_build_profile_is_refused(self) -> None:
        result, root = self._run({"TABLEPRO_GTK_BUILD_PROFILE": "dev"})
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse((root / "cargo.log").exists())


if __name__ == "__main__":
    unittest.main()
