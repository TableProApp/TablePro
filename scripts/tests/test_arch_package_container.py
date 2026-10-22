import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]


class ArchPackageContainerTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name)
        scripts = self.root / "scripts"
        scripts.mkdir()
        for name in ("test-arch-package-container.sh", "check-release-version.py"):
            shutil.copy2(ROOT / "scripts" / name, scripts / name)
        (self.root / "Cargo.toml").write_text('[workspace.package]\nversion = "0.2.0"\n')
        commands = self.root / "commands"
        commands.mkdir()
        self.record = self.root / "docker.json"
        docker = commands / "docker"
        docker.write_text(f"#!{sys.executable}\nimport json,os,sys\nfrom pathlib import Path\nPath(os.environ['DOCKER_RECORD']).write_text(json.dumps({{'args':sys.argv[1:],'stdin':sys.stdin.read()}}))\n")
        docker.chmod(0o700)
        real_date = shutil.which("date")
        date = commands / "date"
        date.write_text(f'#!/bin/bash\nif [[ "$*" == "-u +%F" ]]; then echo "${{FAKE_UTC_DATE:-2026-10-22}}"; else exec "{real_date}" "$@"; fi\n')
        date.chmod(0o700)
        self.environment = {key: value for key, value in os.environ.items() if key not in {"TABLEPRO_RC_DATE", "ARCH_CANDIDATE_DATE", "ARCH_CANDIDATE_VERSION", "ARCH_RELEASED_URL"}}
        self.environment.update(PATH=str(commands) + os.pathsep + os.environ["PATH"], DOCKER_RECORD=str(self.record), FAKE_UTC_DATE="2026-10-22")

    def run_wrapper(self, **overrides):
        return subprocess.run(["bash", "scripts/test-arch-package-container.sh"], cwd=self.root,
                              env={**self.environment, **overrides}, input="", capture_output=True, text=True, timeout=10)

    def docker_environment(self):
        args = json.loads(self.record.read_text())["args"]
        return dict(args[index + 1].split("=", 1) for index, item in enumerate(args[:-1]) if item == "-e")

    def test_default_standalone_invocation_forwards_utc_date(self):
        for date in ("2026-10-22", "2026-12-31"):
            with self.subTest(date=date):
                result = self.run_wrapper(FAKE_UTC_DATE=date)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(self.docker_environment().get("TABLEPRO_RC_DATE"), date)

    def test_default_version_tracks_the_workspace(self):
        (self.root / "Cargo.toml").write_text('[workspace.package]\nversion = "0.3.0"\n')
        result = self.run_wrapper()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.docker_environment()["VERSION"], "0.3.0")

    def test_explicit_date_takes_precedence_over_inherited_date(self):
        result = self.run_wrapper(ARCH_CANDIDATE_DATE="2026-10-19", TABLEPRO_RC_DATE="2026-10-18")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.docker_environment().get("TABLEPRO_RC_DATE"), "2026-10-19")

    def test_inherited_candidate_date_is_forwarded(self):
        result = self.run_wrapper(TABLEPRO_RC_DATE="2026-10-18")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.docker_environment().get("TABLEPRO_RC_DATE"), "2026-10-18")

    def test_invalid_calendar_date_is_refused_before_container_work(self):
        result = self.run_wrapper(ARCH_CANDIDATE_DATE="2026-02-30")
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(self.record.exists())

    def test_invalid_version_is_refused_before_container_work(self):
        result = self.run_wrapper(ARCH_CANDIDATE_VERSION="0.2.0;echo unsafe")
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(self.record.exists())

    def test_version_drift_is_refused_before_container_work(self):
        result = self.run_wrapper(ARCH_CANDIDATE_VERSION="0.2.1")
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(self.record.exists())

    def test_a_valid_leap_day_is_accepted(self):
        result = self.run_wrapper(ARCH_CANDIDATE_DATE="2024-02-29")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.docker_environment()["TABLEPRO_RC_DATE"], "2024-02-29")

    def test_noncanonical_dates_are_refused_before_container_work(self):
        for date in ("2026-02-29", "2026-2-03", "2026-10-19\nextra", "$(exit 0)"):
            with self.subTest(date=date):
                self.record.unlink(missing_ok=True)
                result = self.run_wrapper(ARCH_CANDIDATE_DATE=date)
                self.assertNotEqual(result.returncode, 0)
                self.assertFalse(self.record.exists())

    def test_builder_receives_the_date_and_keeps_url_text_as_data(self):
        marker = self.root / "must-not-execute"
        url = f'https://example.invalid/$(touch {marker})/"quoted".pkg.tar.zst'
        result = self.run_wrapper(ARCH_CANDIDATE_DATE="2026-10-19", ARCH_RELEASED_URL=url)
        self.assertEqual(result.returncode, 0, result.stderr)
        record = json.loads(self.record.read_text())
        environment = self.docker_environment()
        container = record["stdin"] or record["args"][-1]
        body = container[container.index("  sudo -u builder "): ]
        scripts = self.root / "scripts"
        (scripts / "build-arch-rc.sh").write_text(
            'python3 - <<\'PY\'\nimport json,os\nfrom pathlib import Path\n'
            'Path(os.environ["BUILD_RECORD"]).write_text(json.dumps({key: os.environ.get(key) for key in ["TABLEPRO_RC_DATE", "TABLEPRO_RC_VERSION", "TABLEPRO_RC_COMMIT"]}))\nPY\n'
        )
        (scripts / "test-arch-package.sh").write_text('printf \'%s\\n\' "$@" > "$LIFECYCLE_RECORD"\n')
        commands = self.root / "commands"
        git = commands / "git"
        git.write_text('#!/bin/bash\nif [[ "$*" == "rev-parse HEAD" ]]; then printf \'%040d\\n\' 1; fi\n')
        git.chmod(0o700)
        curl = commands / "curl"
        curl.write_text(f'#!{sys.executable}\nimport json,os,sys\nfrom pathlib import Path\nPath(os.environ["CURL_RECORD"]).write_text(json.dumps(sys.argv[1:]))\n')
        curl.chmod(0o700)
        sudo = commands / "sudo"
        sudo.write_text(
            f"#!{sys.executable}\nimport os,subprocess,sys\n"
            "keys = ['PATH', 'BASH_ENV', 'FIXTURE_ROOT', 'BUILD_RECORD', 'CURL_RECORD', 'LIFECYCLE_RECORD']\n"
            "environment = {key: os.environ[key] for key in keys}\n"
            "raise SystemExit(subprocess.run(sys.argv[3:], env=environment, stdin=sys.stdin).returncode)\n"
        )
        sudo.chmod(0o700)
        init = self.root / "shell-init"
        init.write_text('cd() { builtin cd "$FIXTURE_ROOT"; }\n')
        child_environment = {**self.environment, **environment, "BASH_ENV": str(init), "FIXTURE_ROOT": str(self.root),
                             "BUILD_RECORD": str(self.root / "build.json"), "CURL_RECORD": str(self.root / "curl.json"),
                             "LIFECYCLE_RECORD": str(self.root / "lifecycle")}
        builder = subprocess.run(["bash", "-seu"], input=body, env=child_environment, capture_output=True, text=True, timeout=10)
        self.assertEqual(builder.returncode, 0, builder.stderr)
        self.assertFalse(marker.exists())
        build = json.loads((self.root / "build.json").read_text())
        self.assertEqual(build, {"TABLEPRO_RC_DATE": "2026-10-19", "TABLEPRO_RC_VERSION": "0.2.0", "TABLEPRO_RC_COMMIT": "0" * 39 + "1"})
        self.assertEqual(json.loads((self.root / "curl.json").read_text())[-2:], ["--", url])
        self.assertIn("bookie-0.2.0-1-x86_64.pkg.tar.zst", (self.root / "lifecycle").read_text())
        self.assertFalse(marker.exists())


if __name__ == "__main__":
    unittest.main()
