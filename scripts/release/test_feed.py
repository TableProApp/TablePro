#!/usr/bin/env python3

import io
import json
import os
import plistlib
import sys
import tarfile
import tempfile
import unittest
import zipfile
from contextlib import redirect_stderr, redirect_stdout
from pathlib import Path
from unittest import mock

import feed
import registry
import version

KEY = "cHJvYmUta2V5LW5vdC1hLXJlYWwtb25l"
REPOSITORY = "TableProApp/TablePro"

SIGNATURE = r'''
import hashlib, re
TRAILER = re.compile(r"<!-- sparkle-signatures:.*?-->\s*$", re.S)
def content(text):
    return TRAILER.sub("", text)
def signed(text, key):
    body = content(text)
    signature = hashlib.sha256((key.strip() + body).encode()).hexdigest()
    return body + "<!-- sparkle-signatures:\nedSignature: " + signature + "\nlength: " + str(len(body)) + "\n-->\n"
'''

FAKE_GH = r'''
import hashlib, json, os, shutil, sys
from pathlib import Path
args = sys.argv[1:]
with open(os.environ["FAKE_LOG"], "a") as log:
    log.write(json.dumps(["gh", *args]) + "\n")
releases = Path(os.environ["FAKE_RELEASES"])
def digest(path):
    return "sha256:" + hashlib.sha256(path.read_bytes()).hexdigest()
if args[:2] == ["release", "download"]:
    out = Path(args[args.index("--dir") + 1])
    names = [args[index + 1] for index, arg in enumerate(args) if arg == "--pattern"]
    found = [name for name in names if (releases / args[2] / name).is_file()]
    if not found:
        sys.exit("no assets match the file pattern")
    for name in found:
        shutil.copy(releases / args[2] / name, out / name)
        if name == os.environ.get("FAKE_BAD_DIGEST"):
            with open(out / name, "ab") as handle:
                handle.write(b"x")
elif args[:2] == ["release", "verify-asset"]:
    tag, path = args[2], Path(args[3])
    if os.environ.get("FAKE_DRAFT"):
        sys.exit("no attestations found for tag " + tag)
    if digest(path) != digest(releases / tag / path.name):
        sys.exit("attestation for " + tag + " does not contain subject " + digest(path))
    print("Verification succeeded! " + path.name + " is present in release " + tag)
else:
    sys.exit("fake gh cannot answer " + " ".join(args))
'''

FAKE_GENERATE_APPCAST = SIGNATURE + r'''
import json, os, sys
from pathlib import Path
args = sys.argv[1:]
key = sys.stdin.read()
with open(os.environ["FAKE_LOG"], "a") as log:
    log.write(json.dumps(["generate_appcast", *args, "stdin=" + key.strip()]) + "\n")
def option(name):
    return args[args.index(name) + 1] if name in args else None
stage = Path(args[-1])
appcast = stage / "appcast.xml"
text = content(appcast.read_text())
if os.environ.get("FAKE_PRUNE"):
    appcast.write_text(signed(text, key))
    print("Wrote 0 new updates")
    sys.exit(0)
archive = next(stage.glob("*.tar.xz"))
short = archive.name[len("TablePro-"):-len(".tar.xz")]
lines = ["<item>", "<title>" + short + "</title>"]
if option("--channel"):
    lines.append("<sparkle:channel>" + option("--channel") + "</sparkle:channel>")
if option("--phased-rollout-interval"):
    interval = option("--phased-rollout-interval")
    lines.append("<sparkle:phasedRolloutInterval>" + interval + "</sparkle:phasedRolloutInterval>")
if option("--critical-update-version") is not None:
    lines.append('<sparkle:criticalUpdate sparkle:version="' + option("--critical-update-version") + '"/>')
lines.append("<sparkle:version>" + option("--versions") + "</sparkle:version>")
lines.append("<sparkle:shortVersionString>" + short + "</sparkle:shortVersionString>")
notes = (stage / ("TablePro-" + short + ".md")).read_text()
lines.append('<description sparkle:format="markdown"><![CDATA[' + notes + ']]></description>')
signature = "" if os.environ.get("FAKE_UNSIGNED_ENCLOSURE") else ' sparkle:edSignature="c2ln"'
lines.append('<enclosure url="' + option("--download-url-prefix") + archive.name + '" length="'
             + str(archive.stat().st_size) + '" type="application/octet-stream"' + signature + "/>")
lines.append("</item>")
index = text.index("<item>") if "<item>" in text else text.index("</channel>")
text = text[:index] + "\n".join(lines) + "\n" + text[index:]
appcast.write_text(text if os.environ.get("FAKE_UNSIGNED_FEED") else signed(text, key))
print("Wrote 1 new update")
'''

