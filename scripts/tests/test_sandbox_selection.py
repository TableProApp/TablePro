import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[2]


class SandboxSelectionTests(unittest.TestCase):
    def test_unit_tier_keeps_library_and_binary_unit_targets(self):
        script = (ROOT / "scripts/preflight.sh").read_text()
        commands = [line for line in script.splitlines() if '"$NEXTEST" nextest run' in line]
        self.assertEqual(len(commands), 1)
        self.assertIn("--lib", commands[0].split())
        self.assertIn("--bins", commands[0].split())
        self.assertNotIn("--tests", commands[0].split())

    def test_sandbox_selects_all_integration_targets_without_repeating_unit_targets(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            scripts = root / "scripts"
            scripts.mkdir()
            shutil.copyfile(ROOT / "scripts/test-sandbox.sh", scripts / "test-sandbox.sh")
            nextest = root / "nextest"
            nextest.write_text(
                '#!/usr/bin/env python3\nimport json, os, sys\n'
                'with open(os.environ["NEXTEST_LOG"], "a") as output:\n'
                '    output.write(json.dumps(sys.argv[1:]) + "\\n")\n'
            )
            nextest.chmod(0o755)
            (scripts / "ensure-nextest.sh").write_text(f"#!/bin/sh\nprintf '%s\\n' '{nextest}'\n")
            (scripts / "ensure-nextest.sh").chmod(0o755)
            log = root / "commands.jsonl"
            result = subprocess.run(
                ["bash", str(scripts / "test-sandbox.sh")],
                env={**os.environ, "NEXTEST_LOG": str(log)}, text=True, capture_output=True,
            )
            self.assertEqual(result.returncode, 0, result.stderr)
            commands = [json.loads(line) for line in log.read_text().splitlines()]
        self.assertEqual(len(commands), 2)
        for command in commands:
            self.assertNotIn("--tests", command)
            self.assertNotIn("--lib", command)
            self.assertNotIn("--bins", command)
        self.assertEqual(commands[0][commands[0].index("--test") + 1], "*")
        self.assertEqual(commands[1][commands[1].index("--test") + 1], "cancellation")


if __name__ == "__main__":
    unittest.main()
