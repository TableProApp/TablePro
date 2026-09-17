#!/usr/bin/env python3
"""Regression tests for the Sparkle feed merge.

This script edits the file every install polls, and the release job is the only thing that runs
it. So the invariants are tested here, on the free Linux runner, rather than discovered by a user
whose updater has gone quiet.

Run: python3 scripts/ci/test_merge_appcast.py
"""

import importlib.util
import pathlib
import sys
import tempfile
import unittest

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
SPEC = importlib.util.spec_from_file_location(
    "merge_appcast", pathlib.Path(__file__).with_name("merge-appcast.py")
)
merge_appcast = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(merge_appcast)

import appcast_feed  # noqa: E402

PREFIX = "https://github.com/TableProApp/TablePro/releases/download/v0.75.0/"


def item(version, build, arch, notes="Fixed a thing.", deltas=(), prefix=None):
    prefix = PREFIX if prefix is None else prefix
    hardware = (
        f"            <sparkle:hardwareRequirements>arch</sparkle:hardwareRequirements>\n".replace(
            "arch", arch
        )
        if arch
        else ""
    )
    delta_block = ""
    if deltas:
        enclosures = "\n".join(
            f'                <enclosure url="{url}" sparkle:deltaFrom="129" length="1" '
            f'sparkle:edSignature="dsig==" type="application/octet-stream"/>'
            for url in deltas
        )
        delta_block = f"            <sparkle:deltas>\n{enclosures}\n            </sparkle:deltas>\n"
    suffix = f"-{arch}" if arch else "-x86_64"
    return (
        "        <item>\n"
        f"            <title>{version}</title>\n"
        "            <pubDate>Sat, 13 Sep 2026 10:00:00 +0000</pubDate>\n"
        f"            <sparkle:version>{build}</sparkle:version>\n"
        f"            <sparkle:shortVersionString>{version}</sparkle:shortVersionString>\n"
        "            <sparkle:minimumSystemVersion>14.0</sparkle:minimumSystemVersion>\n"
        f"{hardware}"
        f"            <description><![CDATA[<p>{notes}</p>]]></description>\n"
        f"{delta_block}"
        f'            <enclosure url="{prefix}TablePro-{version}{suffix}.zip" '
        f'sparkle:edSignature="sig==" length="123" type="application/octet-stream"/>\n'
        "        </item>\n"
    )


def feed(*items):
    return (
        '<?xml version="1.0" standalone="yes"?>\n'
        '<rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle" version="2.0">\n'
        "    <channel>\n"
        "        <title>TablePro</title>\n"
        + "".join(items)
        + "    </channel>\n"
        "</rss>\n"
    )


BASE = feed(item("0.74.0", 130, "arm64"), item("0.74.0", 130, None), item("0.73.0", 129, "arm64"))


PUBLISHED = pathlib.Path(__file__).resolve().parents[2] / "appcast.xml"


def succeeding(base):
    """The version and build a release cut right now would carry, read from the feed itself.

    Pinning them to the version in Configs/Version.xcconfig makes every test using the published
    feed fail the moment that release is published, because the feed then advertises it and the
    merge refuses a version it already carries.
    """
    items = merge_appcast.channel_items(merge_appcast.parse_text(base), "base")
    newest = merge_appcast.item_short_version(items[0]).split(".")
    newest[-1] = str(int(newest[-1]) + 1)
    builds = [int(b) for b in (merge_appcast.item_bundle_version(i) for i in items) if b]
    return ".".join(newest), max(builds) + 1


