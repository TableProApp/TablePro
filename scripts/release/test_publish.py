#!/usr/bin/env python3

import hashlib
import io
import json
import os
import sys
import tempfile
import unittest
from contextlib import redirect_stderr, redirect_stdout
from pathlib import Path
from unittest import mock

import feed
import publish
import version

REPOSITORY = "TableProApp/TablePro"

FAKE_GH = r'''
import hashlib, json, os, sys
from pathlib import Path
args = sys.argv[1:]
state_path = Path(os.environ["FAKE_STATE"])
state = json.loads(state_path.read_text())
state["calls"].append(args)
releases = state["releases"]

def save():
    state_path.write_text(json.dumps(state))

def fail(message):
    save()
    sys.exit(message)

def option(name):
    return args[args.index(name) + 1] if name in args else None

def files():
    return [arg for arg in args[3:] if os.path.isfile(arg) and arg != option("--notes-file")]

def upload(release, paths):
    for path in paths:
        digest = "sha256:" + hashlib.sha256(Path(path).read_bytes()).hexdigest()
        if Path(path).name == os.environ.get("FAKE_CORRUPT"):
            digest = "sha256:" + "0" * 64
        release["assets"][Path(path).name] = digest

if args[0] == "api":
    path = args[1]
    if path.endswith("/releases/latest"):
        if state["latest"] is None:
            fail("gh: Not Found (HTTP 404)")
        print(state["latest"])
    else:
        tag = path.rsplit("/", 1)[1]
        if tag not in releases or releases[tag]["draft"]:
            fail("gh: Not Found (HTTP 404)")
        print("false")
elif args[:2] == ["release", "view"]:
    release = releases.get(args[2])
    if release is None:
        fail("release not found")
    if state.get("hide_drafts", 0) > 0:
        state["hide_drafts"] -= 1
        fail("release not found")
    assets = [{"name": name, "digest": digest, "state": "uploaded"} for name, digest in release["assets"].items()]
    print(json.dumps({"isDraft": release["draft"], "assets": assets}))
elif args[:2] == ["release", "create"]:
    if args[2] not in state["tags"]:
        fail("tag " + args[2] + " doesn't exist in the repo")
    release = {"draft": "--draft" in args, "prerelease": "--prerelease=true" in args, "latest": None, "assets": {}}
    releases[args[2]] = release
    upload(release, files())
elif args[:2] == ["release", "upload"]:
    upload(releases[args[2]], files())
elif args[:2] == ["release", "edit"]:
    release = releases[args[2]]
    for arg in args[3:]:
        if arg == "--draft=false":
            release["draft"] = False
        elif arg in ("--prerelease", "--prerelease=true"):
            release["prerelease"] = True
        elif arg == "--prerelease=false":
            release["prerelease"] = False
        elif arg == "--latest=true":
            state["latest"] = args[2]
        elif arg == "--latest=false":
            release["latest"] = False
else:
    fail("fake gh cannot answer " + " ".join(args))
save()
'''


def items(*pairs):
    return [feed.Item(build=str(build), short_version=short, channel=channel, is_critical=False,
                      critical_version=None, url="https://example.com", signature="c2ln", length="1")
            for build, short, channel in pairs]


