#!/usr/bin/env python3

import io
import json
import os
import plistlib
import subprocess
import sys
import tarfile
import tempfile
import unittest
import zipfile
from contextlib import redirect_stderr
from pathlib import Path
from unittest import mock

import feed
import publish
import registry
import version

KEY = "cHJvYmUta2V5LW5vdC1hLXJlYWwtb25l"
REPOSITORY = "TableProApp/TablePro"
GIT_ENV = {
    "GIT_CONFIG_GLOBAL": os.devnull,
    "GIT_CONFIG_NOSYSTEM": "1",
    "GIT_AUTHOR_NAME": "Fixture",
    "GIT_AUTHOR_EMAIL": "fixture@example.com",
    "GIT_COMMITTER_NAME": "Fixture",
    "GIT_COMMITTER_EMAIL": "fixture@example.com",
}

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

FAKE_GH = SIGNATURE + r'''
import json, os, shutil, sys
from pathlib import Path
args = sys.argv[1:]
with open(os.environ["FAKE_LOG"], "a") as log:
    log.write(json.dumps(["gh", *args]) + "\n")
releases = Path(os.environ["FAKE_RELEASES"])
if args[:2] == ["release", "view"]:
    folder = releases / args[2]
    if not folder.is_dir():
        sys.exit("release not found")
    assets = []
    for path in sorted(folder.iterdir()):
        digest = "sha256:" + hashlib.sha256(path.read_bytes()).hexdigest()
        if path.name == os.environ.get("FAKE_BAD_DIGEST"):
            digest = "sha256:" + "0" * 64
        assets.append({"name": path.name, "digest": digest, "state": "uploaded"})
    print(json.dumps({"isDraft": os.environ.get("FAKE_DRAFT") == "1", "assets": assets}))
elif args[:2] == ["release", "download"]:
    out = Path(args[args.index("--dir") + 1])
    for index, arg in enumerate(args):
        if arg == "--pattern":
            shutil.copy(releases / args[2] / args[index + 1], out / args[index + 1])
elif args[:2] != ["release", "edit"]:
    sys.exit("fake gh cannot answer " + " ".join(args))
'''

