#!/usr/bin/env python3

import os
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

SCRIPT = Path(__file__).resolve().parent.parent / "check-pluginkit-abi.sh"
API = ["query", "fetchRows"]

# Stands in for Xcode: a build writes the tree's api.txt as its ABI baseline, and the checker
# reports each baseline line missing from api.txt as a breakage.
XCODEBUILD = """#!/usr/bin/env bash
set -euo pipefail
project="" out="" baseline="" previous=""
for arg in "$@"; do
    [ "$previous" = -project ] && project="${arg%/TablePro.xcodeproj}"
    case "$arg" in
        SWIFT_ABI_GENERATION_TOOL_OUTPUT_DIR=*) out="${arg#*=}" ;;
        SWIFT_ABI_CHECKER_BASELINE_DIR=*) baseline="${arg#*=}" ;;
    esac
    previous="$arg"
done
if [ -e "$project/build-fails" ]; then
    echo "$project/Kit.swift:1:1: error: cannot find type 'Row' in scope"
    exit 65
fi
mkdir -p "$out"
cp "$project/api.txt" "$out/arm64-apple-macos.json"
[ -n "$baseline" ] || exit 0
removed="$(grep -vxFf "$project/api.txt" "$baseline/ABI/arm64-apple-macos.json" || true)"
[ -n "$removed" ] || exit 0
while IFS= read -r symbol; do
    echo "$project/Kit.swift:1:1: error: ABI breakage: func $symbol has been removed"
done <<< "$removed"
exit 65
"""


