import json
import os
from pathlib import Path
import shlex
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[2]


class DistroFloorShardTests(unittest.TestCase):
    def test_success_output_keeps_every_scenario_for_cross_shard_coverage_checks(self):
        script = (ROOT / "scripts/test-distro-floor.sh").read_text()
        summaries = [line.strip() for line in script.splitlines() if 'grep -aE "^passed:' in line]
        self.assertEqual(len(summaries), 2)
        with tempfile.TemporaryDirectory() as temporary:
            log = Path(temporary) / "gtk-safety.log"
            expected = [f"passed: scenario_{index}" for index in range(40)]
            expected.append("gtk: 40 tests executed successfully")
            log.write_text("\n".join(expected) + "\n")
            for summary in summaries:
                command = summary.replace("/tmp/gtk-safety.log", shlex.quote(str(log)))
                result = subprocess.run(
                    ["bash", "-o", "pipefail", "-c", command],
                    capture_output=True, text=True, check=False,
                )
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(result.stdout.splitlines(), expected)

    def test_fallback_package_staging_does_not_dirty_the_artifact_source_checkout(self):
        result = subprocess.run(
            ["git", "check-ignore", "--no-index", ".floor-package/source/bookie/usr/bin/bookie"],
            cwd=ROOT, capture_output=True, text=True, check=False,
        )
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_docker_receives_the_selected_shard_for_both_package_and_source_runs(self):
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            docker = directory / "docker"
            docker.write_text(
                "#!/usr/bin/env python3\n"
                "import json, os, sys\n"
                "with open(os.environ['DOCKER_ARGUMENTS'], 'a') as log:\n"
                "    log.write(json.dumps(sys.argv[1:]) + '\\n')\n"
            )
            docker.chmod(0o755)
            package = directory / "bookie.deb"
            package.write_bytes(b"fixture")
            for packaged in (False, True):
                with self.subTest(packaged=packaged):
                    log = directory / f"arguments-{packaged}.jsonl"
                    environment = os.environ.copy()
                    environment.pop("DISTRO_FLOOR_PACKAGE", None)
                    environment.update(
                        PATH=f"{directory}{os.pathsep}{environment['PATH']}",
                        DOCKER_ARGUMENTS=str(log),
                        TABLEPRO_GTK_SHARD="2/3",
                    )
                    if packaged:
                        environment["DISTRO_FLOOR_PACKAGE"] = str(package)
                    result = subprocess.run(
                        ["bash", str(ROOT / "scripts/test-distro-floor.sh"), "debian:testing"],
                        env=environment, capture_output=True, text=True, check=False,
                    )
                    self.assertEqual(result.returncode, 0, result.stderr)
                    calls = [json.loads(line) for line in log.read_text().splitlines()]
                    runs = [call for call in calls if call[0] == "run"]
                    self.assertEqual(len(runs), 1)
                    arguments = runs[0]
                    self.assertIn("TABLEPRO_GTK_SHARD=2/3", arguments)
                    position = arguments.index("TABLEPRO_GTK_SHARD=2/3")
                    self.assertEqual(arguments[position - 1], "-e")
                    self.assertLess(position, arguments.index("bash"))


if __name__ == "__main__":
    unittest.main()
