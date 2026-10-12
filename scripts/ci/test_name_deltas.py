#!/usr/bin/env python3
"""Regression tests for the delta renaming in sign-and-appcast.sh.

Run: python3 scripts/ci/test_name_deltas.py
"""

import contextlib
import importlib.util
import io
import pathlib
import sys
import tempfile
import unittest

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
SPEC = importlib.util.spec_from_file_location("name_deltas", pathlib.Path(__file__).with_name("name-deltas.py"))
name_deltas = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(name_deltas)

import appcast_feed  # noqa: E402

PREFIX = "https://github.com/TableProApp/TablePro/releases/download/v0.81.0/"


def generated(deltas, arch="arm64", prefix=PREFIX):
    """The shape generate_appcast 2.10.0 writes: the bundle's directory name plus both builds."""
    enclosures = "".join(
        f'                <enclosure url="{prefix}TablePro-{arch}140-{build}.delta" '
        f'sparkle:deltaFrom="{build}" length="5820762" type="application/octet-stream" '
        f'sparkle:deltaFromSparkleExecutableSize="1018704" '
        f'sparkle:deltaFromSparkleLocales="de,fr" sparkle:edSignature="sig{build}=="/>\n'
        for build in deltas
    )
    delta_block = f"            <sparkle:deltas>\n{enclosures}            </sparkle:deltas>\n" if deltas else ""
    return (
        '<?xml version="1.0" standalone="yes"?>\n'
        '<rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle" version="2.0">\n'
        "    <channel>\n"
        "        <title>TablePro</title>\n"
        "        <item>\n"
        "            <title>0.81.0</title>\n"
        "            <sparkle:version>140</sparkle:version>\n"
        "            <sparkle:shortVersionString>0.81.0</sparkle:shortVersionString>\n"
        f"{delta_block}"
        f'            <enclosure url="{prefix}TablePro-0.81.0-{arch}.zip" length="33851296" '
        'type="application/octet-stream" sparkle:edSignature="sig=="/>\n'
        "        </item>\n"
        "    </channel>\n"
        "</rss>\n"
    )


class NameDeltasTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.staging = pathlib.Path(self.directory.name) / "staging"
        self.out = pathlib.Path(self.directory.name) / "artifacts"
        self.staging.mkdir()

    def stage(self, builds, arch="arm64", files=None):
        (self.staging / "appcast.xml").write_text(generated(builds, arch), encoding="utf-8")
        for build in builds if files is None else files:
            (self.staging / f"TablePro-{arch}140-{build}.delta").write_bytes(f"delta {build}".encode())

    def run_names(self, arch="arm64"):
        return name_deltas.name_deltas(self.staging, "0.81.0", arch, PREFIX, self.out)

    def run_main(self, expect):
        output = io.StringIO()
        argv = [
            "--staging", str(self.staging), "--version", "0.81.0", "--arch", "arm64",
            "--download-prefix", PREFIX, "--expect", str(expect), "--out-dir", str(self.out),
        ]
        with contextlib.redirect_stdout(output), contextlib.redirect_stderr(output):
            status = name_deltas.main(argv)
        return status, output.getvalue()

    def assertRefused(self, fragment, arch="arm64"):
        with self.assertRaises(appcast_feed.FeedError) as caught:
            self.run_names(arch)
        self.assertIn(fragment, str(caught.exception))

    def test_suffixes_each_delta_with_its_architecture_and_moves_it(self):
        self.stage([139, 138])
        self.run_names()
        self.assertEqual(
            sorted(path.name for path in self.out.iterdir()),
            ["TablePro-0.81.0-from-138-arm64.delta", "TablePro-0.81.0-from-139-arm64.delta"],
        )
        self.assertEqual((self.out / "TablePro-0.81.0-from-139-arm64.delta").read_bytes(), b"delta 139")
        self.assertEqual(list(self.staging.glob("*.delta")), [])

    def test_rewrites_only_the_delta_urls(self):
        self.stage([139])
        self.run_names()
        text = (self.staging / "appcast.xml").read_text(encoding="utf-8")
        expected = generated([139]).replace(
            f"{PREFIX}TablePro-arm64140-139.delta", f"{PREFIX}TablePro-0.81.0-from-139-arm64.delta"
        )
        self.assertEqual(text, expected)

    def test_architectures_never_share_a_name(self):
        self.stage([139], arch="arm64")
        arm64 = self.run_names(arch="arm64")
        self.stage([139], arch="x86_64")
        x86_64 = self.run_names(arch="x86_64")
        self.assertNotEqual(arm64[0].name, x86_64[0].name)
        self.assertEqual(len(list(self.out.iterdir())), 2)

    def test_warns_when_a_staged_release_got_no_delta(self):
        """generate_appcast drops a delta over 7/8 of the full archive and still exits 0."""
        self.stage([139])
        status, output = self.run_main(2)
        self.assertEqual(status, 0)
        self.assertIn("::warning::generate_appcast wrote 1 of 2 arm64 deltas", output)
        self.assertTrue((self.out / "TablePro-0.81.0-from-139-arm64.delta").is_file())

    def test_refuses_more_deltas_than_staged_releases(self):
        self.stage([139, 138])
        status, output = self.run_main(1)
        self.assertEqual(status, 1)
        self.assertIn("::error::", output)

    def test_refuses_a_delta_the_feed_names_but_the_directory_lacks(self):
        self.stage([139, 138], files=[139])
        self.assertRefused("did not write")
        self.assertFalse(self.out.exists())

    def test_refuses_a_delta_outside_the_release_directory(self):
        stray = generated([139]).replace(PREFIX + "TablePro-arm64", PREFIX.replace("v0.81.0", "v0.80.0") + "TablePro-arm64")
        (self.staging / "appcast.xml").write_text(stray, encoding="utf-8")
        self.assertRefused("is not under")

    def test_refuses_a_delta_without_a_source_build(self):
        self.stage([139])
        path = self.staging / "appcast.xml"
        path.write_text(path.read_text(encoding="utf-8").replace(' sparkle:deltaFrom="139"', ""), encoding="utf-8")
        self.assertRefused("carries no sparkle:deltaFrom")

    def test_nothing_staged_leaves_the_feed_alone(self):
        self.stage([])
        self.assertEqual(self.run_main(0), (0, ""))
        self.assertEqual((self.staging / "appcast.xml").read_text(encoding="utf-8"), generated([]))


if __name__ == "__main__":
    unittest.main()
