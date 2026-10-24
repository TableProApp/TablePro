import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[2]


class FloorPackageCacheTests(unittest.TestCase):
    def test_new_source_builds_reuse_dependency_volumes_without_hiding_cargo(self):
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            docker = directory / "docker"
            docker.write_text(
                "#!/usr/bin/env python3\n"
                "import json, os, sys\n"
                "from pathlib import Path\n"
                "args = sys.argv[1:]\n"
                "with open(os.environ['DOCKER_ARGUMENTS'], 'a') as log:\n"
                "    log.write(json.dumps(args) + '\\n')\n"
                "for index, arg in enumerate(args[:-1]):\n"
                "    if arg == '-v' and args[index + 1].endswith(':/out'):\n"
                "        Path(args[index + 1][:-5], 'bookie.deb').write_bytes(b'package')\n"
            )
            docker.chmod(0o755)
            log = directory / "docker.jsonl"
            environment = os.environ.copy()
            environment.update(
                PATH=f"{directory}{os.pathsep}{environment['PATH']}",
                DOCKER_ARGUMENTS=str(log),
                DISTRO_FLOOR_PACKAGE_CACHE=str(directory / "packages"),
            )
            for sha in ("a" * 40, "b" * 40, "b" * 40):
                result = subprocess.run(
                    ["bash", str(ROOT / "scripts/distro-floor-package.sh"), sha],
                    env=environment, capture_output=True, text=True, check=False,
                )
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(Path(result.stdout.strip()).read_bytes(), b"package")
            calls = [json.loads(line) for line in log.read_text().splitlines()]
            builds = [call for call in calls if any(arg.endswith(":/out") for arg in call)]
            self.assertEqual(len(builds), 2)
            previous = None
            for build in builds:
                mounts = {
                    build[index + 1].split(":")[1]: build[index + 1].split(":")[0]
                    for index, arg in enumerate(build[:-1]) if arg == "-v"
                }
                self.assertIn("/opt/cargo/registry", mounts)
                self.assertIn("/opt/cargo/git", mounts)
                self.assertNotIn("/opt/cargo", mounts)
                dependencies = (mounts["/opt/cargo/registry"], mounts["/opt/cargo/git"])
                self.assertTrue(all(name and "/" not in name for name in dependencies))
                self.assertNotEqual(dependencies[0], dependencies[1])
                if previous is not None:
                    self.assertEqual(dependencies, previous)
                previous = dependencies


if __name__ == "__main__":
    unittest.main()