class DecisionTests(unittest.TestCase):
    def test_the_draft_action(self):
        self.assertEqual(publish.draft_action(True, False), "published")
        self.assertEqual(publish.draft_action(True, True), "published")
        self.assertEqual(publish.draft_action(False, True), "reuse")
        self.assertEqual(publish.draft_action(False, False), "create")

    def test_latest_goes_only_to_the_highest_stable(self):
        cases = [
            ("v0.82.0", "v0.81.0", True),
            ("v0.82.0", None, True),
            ("v0.82.0", "plugin-oracle-v1.0.0", True),
            ("v0.81.1", "v0.82.0", False),
            ("v0.82.0", "v0.82.0", False),
            ("v0.83.0-beta.1", "v0.82.0", False),
        ]
        for tag, latest, expected in cases:
            with self.subTest(tag=tag, latest=latest):
                self.assertEqual(publish.should_be_latest(version.parse_tag(tag), latest), expected)

    def test_the_release_flags(self):
        self.assertEqual(publish.release_flags(version.parse_tag("v0.82.0-beta.1"), "v0.81.0"),
                         ["--draft=false", "--prerelease", "--latest=false"])
        self.assertEqual(publish.release_flags(version.parse_tag("v0.82.0"), "v0.81.0"),
                         ["--draft=false", "--latest=true"])
        self.assertEqual(publish.release_flags(version.parse_tag("v0.81.1"), "v0.82.0"),
                         ["--draft=false", "--latest=false"])

    def test_the_highest_stable_in_the_feed(self):
        feed_items = items((830001, "0.83.0-beta.1", "beta"), (820199, "0.82.1", None), (820099, "0.82.0", None),
                           (140, "0.81.0", None))
        self.assertEqual(str(publish.highest_stable(feed_items)), "0.82.1")
        self.assertEqual(str(publish.highest_stable(items((140, "0.81.0", None), (139, "0.80.0", None)))), "0.81.0")
        self.assertIsNone(publish.highest_stable(items((830001, "0.83.0-beta.1", "beta"))))

    def test_asset_problems(self):
        assets = [{"name": "a.zip", "digest": "sha256:" + "1" * 64, "state": "uploaded"},
                  {"name": "b.zip", "digest": "sha256:" + "2" * 64, "state": "starter"}]
        self.assertEqual(publish.asset_problems({"a.zip": "1" * 64}, assets), [])
        self.assertEqual(publish.asset_problems({"a.zip": "3" * 64, "b.zip": "2" * 64, "c.zip": "4" * 64}, assets), [
            f"a.zip is sha256:{'1' * 64} on GitHub but sha256:{'3' * 64} here",
            "b.zip is starter, not uploaded",
            "the release has no c.zip",
        ])


