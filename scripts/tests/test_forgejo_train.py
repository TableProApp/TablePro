from pathlib import Path
import os
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "scripts/forgejo-train.sh"

CARGO_STUB = """#!/usr/bin/env bash
echo "$*" >> "$STUB_LOG"
if [ "$1 $2" = "fmt --all" ]; then
  for path in $STUB_FMT_CHANGES; do printf '\\n' >> "$path"; done
  exit "${STUB_FMT_EXIT:-0}"
fi
exit 0
"""

GATE_STUB = """#!/usr/bin/env bash
printf '%s\\n' "$*" > "$GATE_LOG"
"""

GIT_STUB = """#!/usr/bin/env bash
printf '%s\\n' "$*" >> "$GIT_LOG"
if [[ " $* " == *" worktree "* ]]; then exit 90; fi
exec "$REAL_GIT" "$@"
"""

IDENTITY = {
    "GIT_AUTHOR_NAME": "Train Test",
    "GIT_AUTHOR_EMAIL": "train@example.invalid",
    "GIT_COMMITTER_NAME": "Train Test",
    "GIT_COMMITTER_EMAIL": "train@example.invalid",
}


def git(cwd, *args):
    return subprocess.run(
        ["git", *args], cwd=cwd, env={**os.environ, **IDENTITY}, check=True, capture_output=True, text=True
    ).stdout.strip()


def init_git_repo(cwd, *args):
    git(cwd, "init", *args)
    git(cwd, "config", "--local", "maintenance.auto", "false")


class Fixture:
    def __init__(self, tmp, remote_path="hosts/github.com/cozyGarage/BookiE.git"):
        self.tmp = Path(tmp)
        self.bookie = self.tmp / remote_path
        self.bookie.mkdir(parents=True)
        init_git_repo(self.bookie, "--quiet", "--bare", "--initial-branch=linux")
        self.repo = self.tmp / "clone"
        self.repo.mkdir()
        init_git_repo(self.repo, "--quiet", "--initial-branch=linux")
        git(self.repo, "remote", "add", "fork", str(self.bookie))
        (self.repo / ".gitattributes").write_text("src/registry.rs merge=union\n")
        (self.repo / "src").mkdir()
        (self.repo / "src/registry.rs").write_text("mod base;\n")
        (self.repo / "src/other.rs").write_text("fn other() {}\n")
        (self.repo / "scripts").mkdir()
        gate = self.repo / "scripts/forgejo-gate.sh"
        gate.write_text(GATE_STUB)
        gate.chmod(0o755)
        git(self.repo, "add", "-A")
        git(self.repo, "commit", "--quiet", "-m", "base")
        git(self.repo, "push", "--quiet", "fork", "linux")
        self.base = git(self.repo, "rev-parse", "HEAD")

    def branch(self, name, line):
        git(self.repo, "checkout", "--quiet", "-b", name, self.base)
        with (self.repo / "src/registry.rs").open("a") as registry:
            registry.write(line)
        git(self.repo, "commit", "--quiet", "-am", name)
        git(self.repo, "push", "--quiet", "fork", name)
        git(self.repo, "checkout", "--quiet", "linux")

    def branch_file(self, name, path, content):
        git(self.repo, "checkout", "--quiet", "-b", name, self.base)
        (self.repo / path).write_text(content)
        git(self.repo, "add", path)
        git(self.repo, "commit", "--quiet", "-m", name)
        git(self.repo, "push", "--quiet", "fork", name)
        git(self.repo, "checkout", "--quiet", "linux")

    def run(self, *branches, fmt_changes="", fmt_exit=0, env=None):
        stub_dir = self.tmp / "bin"
        stub_dir.mkdir(exist_ok=True)
        stub = stub_dir / "cargo"
        stub.write_text(CARGO_STUB)
        stub.chmod(0o755)
        log = self.tmp / "cargo.log"
        log.write_text("")
        environment = {
            **os.environ,
            **IDENTITY,
            "PATH": f"{stub_dir}:{os.environ['PATH']}",
            "STUB_LOG": str(log),
            "STUB_FMT_CHANGES": fmt_changes,
            "STUB_FMT_EXIT": str(fmt_exit),
            "GATE_LOG": str(self.tmp / "gate.log"),
            "GIT_LOG": str(self.tmp / "git.log"),
            "REAL_GIT": shutil.which("git"),
            "FORGEJO_TRAIN_DRY": "1",
            **(env or {}),
        }
        git_stub = stub_dir / "git"
        git_stub.write_text(GIT_STUB)
        git_stub.chmod(0o755)
        return subprocess.run(
            ["bash", str(SCRIPT), *branches], cwd=self.repo, env=environment, capture_output=True, text=True
        )

    def train_sha(self, result):
        return result.stdout.rsplit("(", 1)[1].split(")", 1)[0]

    def train_messages(self, result):
        return git(self.repo, "log", "--format=%s", self.train_sha(result)).splitlines()

    def cargo_calls(self):
        return (self.tmp / "cargo.log").read_text().splitlines()


class ForgejoTrainTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.fixture = Fixture(self.tmp.name)
        self.fixture.branch("feature-a", "mod beta;\n")
        self.fixture.branch("feature-b", "mod alpha;\n")

    def tearDown(self):
        self.tmp.cleanup()

    def test_fixture_git_repositories_disable_automatic_maintenance(self):
        for repository in (self.fixture.repo, self.fixture.bookie):
            self.assertEqual(git(repository, "config", "--local", "--get", "maintenance.auto"), "false")

    def test_a_formatting_change_confined_to_union_merged_files_is_committed_to_the_train(self):
        result = self.fixture.run("feature-a", "feature-b", fmt_changes="src/registry.rs")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.fixture.train_messages(result)[0], "train: format union-merged files")

    def test_a_formatting_change_outside_union_merged_files_fails_and_names_the_file(self):
        result = self.fixture.run("feature-a", "feature-b", fmt_changes="src/registry.rs src/other.rs")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("src/other.rs", result.stderr)
        self.assertNotIn("src/registry.rs", result.stderr)

    def test_a_train_that_needs_no_formatting_gains_no_format_commit(self):
        result = self.fixture.run("feature-a", "feature-b")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertNotIn("train: format union-merged files", self.fixture.train_messages(result))

    def test_a_failing_formatter_stops_the_train(self):
        result = self.fixture.run("feature-a", "feature-b", fmt_exit=1)
        self.assertIn("fmt --all", self.fixture.cargo_calls())
        self.assertNotEqual(result.returncode, 0)

    def test_branches_come_from_the_bookie_remote_even_when_origin_points_elsewhere(self):
        decoy = Path(self.tmp.name) / "hosts/upstream/TablePro.git"
        decoy.mkdir(parents=True)
        init_git_repo(decoy, "--quiet", "--bare")
        git(self.fixture.repo, "remote", "add", "origin", str(decoy))
        result = self.fixture.run("feature-a", "feature-b")
        self.assertEqual(result.returncode, 0, result.stderr)
        sha = self.fixture.train_sha(result)
        self.assertEqual(git(self.fixture.repo, "rev-parse", f"{sha}^1^1"), self.fixture.base)

    def test_gate_receives_the_exact_train_sha_and_a_sha_scoped_remote_ref(self):
        original_head = git(self.fixture.repo, "rev-parse", "HEAD")
        result = self.fixture.run("feature-a", "feature-b", env={"FORGEJO_TRAIN_DRY": ""})
        self.assertEqual(result.returncode, 0, result.stderr)
        sha = self.fixture.train_sha(result)
        self.assertEqual((self.fixture.tmp / "gate.log").read_text().split(), [sha, f"train/{sha}"])
        self.assertEqual(git(self.fixture.repo, "rev-parse", "HEAD"), original_head)

    def test_branches_come_from_github_even_when_the_forgejo_mirror_shares_the_repository_path(self):
        mirror = Path(self.tmp.name) / "hosts/forgejo.invalid/cozyGarage/BookiE.git"
        self.assertEqual(mirror.parts[-3], "forgejo.invalid")
        mirror.mkdir(parents=True)
        init_git_repo(mirror, "--quiet", "--bare")
        git(self.fixture.repo, "remote", "add", "forgejo", str(mirror))
        result = self.fixture.run("feature-a", "feature-b")
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_train_uses_the_current_checkout_without_creating_a_worktree(self):
        original_head = git(self.fixture.repo, "rev-parse", "HEAD")
        result = self.fixture.run("feature-a", "feature-b")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertNotIn("worktree", (self.fixture.tmp / "git.log").read_text())
        self.assertEqual(git(self.fixture.repo, "rev-parse", "HEAD"), original_head)

    def test_a_conflicting_input_stops_the_train_and_restores_the_checkout(self):
        self.fixture.branch_file("conflict-a", "src/other.rs", "fn first() {}\\n")
        self.fixture.branch_file("conflict-b", "src/other.rs", "fn second() {}\\n")
        original_head = git(self.fixture.repo, "rev-parse", "HEAD")
        result = self.fixture.run("conflict-a", "conflict-b")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("conflicts", result.stderr)
        self.assertEqual(git(self.fixture.repo, "rev-parse", "HEAD"), original_head)
        self.assertEqual(git(self.fixture.repo, "status", "--porcelain"), "")

    def test_a_dirty_checkout_is_refused_without_changing_the_working_file(self):
        path = self.fixture.repo / "src/other.rs"
        path.write_text("uncommitted change\\n")
        original_head = git(self.fixture.repo, "rev-parse", "HEAD")
        result = self.fixture.run("feature-a", "feature-b")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("current checkout must be clean", result.stderr)
        self.assertEqual(git(self.fixture.repo, "rev-parse", "HEAD"), original_head)
        self.assertEqual(path.read_text(), "uncommitted change\\n")


class ForgejoTrainRemoteTests(unittest.TestCase):
    def test_without_a_bookie_remote_the_train_refuses_to_guess(self):
        with tempfile.TemporaryDirectory() as tmp:
            fixture = Fixture(tmp, remote_path="hosts/someone/else.git")
            fixture.branch("feature-a", "mod beta;\n")
            fixture.branch("feature-b", "mod alpha;\n")
            result = fixture.run("feature-a", "feature-b")
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("FORGEJO_TRAIN_REMOTE", result.stderr)

    def test_an_explicit_remote_overrides_detection(self):
        with tempfile.TemporaryDirectory() as tmp:
            fixture = Fixture(tmp, remote_path="hosts/someone/else.git")
            fixture.branch("feature-a", "mod beta;\n")
            fixture.branch("feature-b", "mod alpha;\n")
            result = fixture.run("feature-a", "feature-b", env={"FORGEJO_TRAIN_REMOTE": "fork"})
            self.assertEqual(result.returncode, 0, result.stderr)


if __name__ == "__main__":
    unittest.main()