FAKE_SIGN_UPDATE = SIGNATURE + r'''
import json, os, sys
from pathlib import Path
args = sys.argv[1:]
key = sys.stdin.read()
with open(os.environ["FAKE_LOG"], "a") as log:
    log.write(json.dumps(["sign_update", *args, "stdin=" + key.strip()]) + "\n")
path = Path(args[-1])
text = path.read_text()
if "--verify" in args:
    if signed(text, key) != text:
        print("Error: failed to pass signing verification.")
        sys.exit(1)
    sys.exit(0)
path.write_text(signed(text, key))
print("<!-- Updated signature inside appcast.xml -->")
'''

SEED = """<?xml version="1.0" encoding="utf-8"?>
<rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle" version="2.0">
    <channel>
        <title>TablePro</title>
        <item>
            <title>0.81.0</title>
            <sparkle:criticalUpdate />
            <sparkle:version>140</sparkle:version>
            <sparkle:shortVersionString>0.81.0</sparkle:shortVersionString>
            <description sparkle:format="markdown"><![CDATA[# 0.81.0]]></description>
            <enclosure url="https://example.com/TablePro-0.81.0.zip" length="10" sparkle:edSignature="c2ln" />
        </item>
        <item>
            <title>0.80.0</title>
            <sparkle:phasedRolloutInterval>21600</sparkle:phasedRolloutInterval>
            <sparkle:version>139</sparkle:version>
            <sparkle:shortVersionString>0.80.0</sparkle:shortVersionString>
            <enclosure url="https://example.com/TablePro-0.80.0.zip" length="10" sparkle:edSignature="c2ln" />
        </item>
    </channel>
</rss>
"""
METADATA = {
    "retainFromPluginKit": 39,
    "plugins": {
        "OracleDriver": {"name": "Oracle Driver"},
        "ParquetExport": {"name": "Parquet Export"},
    },
}


def item(build, short, channel=None, critical=None, signature="c2ln", url=None):
    lines = ["<item>"]
    if channel is not None:
        lines.append(f"<sparkle:channel>{channel}</sparkle:channel>")
    if critical is not None:
        lines.append(f'<sparkle:criticalUpdate sparkle:version="{critical}"/>' if critical else
                     "<sparkle:criticalUpdate/>")
    lines += [f"<sparkle:version>{build}</sparkle:version>",
              f"<sparkle:shortVersionString>{short}</sparkle:shortVersionString>"]
    signed = f' sparkle:edSignature="{signature}"' if signature else ""
    url = url or f"https://example.com/TablePro-{short}.tar.xz"
    lines += [f'<enclosure url="{url}" length="10"{signed}/>', "</item>"]
    return "\n".join(lines)


def appcast(*items):
    return (f'<rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle" version="2.0"><channel>'
            f'<title>TablePro</title>{"".join(items)}</channel></rss>').encode()


def fake_signed(text, key=KEY):
    namespace = {}
    exec(SIGNATURE, namespace)
    return namespace["signed"](text, key)


