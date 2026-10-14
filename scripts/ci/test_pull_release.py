#!/usr/bin/env python3
"""Regression tests for withdrawing a release from the Sparkle feed.

This is the rollback path. It runs once every few years, under time pressure, on the file every
install polls, so it is tested here rather than rehearsed on the day.

Run: python3 scripts/ci/test_pull_release.py
"""

import contextlib
import importlib.util
import os
import pathlib
import subprocess
import sys
import tempfile
import unittest

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
SPEC = importlib.util.spec_from_file_location(
    "pull_release", pathlib.Path(__file__).with_name("pull-release.py")
)
pull_release = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(pull_release)

TEST_MERGE = importlib.util.spec_from_file_location(
    "test_merge_appcast", pathlib.Path(__file__).with_name("test_merge_appcast.py")
)
fixtures = importlib.util.module_from_spec(TEST_MERGE)
TEST_MERGE.loader.exec_module(fixtures)

item = fixtures.item
feed = fixtures.feed

BASE = feed(
    item("0.75.0", 131, "arm64"),
    item("0.75.0", 131, None),
    item("0.74.0", 130, "arm64"),
    item("0.74.0", 130, None),
    item("0.73.0", 129, "arm64"),
)


class PullReleaseTests(unittest.TestCase):
    def withdraw(self, version, text=BASE):
        with tempfile.TemporaryDirectory() as directory:
            path = pathlib.Path(directory) / "appcast.xml"
            path.write_text(text, encoding="utf-8")
            return pull_release.withdraw(path, version)

    def versions(self, text):
        root = pull_release.parse_text(text)
        return [pull_release.item_short_version(i) for i in pull_release.channel_items(root, "t")]

    def test_removes_both_architecture_items(self):
        result, removed = self.withdraw("0.75.0")
        self.assertEqual(removed, 2)
        self.assertEqual(self.versions(result), ["0.74.0", "0.74.0", "0.73.0"])

    def test_every_surviving_item_is_byte_identical(self):
        result, _ = self.withdraw("0.75.0")
        self.assertEqual(
            result,
            feed(item("0.74.0", 130, "arm64"), item("0.74.0", 130, None), item("0.73.0", 129, "arm64")),
        )

    def test_removes_a_version_from_the_middle_of_the_feed(self):
        result, removed = self.withdraw("0.74.0")
        self.assertEqual(removed, 2)
        self.assertEqual(self.versions(result), ["0.75.0", "0.75.0", "0.73.0"])

    def test_refuses_a_version_the_feed_does_not_carry(self):
        with self.assertRaises(pull_release.FeedError) as caught:
            self.withdraw("9.9.9")
        self.assertIn("nothing to withdraw", str(caught.exception))

    def test_refuses_to_empty_the_feed(self):
        only = feed(item("0.75.0", 131, "arm64"))
        with self.assertRaises(pull_release.FeedError) as caught:
            self.withdraw("0.75.0", text=only)
        self.assertIn("would empty the feed", str(caught.exception))

    def test_release_notes_containing_the_closing_tag_do_not_widen_the_cut(self):
        text = feed(
            item("0.75.0", 131, "arm64", notes="a literal &lt;/item&gt; in a cell"),
            item("0.74.0", 130, "arm64"),
        )
        result, removed = self.withdraw("0.75.0", text=text)
        self.assertEqual(removed, 1)
        self.assertEqual(self.versions(result), ["0.74.0"])

    def test_withdraws_the_newest_version_from_the_published_feed(self):
        published = pathlib.Path(__file__).resolve().parents[2] / "appcast.xml"
        text = published.read_text(encoding="utf-8")
        newest = self.versions(text)[0]
        result, removed = self.withdraw(newest, text=text)
        self.assertGreaterEqual(removed, 1)
        self.assertNotIn(newest, self.versions(result))
        self.assertEqual(len(self.versions(result)), len(self.versions(text)) - removed)


@contextlib.contextmanager
def repository_on(branch):
    """A throwaway git repo checked out on `branch`, or detached when branch is None."""
    with tempfile.TemporaryDirectory() as directory:
        def run(*args):
            subprocess.run(["git", *args], cwd=directory, check=True, capture_output=True)

        run("init", "--quiet", "--initial-branch", "main")
        run("config", "user.email", "test@example.com")
        run("config", "user.name", "Test")
        pathlib.Path(directory, "appcast.xml").write_text(BASE, encoding="utf-8")
        run("add", "appcast.xml")
        run("commit", "--quiet", "-m", "seed")
        if branch is None:
            run("checkout", "--quiet", "--detach", "HEAD")
        elif branch != "main":
            run("checkout", "--quiet", "-b", branch)
        previous = os.getcwd()
        os.chdir(directory)
        try:
            yield directory
        finally:
            os.chdir(previous)