class GitHubTests(unittest.TestCase):
    def setUp(self):
        directory = tempfile.TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        self.base = Path(directory.name)
        tools = self.base / "bin"
        tools.mkdir()
        (tools / "gh").write_text(f"#!{sys.executable}\n{FAKE_GH}")
        (tools / "gh").chmod(0o755)
        self.state_path = self.base / "state.json"
        self.state({"releases": {"v0.81.0": {"draft": False, "prerelease": False, "assets": {}}},
                    "latest": "v0.81.0", "tags": ["v0.81.0", "v0.82.0-beta.1", "v0.82.0", "v0.81.1"], "calls": []})
        environment = mock.patch.dict(os.environ, {"PATH": f"{tools}{os.pathsep}{os.environ['PATH']}",
                                                   "FAKE_STATE": str(self.state_path),
                                                   "GITHUB_REPOSITORY": REPOSITORY})
        environment.start()
        self.addCleanup(environment.stop)
        self.github = publish.GitHub(REPOSITORY)
        self.notes = self.base / "body.md"
        self.notes.write_text("Notes\n")
        self.files = []
        for name in ("TablePro-0.82.0.dmg", "TablePro-0.82.0.tar.xz", "OracleDriver-0.82.0.zip"):
            path = self.base / name
            path.write_bytes(name.encode())
            self.files.append(path)
        self.log = []

    def state(self, value=None):
        if value is not None:
            self.state_path.write_text(json.dumps(value))
        return json.loads(self.state_path.read_text())

    def verbs(self):
        return [call[:2] if call[0] == "release" else call[:1] for call in self.state()["calls"]]

    def draft(self, tag="v0.82.0"):
        return publish.draft(self.github, tag, self.notes, self.files, sleep=lambda seconds: None,
                             log=self.log.append)

    def digests(self):
        return {path.name: "sha256:" + hashlib.sha256(path.read_bytes()).hexdigest() for path in self.files}

    def test_creates_a_draft_and_checks_its_digests(self):
        self.assertEqual(self.draft(), "draft")
        release = self.state()["releases"]["v0.82.0"]
        self.assertEqual((release["draft"], release["prerelease"], release["assets"]), (True, False, self.digests()))
        create = next(call for call in self.state()["calls"] if call[:2] == ["release", "create"])
        self.assertEqual(create[:9], ["release", "create", "v0.82.0", "--draft", "--verify-tag", "--title", "v0.82.0",
                                      "--notes-file", str(self.notes)])

    def test_a_beta_draft_is_a_prerelease(self):
        self.files = [self.base / "TablePro-0.82.0.dmg"]
        self.draft("v0.82.0-beta.1")
        self.assertTrue(self.state()["releases"]["v0.82.0-beta.1"]["prerelease"])

    def test_a_published_release_is_left_alone(self):
        state = self.state()
        state["releases"]["v0.82.0"] = {"draft": False, "prerelease": False, "assets": {}}
        self.state(state)
        self.assertEqual(self.draft(), "published")
        self.assertEqual(self.verbs(), [["api"]])

    def test_an_earlier_draft_is_reused(self):
        self.draft()
        state = self.state()
        state["calls"] = []
        self.state(state)
        self.files[0].write_bytes(b"rebuilt")
        self.assertEqual(self.draft(), "draft")
        self.assertNotIn(["release", "create"], self.verbs())
        self.assertIn(["release", "upload"], self.verbs())
        self.assertEqual(self.state()["releases"]["v0.82.0"]["assets"], self.digests())

    def test_waits_for_a_new_draft_to_appear(self):
        state = self.state()
        state["hide_drafts"] = 2
        self.state(state)
        self.assertEqual(self.draft(), "draft")
        self.assertEqual(self.verbs().count(["release", "view"]), 4)

    def test_a_draft_that_never_appears_is_an_error(self):
        state = self.state()
        state["hide_drafts"] = publish.FIND_ATTEMPTS
        self.state(state)
        with self.assertRaisesRegex(publish.PublishError, "cannot be found"):
            self.draft()

    def test_a_wrong_digest_keeps_the_draft_unpublished(self):
        with mock.patch.dict(os.environ, {"FAKE_CORRUPT": "OracleDriver-0.82.0.zip"}):
            with self.assertRaisesRegex(publish.PublishError, "OracleDriver-0.82.0.zip is sha256:0000"):
                self.draft()
        self.assertTrue(self.state()["releases"]["v0.82.0"]["draft"])

    def test_a_missing_file_is_refused_before_any_call(self):
        self.files.append(self.base / "missing.zip")
        with self.assertRaisesRegex(publish.PublishError, "missing.zip does not exist"):
            self.draft()
        self.assertEqual(self.state()["calls"], [])

    def test_publishes_a_beta_as_a_prerelease_that_is_never_latest(self):
        self.files = [self.base / "TablePro-0.82.0.dmg"]
        self.draft("v0.82.0-beta.1")
        publish.release(self.github, "v0.82.0-beta.1", self.log.append)
        state = self.state()
        self.assertEqual(state["releases"]["v0.82.0-beta.1"]["draft"], False)
        self.assertEqual(state["latest"], "v0.81.0")
        self.assertEqual(state["calls"][-1], ["release", "edit", "v0.82.0-beta.1", "--draft=false", "--prerelease",
                                              "--latest=false", "--repo", REPOSITORY])

    def test_a_stable_above_latest_becomes_latest(self):
        self.draft()
        publish.release(self.github, "v0.82.0", self.log.append)
        self.assertEqual(self.state()["latest"], "v0.82.0")

    def test_a_patch_on_an_older_line_is_not_latest(self):
        state = self.state()
        state["latest"] = "v0.82.0"
        self.state(state)
        self.draft("v0.81.1")
        publish.release(self.github, "v0.81.1", self.log.append)
        self.assertEqual(self.state()["latest"], "v0.82.0")
        self.assertIn("--latest=false", self.state()["calls"][-1])

    def test_releasing_twice_edits_once(self):
        self.draft()
        publish.release(self.github, "v0.82.0", self.log.append)
        publish.release(self.github, "v0.82.0", self.log.append)
        self.assertEqual(sum(call[:2] == ["release", "edit"] for call in self.state()["calls"]), 1)

    def test_releasing_without_a_draft_is_refused(self):
        with self.assertRaisesRegex(publish.PublishError, "has no draft"):
            publish.release(self.github, "v0.82.0", self.log.append)

    def test_latest_marks_the_highest_stable_left_in_the_feed(self):
        feed_items = items((830001, "0.83.0-beta.1", "beta"), (140, "0.81.0", None))
        self.assertEqual(publish.latest(self.github, feed_items, self.log.append), "v0.81.0")
        self.assertEqual(self.state()["calls"][-1], ["release", "edit", "v0.81.0", "--latest=true",
                                                     "--repo", REPOSITORY])

    def test_draft_prints_only_the_state_on_stdout(self):
        arguments = ["draft", "v0.82.0", "--notes", str(self.notes), *[str(path) for path in self.files]]
        with redirect_stdout(io.StringIO()) as output, redirect_stderr(io.StringIO()):
            self.assertEqual(publish.main(arguments), 0)
        self.assertEqual(output.getvalue(), "state=draft\n")
        with redirect_stdout(io.StringIO()) as output, redirect_stderr(io.StringIO()):
            self.assertEqual(publish.main(["release", "v0.82.0"]), 0)
            self.assertEqual(publish.main(arguments), 0)
        self.assertEqual(output.getvalue(), "state=published\n")


if __name__ == "__main__":
    unittest.main()
