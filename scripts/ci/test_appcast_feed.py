#!/usr/bin/env python3
"""Regression tests for the text primitives both feed scripts share.

merge-appcast.py and pull-release.py agree about where an item begins and ends only because they
call the same scanner. When that scanner is wrong, one of them moves the wrong bytes into the file
every install polls, and the result is still well-formed XML, so nothing downstream notices.

Run: python3 scripts/ci/test_appcast_feed.py
"""

import pathlib
import sys
import unittest

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))

import appcast_feed  # noqa: E402


def feed(*items):
    body = "".join(items)
    return (
        '<?xml version="1.0" standalone="yes"?>\n'
        '<rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle" version="2.0">\n'
        "    <channel>\n"
        "        <title>TablePro</title>\n"
        f"{body}"
        "    </channel>\n"
        "</rss>\n"
    )


def item(version, body=""):
    return (
        "        <item>\n"
        f"            <sparkle:shortVersionString>{version}</sparkle:shortVersionString>\n"
        f"{body}"
        "        </item>\n"
    )


class ItemSpanTests(unittest.TestCase):
    def spans(self, text):
        return [text[start:end] for start, end in appcast_feed.item_spans(text)]

    def test_finds_each_item_whole(self):
        text = feed(item("0.75.0"), item("0.74.0"))
        found = self.spans(text)
        self.assertEqual(len(found), 2)
        self.assertTrue(found[0].startswith("        <item>"))
        self.assertTrue(found[0].rstrip().endswith("</item>"))

    def test_a_comment_holding_an_open_tag_does_not_swallow_the_next_item(self):
        """`<!-- <item> -->` used to open a span that ran on until the real item's close tag, so
        the first real item was consumed by a comment and silently moved with it."""
        text = feed("        <!-- <item> a note -->\n", item("0.75.0"))
        found = self.spans(text)
        self.assertEqual(len(found), 1)
        self.assertIn("0.75.0", found[0])
        self.assertNotIn("a note", found[0])

    def test_a_comment_holding_a_close_tag_does_not_truncate_an_item(self):
        """A comment inside an item used to close it early, so the rest of the item stayed behind
        when the item was removed."""
        text = feed(item("0.75.0", "            <!-- ends with </item> -->\n            <title>Keep</title>\n"))
        found = self.spans(text)
        self.assertEqual(len(found), 1)
        self.assertIn("<title>Keep</title>", found[0])

    def test_an_element_whose_name_merely_starts_with_item_is_not_an_item(self):
        text = feed("        <itemCount>3</itemCount>\n", item("0.75.0"))
        found = self.spans(text)
        self.assertEqual(len(found), 1)
        self.assertNotIn("itemCount", found[0])

    def test_cdata_holding_either_tag_is_skipped_whole(self):
        body = "            <description><![CDATA[<item> and </item> in the notes]]></description>\n"
        text = feed(item("0.75.0", body), item("0.74.0"))
        found = self.spans(text)
        self.assertEqual(len(found), 2)
        self.assertIn("in the notes", found[0])
        self.assertIn("0.74.0", found[1])

    def test_an_unterminated_comment_is_refused(self):
        with self.assertRaises(appcast_feed.FeedError) as caught:
            appcast_feed.item_spans(feed("        <!-- never closed\n", item("0.75.0")))
        self.assertIn("unterminated comment", str(caught.exception))

    def test_an_unterminated_cdata_section_is_refused(self):
        with self.assertRaises(appcast_feed.FeedError) as caught:
            appcast_feed.item_spans(feed(item("0.75.0", "            <![CDATA[never closed\n")))
        self.assertIn("unterminated CDATA section", str(caught.exception))

    def test_an_unclosed_item_is_refused(self):
        text = feed("        <item>\n            <title>Dangling</title>\n")
        with self.assertRaises(appcast_feed.FeedError) as caught:
            appcast_feed.item_spans(text)
        self.assertIn("never closed", str(caught.exception))

    def test_the_published_feed_scans_to_the_same_count_the_parser_sees(self):
        published = pathlib.Path(__file__).resolve().parents[2] / "appcast.xml"
        text = published.read_text(encoding="utf-8")
        parsed = appcast_feed.channel_items(appcast_feed.parse_text(text), "appcast.xml")
        self.assertEqual(len(appcast_feed.item_spans(text)), len(parsed))


class SpliceTests(unittest.TestCase):
    def test_inserts_before_the_newest_item(self):
        base = feed(item("0.74.0"))
        merged = appcast_feed.insert_items(base, "base", item("0.75.0"))
        versions = [
            appcast_feed.item_short_version(i)
            for i in appcast_feed.channel_items(appcast_feed.parse_text(merged), "merged")
        ]
        self.assertEqual(versions, ["0.75.0", "0.74.0"])

    def test_inserts_before_the_channel_close_when_the_feed_is_empty(self):
        merged = appcast_feed.insert_items(feed(), "base", item("0.75.0"))
        parsed = appcast_feed.channel_items(appcast_feed.parse_text(merged), "merged")
        self.assertEqual(len(parsed), 1)

    def test_refuses_items_that_do_not_end_on_a_line_boundary(self):
        with self.assertRaises(appcast_feed.FeedError) as caught:
            appcast_feed.insert_items(feed(item("0.74.0")), "base", "        <item></item>")
        self.assertIn("line boundary", str(caught.exception))

    def test_keeps_every_untouched_byte(self):
        base = feed(item("0.74.0"))
        inserted = item("0.75.0")
        merged = appcast_feed.insert_items(base, "base", inserted)
        self.assertEqual(merged.replace(inserted, "", 1), base)


class RemoveTests(unittest.TestCase):
    def test_removes_every_item_for_one_version(self):
        base = feed(item("0.75.0"), item("0.75.0"), item("0.74.0"))
        result, removed = appcast_feed.remove_version(base, "base", "0.75.0")
        self.assertEqual(removed, 2)
        versions = [
            appcast_feed.item_short_version(i)
            for i in appcast_feed.channel_items(appcast_feed.parse_text(result), "result")
        ]
        self.assertEqual(versions, ["0.74.0"])

    def test_removing_an_absent_version_changes_nothing(self):
        base = feed(item("0.74.0"))
        result, removed = appcast_feed.remove_version(base, "base", "9.9.9")
        self.assertEqual(removed, 0)
        self.assertEqual(result, base)

    def test_survivors_keep_their_bytes(self):
        survivor = item("0.74.0", "            <description><![CDATA[**bold** <item>]]></description>\n")
        base = feed(item("0.75.0"), survivor)
        result, removed = appcast_feed.remove_version(base, "base", "0.75.0")
        self.assertEqual(removed, 1)
        self.assertIn(survivor, result)


if __name__ == "__main__":
    unittest.main()