class PublishTargetTests(unittest.TestCase):
    """SUFeedURL serves main. A withdrawal pushed anywhere else leaves every install downloading the
    bad build while the script prints that it is no longer offered, which `git push origin HEAD` from
    one of this repo's worktrees did."""

    def test_accepts_main(self):
        with repository_on("main"):
            self.assertEqual(pull_release.require_publishable_checkout(), "main")

    def test_refuses_a_feature_branch(self):
        with repository_on("fix/some-feature"):
            with self.assertRaises(pull_release.FeedError) as caught:
                pull_release.require_publishable_checkout()
            self.assertIn("fix/some-feature", str(caught.exception))
            self.assertIn("main", str(caught.exception))

    def test_refuses_a_detached_head(self):
        with repository_on(None):
            with self.assertRaises(pull_release.FeedError) as caught:
                pull_release.require_publishable_checkout()
            self.assertIn("detached", str(caught.exception))

    def test_a_wrong_branch_writes_nothing(self):
        with repository_on("fix/some-feature") as directory:
            feed_path = pathlib.Path(directory, "appcast.xml")
            before = feed_path.read_text(encoding="utf-8")
            self.assertEqual(pull_release.main(["0.75.0"]), 1)
            self.assertEqual(feed_path.read_text(encoding="utf-8"), before)

    def test_a_dry_run_is_allowed_anywhere(self):
        with repository_on("fix/some-feature"):
            self.assertEqual(pull_release.main(["0.75.0", "--dry-run"]), 0)


@contextlib.contextmanager
def clone_of_main(ahead=False, behind=False):
    """A checkout of main with an origin, one unpushed commit when ahead, one missing when behind."""
    with tempfile.TemporaryDirectory() as directory:
        origin = pathlib.Path(directory, "origin.git")
        work = pathlib.Path(directory, "work")

        def run(cwd, *args):
            subprocess.run(["git", *args], cwd=cwd, check=True, capture_output=True)

        def commit(cwd, message):
            run(cwd, "-c", "user.email=test@example.com", "-c", "user.name=Test",
                "commit", "--quiet", "--allow-empty", "-m", message)

        run(directory, "init", "--quiet", "--bare", "--initial-branch", "main", str(origin))
        run(directory, "clone", "--quiet", str(origin), str(work))
        run(work, "checkout", "--quiet", "-B", "main")
        pathlib.Path(work, "appcast.xml").write_text(BASE, encoding="utf-8")
        run(work, "add", "appcast.xml")
        commit(work, "seed")
        run(work, "push", "--quiet", "origin", "main")
        if behind:
            other = pathlib.Path(directory, "other")
            run(directory, "clone", "--quiet", str(origin), str(other))
            commit(other, "merged elsewhere")
            run(other, "push", "--quiet", "origin", "main")
        if ahead:
            commit(work, "not pushed")
        previous = os.getcwd()
        os.chdir(work)
        try:
            yield work
        finally:
            os.chdir(previous)


class PushContentTests(unittest.TestCase):
    """The release key bypasses every check on main, so a withdrawal push must hold that commit alone."""

    def test_accepts_main_at_origin(self):
        with clone_of_main():
            pull_release.require_in_step_with_origin()

    def test_refuses_an_unpushed_commit(self):
        with clone_of_main(ahead=True):
            with self.assertRaises(pull_release.FeedError) as caught:
                pull_release.require_in_step_with_origin()
            self.assertIn("origin/main", str(caught.exception))

    def test_refuses_a_main_behind_origin(self):
        with clone_of_main(behind=True):
            with self.assertRaises(pull_release.FeedError):
                pull_release.require_in_step_with_origin()

    def test_an_unpushed_commit_writes_nothing(self):
        with clone_of_main(ahead=True) as work:
            feed_path = pathlib.Path(work, "appcast.xml")
            before = feed_path.read_text(encoding="utf-8")
            self.assertEqual(pull_release.main(["0.75.0"]), 1)
            self.assertEqual(feed_path.read_text(encoding="utf-8"), before)


if __name__ == "__main__":
    unittest.main()
