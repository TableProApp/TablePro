from pathlib import Path
import os
import stat
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "scripts/prepull-test-images.sh"
IMAGES = ROOT / "ci/test-images.txt"

STUB = """#!/usr/bin/env bash
echo "$*" >> "$STUB_LOG"
case "$1 $2" in
  "image inspect")
    grep -qx "$3" "$STUB_PRESENT" 2>/dev/null
    exit $?
    ;;
  "pull --quiet")
    count=$(grep -c "^pull --quiet $3$" "$STUB_LOG")
    [ "$count" -gt "$STUB_FAIL_FIRST" ]
    exit $?
    ;;
esac
exit 0
"""


def run(group, fail_first=0, present=(), images=None):
    with tempfile.TemporaryDirectory() as tmp:
        tmp = Path(tmp)
        stub = tmp / "docker"
        stub.write_text(STUB)
        stub.chmod(stub.stat().st_mode | stat.S_IXUSR)
        log = tmp / "log"
        log.write_text("")
        present_file = tmp / "present"
        present_file.write_text("".join(f"{image}\n" for image in present))
        env = dict(
            os.environ,
            PATH=f"{tmp}:{os.environ['PATH']}",
            STUB_LOG=str(log),
            STUB_PRESENT=str(present_file),
            STUB_FAIL_FIRST=str(fail_first),
            PREPULL_BACKOFF_SECONDS="0",
            PREPULL_IMAGE_LIST=str(images or IMAGES),
        )
        result = subprocess.run(["bash", str(SCRIPT), group], env=env, capture_output=True, text=True)
        return result, log.read_text().splitlines()


class PrepullTestImagesTests(unittest.TestCase):
    def test_every_image_in_a_group_is_pulled_once_when_the_pull_works(self):
        result, calls = run("mongodb")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("pull --quiet mongo:7", calls)
        self.assertEqual(calls.count("pull --quiet mongo:7"), 1)

    def test_an_image_already_on_the_host_is_not_pulled(self):
        result, calls = run("mongodb", present=["mongo:7"])
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertNotIn("pull --quiet mongo:7", calls)

    def test_a_dropped_download_is_retried_and_then_succeeds(self):
        result, calls = run("mongodb", fail_first=2)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(calls.count("pull --quiet mongo:7"), 3)

    def test_a_pull_that_never_works_fails_the_step_and_names_the_image(self):
        result, calls = run("mongodb", fail_first=99)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("mongo:7", result.stderr)
        self.assertEqual(calls.count("pull --quiet mongo:7"), 3)

    def test_an_unknown_group_is_an_error_not_a_silent_skip(self):
        result, calls = run("no-such-group")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(calls, [])

    def test_the_list_covers_each_driver_and_the_tls_fixtures(self):
        groups = {line.split()[0] for line in IMAGES.read_text().splitlines() if line and not line.startswith("#")}
        for group in ("postgres", "mysql", "mssql", "clickhouse", "redis", "mongodb", "driver-tls"):
            self.assertIn(group, groups)

    def test_the_driver_jobs_pre_pull_before_their_tests(self):
        ci = (ROOT / ".forgejo/workflows/ci.yml").read_text()
        self.assertIn('bash src/scripts/prepull-test-images.sh "${{ matrix.driver }}"', ci)
        self.assertIn("bash src/scripts/prepull-test-images.sh driver-tls", ci)


if __name__ == "__main__":
    unittest.main()
