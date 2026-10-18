#!/usr/bin/env python3
"""Tests check-banned-words.sh against throwaway git repositories."""

import os
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

SCRIPT = Path(__file__).resolve().parent.parent / "check-banned-words.sh"
TERM = "frobnicate"
SEED_TEXT = "".join(f"seed line {number}\n" for number in range(20))


class CheckBannedWordsTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.repo = Path(self.temp.name)
        self.env = {key: value for key, value in os.environ.items() if not key.startswith("GIT_")}
        self.git("-c", "init.defaultBranch=main", "init", "-q")
        (self.repo / "scripts").mkdir()
        shutil.copy(SCRIPT, self.repo / "scripts/check-banned-words.sh")
        self.write("scripts/banned-words.txt", f"{TERM}\n")
        self.write(".gitattributes", "gen/** linguist-generated\nvendor/** linguist-vendored\n")
        self.write("README.md", SEED_TEXT)
        self.write("gen/data.txt", SEED_TEXT)
        self.git("add", "-A")
        self.git("commit", "-q", "-m", "seed")
        self.seed = self.git("rev-parse", "HEAD")

    def tearDown(self):
        self.temp.cleanup()

    def git(self, *args):
        result = subprocess.run(
            ["git", "-c", "user.name=test", "-c", "user.email=test@example.com", "-c", "commit.gpgsign=false", *args],
            cwd=self.repo, env=self.env, check=True, capture_output=True, text=True,
        )
        return result.stdout.strip()

    def write(self, path, text):
        file = self.repo / path
        file.parent.mkdir(parents=True, exist_ok=True)
        with open(file, "a", encoding="utf-8") as handle:
            handle.write(text)

    def stage_term(self, *paths):
        for path in paths:
            self.write(path, f"a {TERM} line\n")
        self.git("add", "-A")

    def check(self, *args, cwd=None):
        result = subprocess.run(
            ["bash", str(self.repo / "scripts/check-banned-words.sh"), *args],
            cwd=cwd or self.repo, env=self.env, capture_output=True, text=True,
        )
        return result.returncode, sorted(line.split(":")[0] for line in result.stdout.splitlines())

    def commit_term(self, *paths):
        self.stage_term(*paths)
        self.git("commit", "-q", "-m", "change")
        return self.check("--base", self.seed)

    def test_a_generated_or_vendored_file_is_skipped(self):
        self.assertEqual(self.commit_term("gen/notice.md", "vendor/lib.h", "src/app.txt"), (1, ["src/app.txt"]))

    def test_a_diff_of_only_generated_and_vendored_files_passes(self):
        self.assertEqual(self.commit_term("gen/notice.md", "vendor/lib.h"), (0, []))

    def test_an_unset_or_false_attribute_is_checked(self):
        self.write(".gitattributes", "vendor/own.txt -linguist-vendored\ngen/kept.txt linguist-generated=false\n")
        self.assertEqual(self.commit_term("vendor/own.txt", "gen/kept.txt"), (1, ["gen/kept.txt", "vendor/own.txt"]))

    def test_staged_reads_the_staged_gitattributes(self):
        self.write(".gitattributes", "notes/** linguist-generated\n")
        self.stage_term("notes/new.txt", "src/app.txt")
        self.assertEqual(self.check("--staged"), (1, ["src/app.txt"]))

    def test_a_renamed_file_follows_its_new_path(self):
        (self.repo / "src").mkdir()
        self.git("mv", "README.md", "gen/README.md")
        self.git("mv", "gen/data.txt", "src/data.txt")
        self.assertEqual(self.commit_term("gen/README.md", "src/data.txt"), (1, ["src/data.txt"]))

    def test_a_subdirectory_still_resolves_attributes_from_the_top_level(self):
        self.commit_term("gen/notice.md", "src/app.txt")
        self.assertEqual(self.check("--base", self.seed, cwd=self.repo / "src"), (1, ["src/app.txt"]))


if __name__ == "__main__":
    unittest.main()
