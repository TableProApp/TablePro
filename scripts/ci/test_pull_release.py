#!/usr/bin/env python3
"""Regression tests for withdrawing a release from the Sparkle feed.

This is the rollback path. It runs once every few years, under time pressure, on the file every
install polls, so it is tested here rather than rehearsed on the day.

Run: python3 scripts/ci/test_pull_release.py
"""

import importlib.util
import pathlib
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


if __name__ == "__main__":
    unittest.main()
