import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]


class TlsStartupTests(unittest.TestCase):
    def run_failed_startup(self, diagnostic_exit):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            (root / "scripts").mkdir()
            fixture = root / "tests/fixtures/driver-tls"
            fixture.mkdir(parents=True)
            shutil.copy(ROOT / "scripts/test-driver-tls.sh", root / "scripts")
            (fixture / "generate-materials.sh").write_text("#!/bin/bash\nexit 0\n")
            binary = root / "bin"
            binary.mkdir()
            docker = binary / "docker"
            docker.write_text(r"""#!/usr/bin/env python3
import os, sys
from pathlib import Path
args = sys.argv[1:]
with Path(os.environ["TLS_COMMAND_LOG"]).open("a") as out:
    out.write(" ".join(args) + "\n")
if "up" in args:
    sys.exit(42)
if "ps" in args and "--quiet" in args:
    print("fixture-owned-id")
if "inspect" in args:
    print("healthcheck failed")
if "logs" in args:
    print("fixture startup failed")
if any(action in args for action in ["ps", "inspect", "logs"]):
    sys.exit(int(os.environ["TLS_DIAGNOSTIC_EXIT"]))
""")
            docker.chmod(0o755)
            log = root / "commands"
            result = subprocess.run(
                ["bash", str(root / "scripts/test-driver-tls.sh")],
                env=dict(os.environ, PATH=f"{binary}:{os.environ['PATH']}",
                         TLS_COMMAND_LOG=str(log), TLS_DIAGNOSTIC_EXIT=str(diagnostic_exit),
                         TABLEPRO_FIXTURE_KEEP_UP="0"),
                text=True, capture_output=True,
            )
            self.assertTrue(log.exists(), result.stderr)
            return result, log.read_text().splitlines()

    def test_startup_diagnostics_precede_cleanup_and_preserve_failure(self):
        result, commands = self.run_failed_startup(0)
        self.assertEqual(result.returncode, 42)
        self.assertIn("healthcheck failed", result.stdout)
        self.assertIn("fixture startup failed", result.stdout)
        logs = next(i for i, command in enumerate(commands) if " logs " in command)
        cleanup = max(i for i, command in enumerate(commands) if " down " in command)
        self.assertLess(logs, cleanup)
        self.assertTrue(any(command.startswith("inspect ") for command in commands))

    def test_diagnostic_failure_preserves_startup_failure_and_cleanup(self):
        result, commands = self.run_failed_startup(7)
        self.assertEqual(result.returncode, 42)
        self.assertIn(" down ", commands[-1])
        self.assertTrue(any(" logs " in command for command in commands))


if __name__ == "__main__":
    unittest.main()