FAKE_GENERATE_APPCAST = SIGNATURE + r'''
import json, os, subprocess, sys
from pathlib import Path
args = sys.argv[1:]
key = sys.stdin.read()
with open(os.environ["FAKE_LOG"], "a") as log:
    log.write(json.dumps(["generate_appcast", *args, "stdin=" + key.strip()]) + "\n")
race = os.environ.get("FAKE_RACE_REPO")
if race and not os.path.exists(race + ".done"):
    open(race + ".done", "w").close()
    subprocess.run(["git", "-C", race, "push", "--quiet", "origin", "HEAD:refs/heads/feeds"], check=True)
def option(name):
    return args[args.index(name) + 1] if name in args else None
stage = Path(args[-1])
appcast = stage / "appcast.xml"
if os.environ.get("FAKE_PRUNE"):
    appcast.write_text(content(appcast.read_text()))
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
text = content(appcast.read_text())
index = text.index("<item>") if "<item>" in text else text.index("</channel>")
appcast.write_text(text[:index] + "\n".join(lines) + "\n" + text[index:])
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
    if os.environ.get("FAKE_VERIFY_FAIL") or signed(text, key) != text:
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
        "OracleDriver": {"name": "Oracle Driver", "iconName": "oracle-icon"},
        "ParquetExport": {"name": "Parquet Export", "iconName": "parquet-icon"},
    },
}
PROJECT = """aggregateTargets:
  BundledPlugins:
    targets:
      - MySQLDriver
"""


def item(build, short, channel=None, critical=None, signature="c2ln", length="10"):
    lines = ["<item>"]
    if channel is not None:
        lines.append(f"<sparkle:channel>{channel}</sparkle:channel>")
    if critical is not None:
        lines.append(f'<sparkle:criticalUpdate sparkle:version="{critical}"/>' if critical else
                     "<sparkle:criticalUpdate/>")
    lines += [f"<sparkle:version>{build}</sparkle:version>",
              f"<sparkle:shortVersionString>{short}</sparkle:shortVersionString>"]
    signed = f' sparkle:edSignature="{signature}"' if signature else ""
    lines += [f'<enclosure url="https://example.com/TablePro-{short}.tar.xz" length="{length}"{signed}/>', "</item>"]
    return "\n".join(lines)


def appcast(*items):
    return (f'<rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle" version="2.0"><channel>'
            f'<title>TablePro</title>{"".join(items)}</channel></rss>').encode()


class FeedRulesTests(unittest.TestCase):
    def test_a_clean_feed_passes(self):
        self.assertEqual(feed.feed_problems(appcast(item(820001, "0.82.0-beta.1", "beta"), item(140, "0.81.0"))), [])

    def test_each_rule(self):
        cases = [
            (appcast(item(140, "0.81.0", signature="")), "has no sparkle:edSignature"),
            (appcast(item(140, "0.81.0", length="")), "has no length"),
            (appcast(item("1.4", "0.81.0")), "sparkle:version '1.4' is not an integer"),
            (appcast(item(140, "0.81")), "shortVersionString '0.81' is not a release version"),
            (appcast(item(820001, "0.82.0-beta.1", "alpha")), "the only channel is beta"),
            (appcast(item(820001, "0.82.0-beta.1", "beta", critical="")), "a beta marked critical"),
            (appcast(item(141, "0.81.0"), item(140, "0.82.0")), "0.81.0 has the higher build (141 over 140)"),
            (appcast(item(140, "0.81.0"), item(140, "0.80.0")), "build 140 carries 0.80.0, 0.81.0"),
        ]
        for data, message in cases:
            with self.subTest(message=message):
                self.assertTrue(any(message in problem for problem in feed.feed_problems(data)),
                                feed.feed_problems(data))

    def test_the_last_default_channel_item_cannot_go(self):
        before = appcast(item(140, "0.81.0"))
        after = appcast(item(820001, "0.82.0-beta.1", "beta"))
        self.assertIn("the feed no longer has a default-channel item", feed.feed_problems(after, before))

    def test_the_new_item_must_be_present(self):
        release = version.parse_tag("v0.82.0-beta.1")
        url = "https://example.com/TablePro-0.82.0-beta.1.tar.xz"
        self.assertEqual(feed.feed_problems(appcast(item(820001, "0.82.0-beta.1", "beta")), None,
                                            feed.Expected(release, url)), [])
        problems = feed.feed_problems(appcast(item(820001, "0.82.0-beta.1")), None, feed.Expected(release, url))
        self.assertEqual(problems, [f"no beta item for 0.82.0-beta.1 (820001) at {url}"])

    def test_the_critical_build_carries_forward(self):
        items = feed.parse_items(appcast(item(820099, "0.82.0", critical="140"), item(140, "0.81.0", critical=""),
                                         item(830001, "0.83.0-beta.1", "beta")))
        self.assertEqual(feed.carried_critical(items), 140)
        self.assertEqual(feed.carried_critical(feed.parse_items(SEED.encode())), 140)
        self.assertIsNone(feed.carried_critical(feed.parse_items(appcast(item(139, "0.80.0")))))

    def test_the_generate_appcast_arguments(self):
        stage = Path("/stage")
        prefix = ["--ed-key-file", "-", "--embed-release-notes", "--maximum-deltas", "0"]
        beta = feed.appcast_arguments(stage, "v0.82.0-beta.1", version.parse_tag("v0.82.0-beta.1"), None, REPOSITORY)
        self.assertEqual(beta, prefix + [
            "--versions", "820001",
            "--download-url-prefix", "https://github.com/TableProApp/TablePro/releases/download/v0.82.0-beta.1/",
            "--full-release-notes-url", "https://github.com/TableProApp/TablePro/releases/tag/v0.82.0-beta.1",
            "--channel", "beta", "/stage"])
        stable = feed.appcast_arguments(stage, "v0.82.0", version.parse_tag("v0.82.0"), 140, REPOSITORY)
        self.assertEqual(stable[stable.index("--phased-rollout-interval"):],
                         ["--phased-rollout-interval", "21600", "--critical-update-version", "140", "/stage"])
        plain = feed.appcast_arguments(stage, "v0.82.1", version.parse_tag("v0.82.1"), None, REPOSITORY)
        self.assertNotIn("--critical-update-version", plain)
        self.assertNotIn("--channel", plain)

    def test_removes_items_by_version_and_keeps_the_rest_of_the_text(self):
        text = SEED
        edited, removed = feed.remove_items(text, "0.80.0")
        self.assertEqual(removed, 1)
        self.assertEqual([each.short_version for each in feed.parse_items(edited.encode())], ["0.81.0"])
        self.assertEqual(edited, text[:text.index("        <item>\n            <title>0.80.0")]
                         + text[text.index("    </channel>"):])

    def test_refuses_to_edit_text_it_cannot_match(self):
        text = SEED.replace("# 0.81.0", "# 0.81.0 </item> in the notes")
        with self.assertRaises(feed.FeedError):
            feed.remove_items(text, "0.81.0")


def git(path, *args):
    return subprocess.run(["git", "-C", str(path), *args], env={**os.environ, **GIT_ENV}, check=True,
                          capture_output=True, text=True).stdout.strip()


def fake_signed(text, key=KEY):
    namespace = {}
    exec(SIGNATURE, namespace)
    return namespace["signed"](text, key)


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


class FeedBranchTests(unittest.TestCase):
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
            **GIT_ENV,
            "PATH": f"{self.tools}{os.pathsep}{os.environ['PATH']}",
            "FAKE_LOG": str(self.log_path),
            "FAKE_RELEASES": str(self.releases),
        })
        environment.start()
        self.addCleanup(environment.stop)

        self.origin = self.base / "origin.git"
        git(self.base, "init", "--quiet", "--bare", "--initial-branch=main", str(self.origin))
        seed = self.base / "seed"
        git(self.base, "init", "--quiet", "--initial-branch=feeds", str(seed))
        (seed / "appcast.xml").write_text(SEED)
        (seed / "plugins").mkdir()
        (seed / "plugins/v3.json").write_text(json.dumps(registry.empty_manifest(39)))
        git(seed, "add", ".")
        git(seed, "commit", "--quiet", "-m", "seed")
        git(seed, "push", "--quiet", str(self.origin), "feeds")

        self.root = self.base / "tag"
        git(self.base, "init", "--quiet", "--initial-branch=main", str(self.root))
        (self.root / ".github").mkdir()
        (self.root / ".github/plugin-registry.json").write_text(json.dumps(METADATA))
        (self.root / "Configs").mkdir()
        (self.root / "Configs/PluginKit.xcconfig").write_text(
            "TABLEPRO_PLUGINKIT_VERSION = 39\nTABLEPRO_PLUGINKIT_MINIMUM_VERSION = 19\n")
        (self.root / "project.yml").write_text(PROJECT)
        git(self.root, "add", ".")
        git(self.root, "commit", "--quiet", "-m", "tag")
        git(self.root, "remote", "add", "origin", str(self.origin))
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
        release = version.parse_tag(tag)
        messages = []
        changed = feed.add(self.root, tag, release.build, release.channel, self.notes, critical, self.tools, KEY,
                           feed.Releases(REPOSITORY), REPOSITORY, log=messages.append)
        return changed, messages

    def replace_appcast(self, text):
        clone = self.base / "replace"
        git(self.base, "clone", "--quiet", "--branch", "feeds", str(self.origin), str(clone))
        (clone / "appcast.xml").write_text(text)
        git(clone, "commit", "--quiet", "-am", "replace the appcast")
        git(clone, "push", "--quiet", "origin", "feeds")

    def calls(self, tool):
        if not self.log_path.exists():
            return []
        return [call[1:] for call in map(json.loads, self.log_path.read_text().splitlines()) if call[0] == tool]

    def published(self, path):
        return subprocess.run(["git", "-C", str(self.origin), "show", f"feeds:{path}"], check=True,
                              capture_output=True, text=True).stdout

    def history(self):
        return git(self.origin, "log", "--format=%an <%ae> %s", "feeds").splitlines()

    def test_adds_a_beta_and_its_plugins(self):
        self.publish("v0.82.0-beta.1")
        changed, _ = self.add("v0.82.0-beta.1")
        self.assertTrue(changed)
        self.assertEqual(self.history(), [
            "github-actions[bot] <41898282+github-actions[bot]@users.noreply.github.com> release: v0.82.0-beta.1",
            "Fixture <fixture@example.com> seed",
        ])
        (generate,) = self.calls("generate_appcast")
        self.assertEqual(generate[-1], f"stdin={KEY}")
        signing = [call for call in self.calls("sign_update") if "--verify" not in call]
        self.assertEqual([call[:2] + call[-1:] for call in signing], [["--ed-key-file", "-", f"stdin={KEY}"]])
        self.assertIn("--channel", generate)
        self.assertNotIn("--critical-update-version", generate)
        self.assertNotIn("--phased-rollout-interval", generate)
        items = feed.parse_items(self.published("appcast.xml").encode())
        self.assertEqual([(each.short_version, each.channel) for each in items],
                         [("0.82.0-beta.1", "beta"), ("0.81.0", None), ("0.80.0", None)])
        manifest = json.loads(self.published("plugins/v3.json"))
        self.assertEqual([plugin["id"] for plugin in manifest["plugins"]],
                         ["com.TablePro.OracleDriver", "com.TablePro.ParquetExport"])
        oracle = manifest["plugins"][0]
        self.assertEqual(oracle["databaseTypeIds"], ["Oracle"])
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

    def test_a_build_or_channel_that_disagrees_with_the_tag_is_refused(self):
        with self.assertRaisesRegex(feed.FeedError, "is build 820001 on beta"):
            feed.add(self.root, "v0.82.0-beta.1", 820099, "stable", self.notes, False, self.tools, KEY,
                     feed.Releases(REPOSITORY), REPOSITORY, log=lambda message: None)

    def test_a_rerun_changes_nothing(self):
        self.publish("v0.82.0-beta.1")
        self.add("v0.82.0-beta.1")
        head = git(self.origin, "rev-parse", "feeds")
        changed, messages = self.add("v0.82.0-beta.1")
        self.assertFalse(changed)
        self.assertEqual(git(self.origin, "rev-parse", "feeds"), head)
        self.assertEqual(len(self.calls("generate_appcast")), 1)
        self.assertIn("appcast.xml already has 0.82.0-beta.1 (820001)", messages)

    def test_starts_again_when_another_run_pushed_first(self):
        self.publish("v0.82.0-beta.1")
        race = self.base / "race"
        git(self.base, "clone", "--quiet", "--branch", "feeds", str(self.origin), str(race))
        (race / "other.txt").write_text("another run\n")
        git(race, "add", "other.txt")
        git(race, "commit", "--quiet", "-m", "release: v0.81.1")
        with mock.patch.dict(os.environ, {"FAKE_RACE_REPO": str(race)}):
            changed, messages = self.add("v0.82.0-beta.1")
        self.assertTrue(changed)
        self.assertEqual([line.split("> ")[1] for line in self.history()],
                         ["release: v0.82.0-beta.1", "release: v0.81.1", "seed"])
        self.assertEqual(len(self.calls("generate_appcast")), 2)
        self.assertTrue(any("attempt 1 of 3" in message for message in messages))
        self.assertEqual(self.published("other.txt"), "another run\n")

    def test_an_archive_of_another_build_is_refused(self):
        self.publish("v0.82.0-beta.1", archive=("0.82.0-beta.1", 140))
        with self.assertRaisesRegex(feed.FeedError, r"holds 0.82.0-beta.1 \(140\), not 0.82.0-beta.1 \(820001\)"):
            self.add("v0.82.0-beta.1")
        self.assertEqual(self.calls("generate_appcast"), [])

    def test_an_item_sparkle_prunes_on_arrival_leaves_the_appcast_alone(self):
        self.replace_appcast(fake_signed(SEED))
        self.publish("v0.79.1")
        with mock.patch.dict(os.environ, {"FAKE_PRUNE": "1"}):
            changed, messages = self.add("v0.79.1")
        self.assertTrue(changed)
        self.assertEqual(self.published("appcast.xml"), fake_signed(SEED))
        self.assertIn("generate_appcast keeps newer items on 0.79.1's branch, so appcast.xml stays as it is", messages)
        self.assertEqual(len(json.loads(self.published("plugins/v3.json"))["plugins"]), 2)

    def test_a_failed_check_pushes_nothing(self):
        self.publish("v0.82.0-beta.1")
        with mock.patch.dict(os.environ, {"FAKE_UNSIGNED_ENCLOSURE": "1"}):
            with self.assertRaisesRegex(feed.FeedError, "0.82.0-beta.1's enclosure has no sparkle:edSignature"):
                self.add("v0.82.0-beta.1")
        self.assertEqual(len(self.history()), 1)

    def test_a_rejected_signature_pushes_nothing(self):
        self.publish("v0.82.0-beta.1")
        with mock.patch.dict(os.environ, {"FAKE_VERIFY_FAIL": "1"}):
            with self.assertRaisesRegex(feed.FeedError, "sign_update failed"):
                self.add("v0.82.0-beta.1")
        self.assertEqual(len(self.history()), 1)

    def test_a_wrong_digest_is_refused(self):
        self.publish("v0.82.0-beta.1")
        with mock.patch.dict(os.environ, {"FAKE_BAD_DIGEST": "TablePro-0.82.0-beta.1.tar.xz"}):
            with self.assertRaisesRegex(feed.FeedError, "but v0.82.0-beta.1 lists sha256:0000"):
                self.add("v0.82.0-beta.1")
        self.assertEqual(self.calls("generate_appcast"), [])

    def test_a_draft_is_refused(self):
        self.publish("v0.82.0-beta.1")
        with mock.patch.dict(os.environ, {"FAKE_DRAFT": "1"}):
            with self.assertRaisesRegex(feed.FeedError, "is a draft"):
                self.add("v0.82.0-beta.1")

    def test_a_plugin_built_against_another_kit_is_refused(self):
        self.publish("v0.82.0-beta.1", kit=38)
        with self.assertRaisesRegex(registry.RegistryError, "TableProPluginKitVersion is 38"):
            self.add("v0.82.0-beta.1")
        self.assertEqual(len(self.history()), 1)

    def test_withdraw_removes_the_version_and_re_signs(self):
        self.publish("v0.82.0-beta.1")
        self.publish("v0.82.0")
        self.add("v0.82.0-beta.1")
        self.add("v0.82.0")
        signed_before = sum("--verify" not in call for call in self.calls("sign_update"))
        self.assertTrue(feed.withdraw(self.root, "0.82.0", self.tools, KEY, log=lambda message: None))
        self.assertEqual(self.history()[0].split("> ")[1], "withdraw: v0.82.0")
        published = self.published("appcast.xml")
        self.assertEqual([each.short_version for each in feed.parse_items(published.encode())],
                         ["0.82.0-beta.1", "0.81.0", "0.80.0"])
        self.assertEqual(fake_signed(published), published)
        self.assertEqual(sum("--verify" not in call for call in self.calls("sign_update")), signed_before + 1)
        self.assertEqual(json.loads(self.published("plugins/v3.json"))["plugins"], [])
        self.assertFalse(feed.withdraw(self.root, "0.82.0", self.tools, KEY, log=lambda message: None))

    def test_withdraw_keeps_a_default_channel_item(self):
        self.replace_appcast(fake_signed(feed.remove_items(SEED, "0.80.0")[0]))
        with self.assertRaisesRegex(feed.FeedError, "no default-channel item"):
            feed.withdraw(self.root, "0.81.0", self.tools, KEY, log=lambda message: None)

    def test_latest_after_a_withdraw_reads_the_pushed_branch(self):
        self.publish("v0.82.0-beta.1")
        self.publish("v0.82.0")
        self.add("v0.82.0-beta.1")
        self.add("v0.82.0")
        before = git(self.origin, "rev-parse", "feeds")
        feed.withdraw(self.root, "0.82.0", self.tools, KEY, log=lambda message: None)
        git(self.root, "branch", "feeds", before)
        git(self.root, "update-ref", feed.REMOTE_BRANCH, before)
        self.assertEqual([each.short_version for each in feed.published_items(self.root)],
                         ["0.82.0-beta.1", "0.81.0", "0.80.0"])

        git(self.root, "update-ref", feed.REMOTE_BRANCH, before)
        with mock.patch.object(publish, "ROOT", self.root), \
                mock.patch.dict(os.environ, {"GITHUB_REPOSITORY": REPOSITORY}), redirect_stderr(io.StringIO()):
            self.assertEqual(publish.main(["latest"]), 0)
        self.assertEqual(self.calls("gh")[-1], ["release", "edit", "v0.81.0", "--latest=true", "--repo", REPOSITORY])

    def test_check_reads_the_published_branch(self):
        self.assertTrue(any("sign_update failed" in problem for problem in feed.check(self.root, self.tools, KEY)))
        self.publish("v0.82.0-beta.1")
        self.add("v0.82.0-beta.1")
        self.assertEqual(feed.check(self.root, self.tools, KEY), [])

    def test_main_needs_the_sparkle_tools_and_key(self):
        with mock.patch.dict(os.environ, {"SPARKLE_BIN": "", "SPARKLE_PRIVATE_KEY": KEY}), \
                redirect_stderr(io.StringIO()) as errors:
            self.assertEqual(feed.main(["check"]), 1)
        self.assertIn("SPARKLE_BIN is not set", errors.getvalue())
        with mock.patch.dict(os.environ, {"SPARKLE_BIN": str(self.tools), "SPARKLE_PRIVATE_KEY": ""}), \
                redirect_stderr(io.StringIO()) as errors:
            self.assertEqual(feed.main(["check"]), 1)
        self.assertIn("SPARKLE_PRIVATE_KEY is not set", errors.getvalue())


if __name__ == "__main__":
    unittest.main()