class MergeAppcastTests(unittest.TestCase):
    def merge(self, base=BASE, arm64=None, x86_64=None, version="0.75.0", prefix=PREFIX, keep_releases=0, build=131):
        arm64 = feed(item(version, build, "arm64")) if arm64 is None else arm64
        x86_64 = feed(item(version, build, None)) if x86_64 is None else x86_64
        with tempfile.TemporaryDirectory() as directory:
            work = pathlib.Path(directory)
            (work / "base.xml").write_text(base, encoding="utf-8")
            (work / "arm64.xml").write_text(arm64, encoding="utf-8")
            (work / "x86_64.xml").write_text(x86_64, encoding="utf-8")
            return merge_appcast.merge(
                work / "base.xml",
                work / "arm64.xml",
                work / "x86_64.xml",
                version,
                prefix,
                work / "out.xml",
                keep_releases,
            )

    def versions(self, merged):
        items = merge_appcast.channel_items(merge_appcast.parse_text(merged), "merged")
        return [merge_appcast.item_short_version(i) for i in items]

    def assertRefused(self, fragment, **kwargs):
        with self.assertRaises(merge_appcast.MergeError) as caught:
            self.merge(**kwargs)
        self.assertIn(fragment, str(caught.exception))

    def test_new_items_lead_the_feed_arm64_first(self):
        merged = self.merge()
        items = merge_appcast.channel_items(merge_appcast.parse_text(merged), "merged")
        self.assertEqual([merge_appcast.item_short_version(i) for i in items[:2]], ["0.75.0", "0.75.0"])
        self.assertIsNotNone(items[0].find(merge_appcast.HARDWARE))
        self.assertIsNone(items[1].find(merge_appcast.HARDWARE))
        self.assertEqual(len(items), 5)

    def test_every_other_item_survives_byte_for_byte(self):
        merged = self.merge()
        inserted = item("0.75.0", 131, "arm64") + item("0.75.0", 131, None)
        self.assertIn(inserted, merged)
        self.assertEqual(merged.replace(inserted, "", 1), BASE)

    def test_release_notes_containing_the_closing_tag_survive(self):
        """The awk merge this replaced scanned for the literal, so a changelog entry broke the feed."""
        notes = "Fixed the parser on a literal &lt;/item&gt; in a cell."
        merged = self.merge(arm64=feed(item("0.75.0", 131, "arm64", notes=notes)))
        items = merge_appcast.channel_items(merge_appcast.parse_text(merged), "merged")
        self.assertEqual(len(items), 5)
        self.assertIn(notes, merged)

    def test_refuses_a_version_the_base_already_advertises(self):
        older = PREFIX.replace("v0.75.0", "v0.74.0")
        self.assertRefused(
            "already advertises",
            version="0.74.0",
            prefix=older,
            arm64=feed(item("0.74.0", 131, "arm64", prefix=older)),
            x86_64=feed(item("0.74.0", 131, None, prefix=older)),
        )

    def test_refuses_a_build_number_that_did_not_increase(self):
        self.assertRefused(
            "not below the new build",
            arm64=feed(item("0.75.0", 130, "arm64")),
            x86_64=feed(item("0.75.0", 130, None)),
        )

    def test_refuses_an_arm64_item_with_no_hardware_requirement(self):
        self.assertRefused("no <sparkle:hardwareRequirements>", arm64=feed(item("0.75.0", 131, None)))

    def test_refuses_an_x86_64_item_carrying_a_hardware_requirement(self):
        self.assertRefused(
            "carries <sparkle:hardwareRequirements>", x86_64=feed(item("0.75.0", 131, "arm64"))
        )

    def test_refuses_architectures_that_disagree_on_the_build(self):
        self.assertRefused("disagree on <sparkle:version>", x86_64=feed(item("0.75.0", 132, None)))

    def test_refuses_an_enclosure_outside_the_release_directory(self):
        stray = feed(item("0.75.0", 131, "arm64")).replace(PREFIX, PREFIX.replace("v0.75.0", "v0.74.0"))
        self.assertRefused("is not under", arm64=stray)

    def test_refuses_a_delta_enclosure_outside_the_release_directory(self):
        strayed = feed(
            item("0.75.0", 131, "arm64", deltas=[PREFIX.replace("v0.75.0", "v0.74.0") + "d.delta"])
        )
        self.assertRefused("is not under", arm64=strayed)

    def test_accepts_a_delta_enclosure_inside_the_release_directory(self):
        merged = self.merge(
            arm64=feed(item("0.75.0", 131, "arm64", deltas=[PREFIX + "TablePro0.74.0-0.75.0.delta"]))
        )
        self.assertIn("sparkle:deltas", merged)

    def test_refuses_an_unsigned_enclosure(self):
        """generate_appcast drops the signature and still exits 0 when SUPublicEDKey is absent."""
        unsigned = feed(item("0.75.0", 131, "arm64")).replace(' sparkle:edSignature="sig=="', "")
        self.assertRefused("carries no sparkle:edSignature", arm64=unsigned)

    def test_refuses_an_unsigned_delta_enclosure(self):
        strayed = feed(item("0.75.0", 131, "arm64", deltas=[PREFIX + "d.delta"])).replace(
            ' sparkle:edSignature="dsig=="', ""
        )
        self.assertRefused("carries no sparkle:edSignature", arm64=strayed)

    def test_refuses_more_than_one_item_per_architecture(self):
        two = feed(item("0.75.0", 131, "arm64"), item("0.74.0", 130, "arm64"))
        self.assertRefused("expected exactly one item", arm64=two)

    def test_refuses_a_generated_feed_holding_a_different_version(self):
        self.assertRefused("expected exactly one item", arm64=feed(item("0.74.9", 131, "arm64")))

    def test_splices_into_a_feed_that_holds_no_items_yet(self):
        merged = self.merge(base=feed())
        items = merge_appcast.channel_items(merge_appcast.parse_text(merged), "merged")
        self.assertEqual(len(items), 2)

    def test_the_published_feed_is_a_valid_base(self):
        base = PUBLISHED.read_text(encoding="utf-8")
        version, build = succeeding(base)
        merged = self.merge(base=base, version=version, build=build)
        versions = self.versions(merged)
        self.assertEqual(versions[:2], [version, version])
        published = merge_appcast.channel_items(merge_appcast.parse_text(base), "base")
        self.assertEqual(len(versions), len(published) + 2)

    def test_keeps_every_release_when_pruning_is_off(self):
        self.assertEqual(self.versions(self.merge(keep_releases=0)), ["0.75.0", "0.75.0", "0.74.0", "0.74.0", "0.73.0"])

    def test_prunes_to_the_newest_releases(self):
        merged = self.merge(keep_releases=2)
        self.assertEqual(self.versions(merged), ["0.75.0", "0.75.0", "0.74.0", "0.74.0"])

    def test_pruning_keeps_the_arm64_item_first(self):
        merged = self.merge(keep_releases=1)
        items = merge_appcast.channel_items(merge_appcast.parse_text(merged), "merged")
        self.assertEqual(self.versions(merged), ["0.75.0", "0.75.0"])
        self.assertIsNotNone(items[0].find(merge_appcast.HARDWARE))
        self.assertIsNone(items[1].find(merge_appcast.HARDWARE))

    def test_pruning_a_feed_shorter_than_the_limit_drops_nothing(self):
        self.assertEqual(self.versions(self.merge(keep_releases=99)), ["0.75.0", "0.75.0", "0.74.0", "0.74.0", "0.73.0"])

    def test_pruning_keeps_the_retained_items_byte_for_byte(self):
        """The kept items are moved, never re-serialized: an entity-escaped CDATA block would grow
        the feed by 9% and make every future diff unreadable."""
        merged = self.merge(keep_releases=2)
        kept = appcast_feed.item_spans(merged)
        survivor = merged[kept[2][0]:kept[3][1]]
        original = appcast_feed.item_spans(BASE)
        self.assertEqual(survivor, BASE[original[0][0]:original[1][1]])

    def test_pruning_the_published_feed_bounds_its_size(self):
        base = PUBLISHED.read_text(encoding="utf-8")
        version, build = succeeding(base)
        merged = self.merge(base=base, version=version, build=build, keep_releases=merge_appcast.DEFAULT_KEEP_RELEASES)
        versions = self.versions(merged)
        self.assertEqual(versions[:2], [version, version])
        self.assertEqual(len(dict.fromkeys(versions)), merge_appcast.DEFAULT_KEEP_RELEASES)
        kept = self.merge(base=base, version=version, build=build)
        self.assertLess(len(merged), len(kept))
        self.assertNotIn(merge_appcast.releases_in_order(base, "base")[-1], versions)


if __name__ == "__main__":
    unittest.main()
