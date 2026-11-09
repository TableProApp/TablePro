#!/usr/bin/env python3

import os
import subprocess
import tempfile
import unittest
from pathlib import Path

SCRIPT = Path(__file__).resolve().parent / "tag.sh"

STUBS = {
    "gh": r"""#!/usr/bin/env bash
set -euo pipefail
echo "gh $*" >> "$STUB_STATE/calls"
case "$1 $2" in
    "run list")
        case "$*" in
            *--workflow\ ci.yml*) echo "${CI_RUN:-}" ;;
            *--workflow\ release.yml*) echo "${RELEASE_RUN:-}" ;;
        esac
        ;;
    "run watch") [ "$3" != "${RED_RUN:-}" ] ;;
    *) echo "stub gh: unexpected $*" >&2; exit 99 ;;
esac
""",
    "sleep": """#!/usr/bin/env bash
echo "sleep $1" >> "$STUB_STATE/calls"
""",
    # git signs a tag with "<gpg.program> --status-fd=2 -bsau <key>" and wants SIG_CREATED on that descriptor.
    "gpg": r"""#!/usr/bin/env bash
cat > /dev/null
printf '\n[GNUPG:] SIG_CREATED D 1 8 00 0 0\n' >&2
printf -- '-----BEGIN PGP SIGNATURE-----\n\nstub\n-----END PGP SIGNATURE-----\n'
""",
}

VERSION_STUB = """import os
import sys

if sys.argv[1] == "parse":
    print("version=0.82.1\\nbuild=820199\\nchannel=stable\\nline=0.82")
else:
    with open(os.path.join(os.environ["STUB_STATE"], "calls"), "a") as calls:
        calls.write(f"check {sys.argv[2]}\\n")
    sys.exit(int(os.environ.get("CHECK_EXIT", "0")))
"""


class TagTests(unittest.TestCase):
    def setUp(self):
        directory = tempfile.TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        root = Path(directory.name)
        self.bin = root / "bin"
        self.state = root / "state"
        self.repo = root / "repo"
        self.origin = root / "origin.git"
        for path in (self.bin, self.state, self.repo):
            path.mkdir()
        for name, body in STUBS.items():
            stub = self.bin / name
            stub.write_text(body, encoding="utf-8")
            stub.chmod(0o755)
        self.env = {
            **{key: value for key, value in os.environ.items() if not key.startswith("GIT_")},
            "PATH": f"{self.bin}{os.pathsep}{os.environ['PATH']}",
            "STUB_STATE": str(self.state),
            "GIT_CONFIG_GLOBAL": os.devnull,
            "GIT_CONFIG_NOSYSTEM": "1",
            "GIT_CONFIG_COUNT": "1",
            "GIT_CONFIG_KEY_0": "gpg.program",
            "GIT_CONFIG_VALUE_0": str(self.bin / "gpg"),
            "GIT_AUTHOR_NAME": "Fixture",
            "GIT_AUTHOR_EMAIL": "fixture@example.com",
            "GIT_COMMITTER_NAME": "Fixture",
            "GIT_COMMITTER_EMAIL": "fixture@example.com",
            "CI_RUN": "11",
            "RELEASE_RUN": "22",
        }
        self.git("init", "--quiet", "--bare", str(self.origin), cwd=root)
        self.git("init", "--quiet", "--initial-branch=release/0.82")
        version = self.repo / "apple/scripts/release/version.py"
        version.parent.mkdir(parents=True)
        version.write_text(VERSION_STUB, encoding="utf-8")
        self.git("add", "--all")
        self.git("commit", "--quiet", "-m", "chore(release): v0.82.1")
        self.git("remote", "add", "origin", str(self.origin))
        self.git("push", "--quiet", "origin", "HEAD")
        self.sha = self.git("rev-parse", "HEAD")

    def git(self, *args, cwd=None):
        return subprocess.run(["git", *args], cwd=cwd or self.repo, env=self.env, check=True,
                              capture_output=True, text=True).stdout.strip()

    def tag(self, **env):
        return subprocess.run(["bash", str(SCRIPT), "v0.82.1", "HEAD"], cwd=self.repo, env={**self.env, **env},
                              capture_output=True, text=True)

    def calls(self):
        calls = self.state / "calls"
        return calls.read_text(encoding="utf-8").splitlines() if calls.exists() else []

    def local_tags(self):
        return self.git("tag", "--list")

    def pushed_tags(self):
        return self.git("--git-dir", str(self.origin), "tag", "--list")

    def test_a_green_run_and_check_push_a_signed_tag_and_watch_its_release(self):
        result = self.tag()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.calls(), [
            f"gh run list --workflow ci.yml --branch release/0.82 --event push --commit {self.sha} --limit 1 "
            "--json databaseId --jq .[0].databaseId // empty",
            "gh run watch 11 --exit-status --interval 30",
            "check v0.82.1",
            "gh run list --workflow release.yml --branch v0.82.1 --event push --limit 1 "
            "--json databaseId --jq .[0].databaseId // empty",
            "gh run watch 22 --exit-status --interval 60",
        ])
        self.assertEqual(self.pushed_tags(), "v0.82.1")
        self.assertEqual(self.git("rev-parse", "v0.82.1^{commit}"), self.sha)
        self.assertIn("-----BEGIN PGP SIGNATURE-----", self.git("cat-file", "tag", "v0.82.1"))

    def test_a_red_ci_run_tags_nothing(self):
        result = self.tag(RED_RUN="11")
        self.assertEqual(result.returncode, 1)
        self.assertIn(f"the CI push run on {self.sha} did not pass", result.stderr)
        self.assertNotIn("check v0.82.1", self.calls())
        self.assertEqual(self.local_tags(), "")
        self.assertEqual(self.pushed_tags(), "")

    def test_a_failed_check_deletes_the_tag_and_pushes_nothing(self):
        result = self.tag(CHECK_EXIT="1")
        self.assertEqual(result.returncode, 1)
        self.assertIn("v0.82.1 cannot build", result.stderr)
        self.assertEqual(self.calls()[-1], "check v0.82.1")
        self.assertEqual(self.local_tags(), "")
        self.assertEqual(self.pushed_tags(), "")

    def test_a_missing_ci_run_is_waited_for_then_refused(self):
        result = self.tag(CI_RUN="")
        self.assertEqual(result.returncode, 1)
        self.assertIn(f"no CI push run on release/0.82 at {self.sha}", result.stderr)
        self.assertEqual(self.calls().count("sleep 10"), 6)
        self.assertEqual(self.local_tags(), "")

    def test_a_missing_argument_prints_the_usage(self):
        result = subprocess.run(["bash", str(SCRIPT), "v0.82.1"], cwd=self.repo, env=self.env,
                                capture_output=True, text=True)
        self.assertEqual(result.returncode, 2)
        self.assertEqual(self.calls(), [])


if __name__ == "__main__":
    unittest.main()