class CheckPluginKitABITests(unittest.TestCase):
    # Where the app's tree, and so the script, sits in the repository.
    TREE = "."

    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        scratch = Path(self.temp.name)
        stubs = scratch / "bin"
        stubs.mkdir()
        (stubs / "xcodebuild").write_text(XCODEBUILD, encoding="utf-8")
        (stubs / "xcodegen").write_text("#!/bin/sh\nexit 0\n", encoding="utf-8")
        for stub in stubs.iterdir():
            stub.chmod(0o755)
        self.env = {key: value for key, value in os.environ.items() if not key.startswith("GIT_")}
        self.env["PATH"] = f"{stubs}{os.pathsep}{self.env['PATH']}"
        self.repo = scratch / "repo"
        self.tree = self.repo / self.TREE
        (self.tree / "scripts").mkdir(parents=True)
        shutil.copy(SCRIPT, self.tree / "scripts/check-pluginkit-abi.sh")
        self.git("-c", "init.defaultBranch=main", "init", "-q")
        self.commit_release()

    def commit_release(self):
        self.commit(API, 39, 19, tag="v1.0.0")

    def tearDown(self):
        self.temp.cleanup()

    def git(self, *args):
        result = subprocess.run(
            ["git", "-c", "user.name=test", "-c", "user.email=test@example.com", "-c", "commit.gpgsign=false",
             "-c", "tag.gpgsign=false", *args],
            cwd=self.repo, env=self.env, check=True, capture_output=True, text=True, stdin=subprocess.DEVNULL,
        )
        return result.stdout.strip()

    def commit(self, api, kit, minimum, tag=None, config=None, tree=None):
        tree = tree or self.tree
        (tree / "api.txt").write_text("".join(f"{symbol}\n" for symbol in api), encoding="utf-8")
        if config is None:
            config = f"TABLEPRO_PLUGINKIT_VERSION = {kit}\nTABLEPRO_PLUGINKIT_MINIMUM_VERSION = {minimum}\n"
        (tree / "Configs").mkdir(exist_ok=True)
        (tree / "Configs/PluginKit.xcconfig").write_text(
            "// When to raise each: .claude/rules/plugin-system.md, ABI.\n" + config, encoding="utf-8")
        self.git("add", "-A")
        self.git("commit", "-q", "--allow-empty", "-m", "change")
        if tag:
            self.git("tag", tag)

    def check(self, *args):
        result = subprocess.run(
            ["bash", "scripts/check-pluginkit-abi.sh", *args],
            cwd=self.tree, env=self.env, capture_output=True, text=True, stdin=subprocess.DEVNULL,
        )
        return result.returncode, result.stdout + result.stderr

    def assertPasses(self, expected, *args):
        code, out = self.check(*args)
        self.assertEqual(code, 0, out)
        self.assertIn(expected, out)

    def assertFails(self, expected, *args):
        code, out = self.check(*args)
        self.assertEqual(code, 1, out)
        errors = [line for line in out.splitlines() if line.startswith("::error::")]
        self.assertEqual(len(errors), 1, out)
        self.assertIn(expected, errors[0])

    def test_same_api_and_versions_pass(self):
        self.commit(API, 39, 19)
        self.assertPasses("against v1.0.0: unchanged; kit 39, minimum 19.")

    def test_same_api_with_a_kit_bump_fails(self):
        self.commit(API, 40, 19)
        self.assertFails("against v1.0.0: unchanged. Set TABLEPRO_PLUGINKIT_VERSION to 39 and "
                         "TABLEPRO_PLUGINKIT_MINIMUM_VERSION to 19 in Configs/PluginKit.xcconfig.")

    def test_same_api_with_a_lowered_minimum_fails(self):
        self.commit(API, 39, 18)
        self.assertFails("against v1.0.0: unchanged. Set TABLEPRO_PLUGINKIT_VERSION to 39 and "
                         "TABLEPRO_PLUGINKIT_MINIMUM_VERSION to 19")

    def test_reverted_break_that_keeps_its_minimum_fails(self):
        self.commit(["query"], 40, 40)
        self.commit(API, 39, 40)
        self.assertFails("against v1.0.0: unchanged. Set TABLEPRO_PLUGINKIT_VERSION to 39 and "
                         "TABLEPRO_PLUGINKIT_MINIMUM_VERSION to 19")

    def test_added_api_without_a_kit_bump_fails(self):
        self.commit(API + ["prepare"], 39, 19)
        self.assertFails("against v1.0.0: changed. Set TABLEPRO_PLUGINKIT_VERSION to 40 and "
                         "TABLEPRO_PLUGINKIT_MINIMUM_VERSION to 19")

    def test_added_api_with_a_kit_bump_passes(self):
        self.commit(API + ["prepare"], 40, 19)
        self.assertPasses("against v1.0.0: changed; kit 40, minimum 19.")

    def test_added_api_with_a_raised_minimum_fails(self):
        self.commit(API + ["prepare"], 40, 40)
        self.assertFails("against v1.0.0: changed. Set TABLEPRO_PLUGINKIT_VERSION to 40 and "
                         "TABLEPRO_PLUGINKIT_MINIMUM_VERSION to 19")

    def test_removed_api_with_only_a_kit_bump_fails(self):
        self.commit(["query"], 40, 19)
        self.assertFails("against v1.0.0: breaking. Set TABLEPRO_PLUGINKIT_VERSION to 40 and "
                         "TABLEPRO_PLUGINKIT_MINIMUM_VERSION to 40")
        self.assertIn("error: ABI breakage: func fetchRows has been removed", self.check()[1])

    def test_removed_api_with_kit_and_minimum_bumps_passes(self):
        self.commit(["query"], 40, 40)
        self.assertPasses("against v1.0.0: breaking; kit 40, minimum 40.")

    def test_frozen_passes_with_no_change(self):
        self.commit(API, 39, 19)
        self.assertPasses("against v1.0.0: unchanged; kit 39, minimum 19.", "--frozen")

    def test_frozen_fails_on_added_api_even_with_a_kit_bump(self):
        self.commit(API + ["prepare"], 40, 19)
        self.assertFails("PluginKit's ABI differs from v1.0.0, and a release line never changes it.", "--frozen")

    def test_frozen_fails_on_a_minimum_change(self):
        self.commit(API, 39, 18)
        self.assertFails("against v1.0.0: unchanged.", "--frozen")

    def test_default_base_is_the_nearest_v_tag_reachable_from_head(self):
        self.commit(API + ["prepare"], 40, 19, tag="v1.1.0")
        self.git("checkout", "-q", "-b", "side", "v1.0.0")
        self.commit(API, 39, 19, tag="v9.0.0")
        self.git("checkout", "-q", "main")
        self.commit(API + ["prepare", "explain"], 41, 19, tag="libs-1")
        self.assertPasses("against v1.1.0: changed; kit 41, minimum 19.")

    def test_default_base_is_the_release_branch_tag_that_shipped_the_highest_kit(self):
        self.commit(API + ["prepare"], 40, 19)
        self.git("checkout", "-q", "-b", "release/1.1")
        self.commit(API + ["prepare"], 40, 19, tag="v1.1.0")
        self.git("checkout", "-q", "main")
        self.commit(API + ["prepare", "explain"], 40, 19)
        self.assertFails("against v1.1.0: changed. Set TABLEPRO_PLUGINKIT_VERSION to 41 and "
                         "TABLEPRO_PLUGINKIT_MINIMUM_VERSION to 19")
        self.commit(API + ["prepare", "explain"], 41, 19)
        self.assertPasses("against v1.1.0: changed; kit 41, minimum 19.")

    def test_frozen_base_is_the_tag_the_release_line_reaches(self):
        self.commit(API + ["prepare"], 40, 19, tag="v1.1.0")
        self.git("checkout", "-q", "-b", "release/1.0", "v1.0.0")
        self.commit(API, 39, 19)
        self.assertPasses("against v1.0.0: unchanged; kit 39, minimum 19.", "--frozen")

    def test_an_explicit_base_replaces_the_tag(self):
        self.commit(API + ["prepare"], 40, 19, tag="v1.1.0")
        self.assertPasses("against v1.1.0: unchanged; kit 40, minimum 19.")
        self.assertPasses("against v1.0.0: changed; kit 40, minimum 19.", "v1.0.0")

    def test_versions_that_are_not_integers_fail_with_a_message(self):
        self.commit(API, 40, 19, config="TABLEPRO_PLUGINKIT_VERSION = 40 // bumped\n"
                                        "TABLEPRO_PLUGINKIT_MINIMUM_VERSION = 19\n")
        self.assertFails("Configs/PluginKit.xcconfig does not set TABLEPRO_PLUGINKIT_VERSION and "
                         "TABLEPRO_PLUGINKIT_MINIMUM_VERSION to integers.")

    def test_a_missing_base_version_fails_with_a_message(self):
        self.commit(API, 39, 19, config="TABLEPRO_PLUGINKIT_VERSION = 39\n", tag="v1.1.0")
        self.commit(API, 39, 19)
        self.assertFails("Configs/PluginKit.xcconfig at v1.1.0 does not set")

    def test_a_head_that_does_not_build_fails(self):
        (self.tree / "build-fails").touch()
        self.commit(API, 39, 19)
        self.assertFails("TableProPluginKit does not build at HEAD")

    def test_two_bases_are_a_usage_error(self):
        self.assertEqual(self.check("v1.0.0", "v1.0.0")[0], 2)


class AppleTreeTests(CheckPluginKitABITests):
    """Every case again with the tree in apple/, and v1.0.0 cut before it moved there."""

    TREE = "apple"

    def commit_release(self):
        self.commit(API, 39, 19, tag="v1.0.0", tree=self.repo)
        self.git("mv", "api.txt", "Configs", "apple/")
        self.git("commit", "-q", "-m", "move into apple/")

    def test_a_release_cut_after_the_move_is_built_from_apple(self):
        self.commit(API + ["prepare"], 40, 19, tag="v1.1.0")
        self.commit(API + ["prepare"], 40, 19)
        self.assertPasses("against v1.1.0: unchanged; kit 40, minimum 19.")


if __name__ == "__main__":
    unittest.main()
