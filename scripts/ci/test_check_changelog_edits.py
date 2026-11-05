#!/usr/bin/env python3
"""Tests check-changelog-edits.sh against throwaway git repositories."""

import os
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

SCRIPT = Path(__file__).with_name("check-changelog-edits.sh")


class CheckChangelogEditsTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.repo = Path(self.temp.name)
        self.env = {key: value for key, value in os.environ.items() if not key.startswith("GIT_")}
        self.git("-c", "init.defaultBranch=main", "init", "-q")
        (self.repo / "scripts/ci").mkdir(parents=True)
        shutil.copy(SCRIPT, self.repo / "scripts/ci/check-changelog-edits.sh")
        self.base = self.commit(["apple/CHANGELOG.md", "linux/CHANGELOG.md", "README.md"])

    def tearDown(self):
        self.temp.cleanup()

    def git(self, *args):
        result = subprocess.run(
            ["git", "-c", "user.name=test", "-c", "user.email=test@example.com", "-c", "commit.gpgsign=false", *args],
            cwd=self.repo, env=self.env, check=True, capture_output=True, text=True,
        )
        return result.stdout.strip()

    def commit(self, paths):
        for path in paths:
            file = self.repo / path
            file.parent.mkdir(parents=True, exist_ok=True)
            with open(file, "a", encoding="utf-8") as handle:
                handle.write("change\n")
        self.git("add", "-A")
        self.git("commit", "-q", "-m", "change")
        return self.git("rev-parse", "HEAD")

    def check(self, title, base=None):
        result = subprocess.run(
            ["bash", "scripts/ci/check-changelog-edits.sh", self.base if base is None else base, title],
            cwd=self.repo, env=self.env, capture_output=True, text=True,
        )
        return result.returncode, result.stdout

    def test_a_change_without_a_changelog_passes_under_any_title(self):
        self.commit(["README.md", "apple/changelog.d/3500.fixed.md"])
        self.assertEqual(self.check("fix(editor): keep the caret")[0], 0)

    def test_a_changelog_edit_fails_outside_a_release_title(self):
        for path in ["apple/CHANGELOG.md", "linux/CHANGELOG.md"]:
            with self.subTest(path=path):
                self.git("reset", "-q", "--hard", self.base)
                self.commit([path])
                status, out = self.check("fix(editor): keep the caret")
                self.assertEqual(status, 1)
                self.assertIn(f"::error title=Changelog::Only a chore(release) pull request edits {path}", out)

    def test_both_changelogs_are_named_in_one_line(self):
        self.commit(["apple/CHANGELOG.md", "linux/CHANGELOG.md"])
        status, out = self.check("docs: notes")
        self.assertEqual(status, 1)
        self.assertEqual(len(out.splitlines()), 1)
        self.assertIn("apple/CHANGELOG.md or linux/CHANGELOG.md", out)

    def test_a_release_title_may_edit_a_changelog(self):
        self.commit(["apple/CHANGELOG.md"])
        self.assertEqual(self.check("chore(release): v0.86.0")[0], 0)

    def test_a_title_naming_release_elsewhere_is_not_a_release_title(self):
        self.commit(["apple/CHANGELOG.md"])
        self.assertEqual(self.check("fix: chore(release) notes")[0], 1)

    def test_an_empty_base_is_a_usage_error(self):
        self.assertEqual(self.check("fix: x", base="")[0], 2)


if __name__ == "__main__":
    unittest.main()