class FeedRulesTests(unittest.TestCase):
    def test_the_new_item_must_be_there_once(self):
        release = version.parse_tag("v0.82.0-beta.1")
        url = "https://example.com/TablePro-0.82.0-beta.1.tar.xz"
        present = feed.parse_items(appcast(item(820001, "0.82.0-beta.1", "beta"), item(140, "0.81.0")))
        self.assertEqual(feed.new_item_problems(present, release, url), [])
        cases = [
            appcast(item(820001, "0.82.0-beta.1")),
            appcast(item(820001, "0.82.0-beta.1", "beta", url="https://example.com/other.tar.xz")),
            appcast(item(820001, "0.82.0-beta.1", "beta"), item(820001, "0.82.0-beta.1", "beta")),
        ]
        for data, count in zip(cases, (0, 0, 2)):
            with self.subTest(data=data):
                self.assertEqual(feed.new_item_problems(feed.parse_items(data), release, url),
                                 [f"appcast.xml has {count} beta items for 0.82.0-beta.1 (820001) at {url}, not one"])

    def test_a_new_item_with_no_signature_names_the_key(self):
        release = version.parse_tag("v0.82.0")
        items = feed.parse_items(appcast(item(820099, "0.82.0", signature="")))
        self.assertEqual(feed.new_item_problems(items, release, "https://example.com/TablePro-0.82.0.tar.xz"), [
            "0.82.0's enclosure has no sparkle:edSignature; "
            "SPARKLE_PRIVATE_KEY does not match the archive's SUPublicEDKey"])

    def test_the_critical_build_carries_forward(self):
        items = feed.parse_items(appcast(item(820099, "0.82.0", critical="140"), item(140, "0.81.0", critical=""),
                                         item(830001, "0.83.0-beta.1", "beta")))
        self.assertEqual(feed.carried_critical(items), 140)
        self.assertEqual(feed.carried_critical(feed.parse_items(SEED.encode())), 140)
        self.assertIsNone(feed.carried_critical(feed.parse_items(appcast(item(139, "0.80.0")))))

    def test_the_highest_stable_in_the_feed(self):
        items = feed.parse_items(appcast(item(830001, "0.83.0-beta.1", "beta"), item(820199, "0.82.1"),
                                         item(820099, "0.82.0"), item(140, "0.81.0")))
        self.assertEqual(str(feed.highest_stable(items)), "0.82.1")
        self.assertEqual(str(feed.highest_stable(feed.parse_items(SEED.encode()))), "0.81.0")
        self.assertIsNone(feed.highest_stable(feed.parse_items(appcast(item(830001, "0.83.0-beta.1", "beta")))))

    def test_the_generate_appcast_arguments(self):
        stage = Path("/stage")
        prefix = ["--ed-key-file", "-", "--embed-release-notes", "--maximum-deltas", "0"]
        beta = feed.appcast_arguments(stage, "v0.82.0-beta.1", version.parse_tag("v0.82.0-beta.1"), None, REPOSITORY)
        self.assertEqual(beta, prefix + [
            "--versions", "820001",
            "--download-url-prefix", "https://github.com/TableProApp/TablePro/releases/download/v0.82.0-beta.1/",
            "--full-release-notes-url", "https://docs.tablepro.app/changelog",
            "--channel", "beta", "/stage"])
        stable = feed.appcast_arguments(stage, "v0.82.0", version.parse_tag("v0.82.0"), 140, REPOSITORY)
        self.assertEqual(stable[stable.index("--full-release-notes-url") + 1], "https://docs.tablepro.app/changelog")
        self.assertEqual(stable[stable.index("--phased-rollout-interval"):],
                         ["--phased-rollout-interval", "21600", "--critical-update-version", "140", "/stage"])
        plain = feed.appcast_arguments(stage, "v0.82.1", version.parse_tag("v0.82.1"), None, REPOSITORY)
        self.assertNotIn("--critical-update-version", plain)
        self.assertNotIn("--channel", plain)

    def test_removes_items_by_version_and_keeps_the_rest(self):
        edited, removed = feed.remove_items(SEED.encode(), "0.80.0")
        self.assertEqual(removed, 1)
        self.assertEqual(feed.parse_items(edited), feed.parse_items(SEED.encode())[:1])
        self.assertIn(b"<![CDATA[# 0.81.0]]>", edited)

    def test_an_item_end_tag_in_the_notes_does_not_block_a_withdraw(self):
        text = SEED.replace("# 0.81.0", "# 0.81.0 </item> in the notes").encode()
        edited, removed = feed.remove_items(text, "0.81.0")
        self.assertEqual(removed, 1)
        self.assertEqual([each.short_version for each in feed.parse_items(edited)], ["0.80.0"])


def app_archive(path, text, build):
    info = plistlib.dumps({"CFBundleShortVersionString": text, "CFBundleVersion": str(build)})
    with tarfile.open(path, "w:xz") as archive:
        member = tarfile.TarInfo("TablePro.app/Contents/Info.plist")
        member.size = len(info)
        archive.addfile(member, io.BytesIO(info))


def plugin_zip(path, target, text, build, kit=39, **extra):
    info = {"CFBundleIdentifier": f"com.TablePro.{target}", "CFBundleShortVersionString": text,
            "CFBundleVersion": str(build), "TableProPluginKitVersion": kit, "LSMinimumSystemVersion": "13.0",
            **extra}
    with zipfile.ZipFile(path, "w") as archive:
        archive.writestr(f"{target}.tableplugin/Contents/Info.plist", plistlib.dumps(info))


class FeedSiteTests(unittest.TestCase):
    def setUp(self):
        directory = tempfile.TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        self.base = Path(directory.name)
        self.tools = self.base / "bin"
        self.tools.mkdir()
        for name, source in (("gh", FAKE_GH), ("generate_appcast", FAKE_GENERATE_APPCAST),
                             ("sign_update", FAKE_SIGN_UPDATE)):
            path = self.tools / name
            path.write_text(f"#!{sys.executable}\n{source}")
            path.chmod(0o755)
        self.log_path = self.base / "calls.log"
        self.releases = self.base / "releases"
        environment = mock.patch.dict(os.environ, {
            "PATH": f"{self.tools}{os.pathsep}{os.environ['PATH']}",
            "FAKE_LOG": str(self.log_path),
            "FAKE_RELEASES": str(self.releases),
        })
        environment.start()
        self.addCleanup(environment.stop)

        self.site = self.base / "gh-pages"
        (self.site / "plugins").mkdir(parents=True)
        (self.site / "appcast.xml").write_text(fake_signed(SEED))
        registry.write_manifest(self.site / "plugins/v3.json", registry.empty_manifest(39))

        self.root = self.base / "tag"
        (self.root / ".github").mkdir(parents=True)
        (self.root / ".github/plugin-registry.json").write_text(json.dumps(METADATA))
        (self.root / "Configs").mkdir()
        (self.root / "Configs/PluginKit.xcconfig").write_text(
            "TABLEPRO_PLUGINKIT_VERSION = 39\nTABLEPRO_PLUGINKIT_MINIMUM_VERSION = 19\n")
        self.notes = self.base / "feed.md"
        self.notes.write_text("- A fix. (#1)\n")

    def publish(self, tag, kit=39, archive=None):
        release = version.parse_tag(tag)
        folder = self.releases / tag
        folder.mkdir(parents=True)
        app_archive(folder / f"TablePro-{release}.tar.xz", *(archive or (str(release), release.build)))
        plugin_zip(folder / f"OracleDriver-{release}.zip", "OracleDriver", str(release), release.build, kit,
                   TableProProvidesDatabaseTypeIds=["Oracle"])
        plugin_zip(folder / f"ParquetExport-{release}.zip", "ParquetExport", str(release), release.build, kit,
                   TableProProvidesExportFormatIds=["parquet"])

    def add(self, tag, critical=False):
        messages = []
        changed = feed.add(self.root, self.site, tag, self.notes, critical, self.tools, KEY,
                           feed.Releases(REPOSITORY), REPOSITORY, log=messages.append)
        return changed, messages

    def withdraw(self, text):
        return feed.withdraw(self.site, text, self.tools, KEY, log=lambda message: None)

    def files(self):
        return [(self.site / name).read_bytes() for name in ("appcast.xml", "plugins/v3.json")]

    def calls(self, tool):
        if not self.log_path.exists():
            return []
        return [call[1:] for call in map(json.loads, self.log_path.read_text().splitlines()) if call[0] == tool]

    def published(self, path):
        return (self.site / path).read_text()

    def test_adds_a_beta_and_its_plugins(self):
        self.publish("v0.82.0-beta.1")
        changed, messages = self.add("v0.82.0-beta.1")
        self.assertTrue(changed)
        (generate,) = self.calls("generate_appcast")
        self.assertEqual(generate[-1], f"stdin={KEY}")
        self.assertEqual([call for call in self.calls("sign_update") if "--verify" not in call], [])
        self.assertIn("--channel", generate)
        self.assertNotIn("--critical-update-version", generate)
        self.assertNotIn("--phased-rollout-interval", generate)
        verified = [call[3] for call in self.calls("gh") if call[:2] == ["release", "verify-asset"]]
        self.assertEqual([Path(path).name for path in verified], [
            "TablePro-0.82.0-beta.1.tar.xz", "OracleDriver-0.82.0-beta.1.zip", "ParquetExport-0.82.0-beta.1.zip"])
        self.assertIn("Verification succeeded! OracleDriver-0.82.0-beta.1.zip is present in release v0.82.0-beta.1",
                      messages)
        published = self.published("appcast.xml")
        self.assertEqual(fake_signed(published), published)
        items = feed.parse_items(published.encode())
        self.assertEqual([(each.short_version, each.channel) for each in items],
                         [("0.82.0-beta.1", "beta"), ("0.81.0", None), ("0.80.0", None)])
        manifest = json.loads(self.published("plugins/v3.json"))
        self.assertEqual([plugin["id"] for plugin in manifest["plugins"]],
                         ["com.TablePro.OracleDriver", "com.TablePro.ParquetExport"])
        oracle, parquet = manifest["plugins"]
        self.assertEqual((oracle["databaseTypeIds"], oracle["exportFormatIds"]), (["Oracle"], []))
        self.assertEqual((parquet["databaseTypeIds"], parquet["exportFormatIds"]), ([], ["parquet"]))
        self.assertEqual(oracle["releases"][0]["url"],
                         "https://github.com/TableProApp/TablePro/releases/download/v0.82.0-beta.1/"
                         "OracleDriver-0.82.0-beta.1.zip")
        self.assertEqual(oracle["releases"][0]["channel"], "beta")

    def test_a_stable_carries_the_critical_build_and_phases(self):
        self.publish("v0.82.0")
        self.add("v0.82.0")
        (generate,) = self.calls("generate_appcast")
        self.assertEqual(generate[generate.index("--phased-rollout-interval") + 1], "21600")
        self.assertEqual(generate[generate.index("--critical-update-version") + 1], "140")

    def test_a_critical_stable_is_critical_below_its_own_build(self):
        self.publish("v0.82.0")
        self.add("v0.82.0", critical=True)
        (generate,) = self.calls("generate_appcast")
        self.assertEqual(generate[generate.index("--critical-update-version") + 1], "820099")

    def test_a_critical_beta_is_refused(self):
        with self.assertRaisesRegex(feed.FeedError, "a beta is never critical"):
            self.add("v0.82.0-beta.1", critical=True)

    def test_a_rerun_changes_nothing(self):
        self.publish("v0.82.0-beta.1")
        self.add("v0.82.0-beta.1")
        written = self.files()
        changed, messages = self.add("v0.82.0-beta.1")
        self.assertFalse(changed)
        self.assertEqual(self.files(), written)
        self.assertEqual(len(self.calls("generate_appcast")), 1)
        self.assertIn("appcast.xml already has 0.82.0-beta.1 (820001)", messages)

    def test_an_archive_of_another_build_is_refused(self):
        self.publish("v0.82.0-beta.1", archive=("0.82.0-beta.1", 140))
        written = self.files()
        with self.assertRaisesRegex(feed.FeedError, r"holds 0.82.0-beta.1 \(140\), not 0.82.0-beta.1 \(820001\)"):
            self.add("v0.82.0-beta.1")
        self.assertEqual(self.calls("generate_appcast"), [])
        self.assertEqual(self.files(), written)

    def test_an_item_sparkle_prunes_on_arrival_leaves_the_appcast_alone(self):
        self.publish("v0.79.1")
        with mock.patch.dict(os.environ, {"FAKE_PRUNE": "1"}):
            changed, messages = self.add("v0.79.1")
        self.assertTrue(changed)
        self.assertEqual(self.published("appcast.xml"), fake_signed(SEED))
        self.assertIn("generate_appcast keeps newer items on 0.79.1's branch, so appcast.xml stays as it is", messages)
        self.assertEqual(len(json.loads(self.published("plugins/v3.json"))["plugins"]), 2)

    def test_a_new_item_with_no_signature_writes_nothing(self):
        self.publish("v0.82.0-beta.1")
        written = self.files()
        with mock.patch.dict(os.environ, {"FAKE_UNSIGNED_ENCLOSURE": "1"}):
            with self.assertRaisesRegex(feed.FeedError, "0.82.0-beta.1's enclosure has no sparkle:edSignature"):
                self.add("v0.82.0-beta.1")
        self.assertEqual(self.files(), written)

    def test_an_unsigned_feed_from_generate_appcast_writes_nothing(self):
        self.publish("v0.82.0-beta.1")
        written = self.files()
        with mock.patch.dict(os.environ, {"FAKE_UNSIGNED_FEED": "1"}):
            with self.assertRaisesRegex(feed.FeedError, "fails its checks, so nothing was written:\n  sign_update failed"):
                self.add("v0.82.0-beta.1")
        self.assertEqual(self.files(), written)

    def test_a_feed_changed_outside_ci_is_refused(self):
        self.publish("v0.82.0-beta.1")
        (self.site / "appcast.xml").write_text(fake_signed(SEED).replace("TablePro-0.81.0.zip", "evil.zip"))
        written = self.files()
        for attempt in (lambda: self.add("v0.82.0-beta.1"), lambda: self.withdraw("0.80.0")):
            with self.subTest(attempt=attempt):
                with self.assertRaisesRegex(feed.FeedError, "signature does not verify; it changed outside CI"):
                    attempt()
                self.assertEqual(self.files(), written)
        self.assertEqual(self.calls("gh"), [])

    def test_a_wrong_digest_is_refused(self):
        self.publish("v0.82.0-beta.1")
        with mock.patch.dict(os.environ, {"FAKE_BAD_DIGEST": "TablePro-0.82.0-beta.1.tar.xz"}):
            with self.assertRaisesRegex(feed.FeedError, "attestation for v0.82.0-beta.1 does not contain subject"):
                self.add("v0.82.0-beta.1")
        self.assertEqual(self.calls("generate_appcast"), [])

    def test_a_draft_is_refused(self):
        self.publish("v0.82.0-beta.1")
        with mock.patch.dict(os.environ, {"FAKE_DRAFT": "1"}):
            with self.assertRaisesRegex(feed.FeedError, "no attestations found for tag v0.82.0-beta.1"):
                self.add("v0.82.0-beta.1")

    def test_a_missing_asset_is_refused(self):
        self.publish("v0.82.0-beta.1")
        (self.releases / "v0.82.0-beta.1/ParquetExport-0.82.0-beta.1.zip").unlink()
        with self.assertRaisesRegex(feed.FeedError, "v0.82.0-beta.1 has no ParquetExport-0.82.0-beta.1.zip"):
            self.add("v0.82.0-beta.1")

    def test_a_plugin_built_against_another_kit_is_refused(self):
        self.publish("v0.82.0-beta.1", kit=38)
        written = self.files()
        with self.assertRaisesRegex(registry.RegistryError, "TableProPluginKitVersion is 38"):
            self.add("v0.82.0-beta.1")
        self.assertEqual(self.files(), written)

    def test_withdraw_removes_the_version_and_re_signs(self):
        self.publish("v0.82.0-beta.1")
        self.publish("v0.82.0")
        self.add("v0.82.0-beta.1")
        self.add("v0.82.0")
        signed_before = sum("--verify" not in call for call in self.calls("sign_update"))
        self.assertTrue(self.withdraw("0.82.0"))
        published = self.published("appcast.xml")
        self.assertEqual([each.short_version for each in feed.parse_items(published.encode())],
                         ["0.82.0-beta.1", "0.81.0", "0.80.0"])
        self.assertEqual(fake_signed(published), published)
        self.assertEqual(sum("--verify" not in call for call in self.calls("sign_update")), signed_before + 1)
        self.assertEqual(json.loads(self.published("plugins/v3.json"))["plugins"], [])
        self.assertFalse(self.withdraw("0.82.0"))

    def test_withdraw_keeps_a_default_channel_item(self):
        (self.site / "appcast.xml").write_text(fake_signed(feed.remove_items(SEED.encode(), "0.80.0")[0].decode()))
        with self.assertRaisesRegex(feed.FeedError, "no default-channel item"):
            self.withdraw("0.81.0")

    def test_latest_prints_the_highest_stable_left(self):
        self.publish("v0.82.0-beta.1")
        self.publish("v0.82.0")
        self.add("v0.82.0-beta.1")
        self.add("v0.82.0")
        self.withdraw("0.82.0")
        with redirect_stdout(io.StringIO()) as output:
            self.assertEqual(feed.main(["latest", "--site", str(self.site)]), 0)
        self.assertEqual(output.getvalue(), "0.81.0\n")

    def test_main_needs_the_sparkle_tools_and_key(self):
        command = ["withdraw", "0.82.0", "--site", str(self.site)]
        with mock.patch.dict(os.environ, {"SPARKLE_BIN": "", "SPARKLE_PRIVATE_KEY": KEY}), \
                redirect_stderr(io.StringIO()) as errors:
            self.assertEqual(feed.main(command), 1)
        self.assertIn("SPARKLE_BIN is not set", errors.getvalue())
        with mock.patch.dict(os.environ, {"SPARKLE_BIN": str(self.tools), "SPARKLE_PRIVATE_KEY": ""}), \
                redirect_stderr(io.StringIO()) as errors:
            self.assertEqual(feed.main(command), 1)
        self.assertIn("SPARKLE_PRIVATE_KEY is not set", errors.getvalue())


if __name__ == "__main__":
    unittest.main()
