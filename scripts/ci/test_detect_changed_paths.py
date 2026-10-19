#!/usr/bin/env python3
"""Tests detect-changed-paths.sh against throwaway git repositories."""

import os
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

SCRIPT = Path(__file__).with_name("detect-changed-paths.sh")
ZERO = "0" * 40

SEED = [
    "apple/TablePro/App.swift",
    "apple/Plugins/OracleDriverPlugin/OraclePlugin.swift",
    "apple/Packages/TableProCore/Sources/Core.swift",
    "apple/CHANGELOG.md",
    "README.md",
]


class DetectChangedPathsTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.repo = Path(self.temp.name)
        self.env = {key: value for key, value in os.environ.items() if not key.startswith("GIT_")}
        self.git("-c", "init.defaultBranch=main", "init", "-q")
        (self.repo / "scripts/ci").mkdir(parents=True)
        shutil.copy(SCRIPT, self.repo / "scripts/ci/detect-changed-paths.sh")
        self.seed = self.commit(SEED)

    def tearDown(self):
        self.temp.cleanup()

    def git(self, *args):
        result = subprocess.run(
            ["git", "-c", "user.name=test", "-c", "user.email=test@example.com", "-c", "commit.gpgsign=false", *args],
            cwd=self.repo, env=self.env, check=True, capture_output=True, text=True,
        )
        return result.stdout.strip()

    def commit(self, paths):
        for path in paths:
            file = self.repo / path
            file.parent.mkdir(parents=True, exist_ok=True)
            with open(file, "a", encoding="utf-8") as handle:
                handle.write("change\n")
        self.git("add", "-A")
        self.git("commit", "-q", "-m", "change")
        return self.git("rev-parse", "HEAD")

    def detect(self, suite, base=None):
        args = ["bash", "scripts/ci/detect-changed-paths.sh"]
        if base is not None:
            args += ["--base", base]
        result = subprocess.run(args + [suite], cwd=self.repo, env=self.env, capture_output=True, text=True)
        return result.returncode, result.stdout.strip()

    def verdict_after(self, suite, path):
        self.git("checkout", "-q", "-B", "case", self.seed)
        self.commit([path])
        code, out = self.detect(suite, self.seed)
        self.assertEqual(code, 0)
        return out

    def test_unknown_suite_exits_2(self):
        self.assertEqual(self.detect("windows")[0], 2)

    def test_linux_runs_on_the_linux_tree_and_what_its_jobs_read(self):
        for path in [
            "linux/crates/app/src/main.rs",
            "linux/meson.build",
            ".github/workflows/build-linux.yml",
            ".github/workflows/linux-packages.yml",
            ".github/workflows/release-linux.yml",
        ]:
            with self.subTest(path=path):
                self.assertEqual(self.verdict_after("linux", path), "true")

    def test_linux_skips_the_apple_apps(self):
        for path in ["apple/TablePro/App.swift", "apple/TableProMobile/App.swift", "apple/Plugins/Shared/Timeout.swift",
                     "apple/project.yml", "apple/CHANGELOG.md", ".github/workflows/macos-tests.yml"]:
            with self.subTest(path=path):
                self.assertEqual(self.verdict_after("linux", path), "false")

    def test_linux_skips_the_shared_doc_scripts(self):
        for path in ["scripts/check-doc-symbols.sh", "scripts/check-banned-words.sh", "scripts/banned-words.txt"]:
            with self.subTest(path=path):
                self.assertEqual(self.verdict_after("linux", path), "false")

    def test_unknown_flag_exits_2(self):
        self.assertEqual(self.detect("--head")[0], 2)

    def test_no_base_runs_the_suite(self):
        self.assertEqual(self.detect("release"), (0, "true"))

    def test_release_runs_on_what_the_release_build_reads(self):
        for path in [
            "apple/TablePro/App.swift",
            "apple/Plugins/OracleDriverPlugin/OraclePlugin.swift",
            "apple/Plugins/TableProPluginKit/PluginKit.swift",
            "apple/Packages/TableProCore/Sources/Core.swift",
            "apple/Packages/TableProCore/Package.swift",
            "apple/Native/HanaBridge/main.go",
            "apple/Configs/Base.xcconfig",
            "apple/Libs/checksums.sha256",
            "apple/project.yml",
            "apple/TablePro.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved",
            ".github/plugin-registry.json",
            "apple/scripts/release/build.sh",
            "apple/scripts/release/package.sh",
            "apple/scripts/release/registry.py",
            "apple/scripts/release/notes.py",
            "apple/scripts/release/version.py",
            "apple/scripts/build-hana.sh",
            "apple/scripts/lib/common.sh",
            "apple/scripts/ci/verify-plugin-loads.sh",
            ".github/actions/setup-xcode/action.yml",
            ".github/actions/prepare-build/action.yml",
            ".github/workflows/release-build.yml",
        ]:
            with self.subTest(path=path):
                self.assertEqual(self.verdict_after("release", path), "true")

    def test_release_skips_tests_docs_and_other_workflows(self):
        for path in [
            "apple/TableProTests/AppTests.swift",
            "apple/TableProUITests/AppUITests.swift",
            "apple/TestPlans/Unit.xctestplan",
            "apple/Packages/TableProCore/Tests/CoreTests.swift",
            "apple/Plugins/MySQLDriverTests/MySQLTests.swift",
            "apple/TableProMobile/App.swift",
            "apple/CHANGELOG.md",
            "README.md",
            "apple/scripts/ci/summarize-xcresult.sh",
            ".github/workflows/macos-tests.yml",
            "apple/scripts/release/feed.py",
            "apple/scripts/release/notarize.sh",
            "apple/scripts/release/ExportOptions.plist",
            "apple/scripts/release/test_feed.py",
            "scripts/release/requirements.txt",
        ]:
            with self.subTest(path=path):
                self.assertEqual(self.verdict_after("release", path), "false")

    def test_macos_keeps_its_test_folders_and_ignores_the_release_workflow(self):
        self.assertEqual(self.verdict_after("macos", "apple/TableProTests/AppTests.swift"), "true")
        self.assertEqual(self.verdict_after("macos", "apple/Plugins/MySQLDriverTests/MySQLTests.swift"), "true")
        self.assertEqual(self.verdict_after("macos", ".github/workflows/release-build.yml"), "false")
        self.assertEqual(self.verdict_after("macos", "apple/scripts/release/build.sh"), "false")

    def test_macos_runs_on_the_build_setup_action(self):
        self.assertEqual(self.verdict_after("macos", ".github/actions/prepare-build/action.yml"), "true")

    def test_macos_runs_on_the_pluginkit_abi_checker(self):
        self.assertEqual(self.verdict_after("macos", "apple/scripts/check-pluginkit-abi.sh"), "true")

    def test_macos_runs_on_the_notes_script_its_build_phase_reads(self):
        self.assertEqual(self.verdict_after("macos", "apple/scripts/release/notes.py"), "true")
        self.assertEqual(self.verdict_after("macos", "apple/scripts/release/feed.py"), "false")

    def test_plugins_runs_on_what_the_plugin_build_reads(self):
        for path in [
            "apple/Plugins/OracleDriverPlugin/OraclePlugin.swift",
            "apple/Plugins/TableProPluginKit/PluginKit.swift",
            "apple/Packages/TableProCore/Sources/Core.swift",
            "apple/Packages/TableProOracle/Package.swift",
            "apple/Native/HanaBridge/go.mod",
            "apple/Native/DamengBridge/src/lib.rs",
            "apple/Libs/checksums.sha256",
            "apple/Configs/Base.xcconfig",
            "apple/project.yml",
            "apple/TablePro.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved",
            "apple/scripts/generate-project.sh",
            "apple/scripts/download-libs.sh",
            "apple/scripts/create-openssl-dylibs.sh",
            "apple/scripts/build-dameng.sh",
            "apple/scripts/build-hana.sh",
            "apple/scripts/lib/deployment-target.sh",
            "apple/scripts/ci/verify-plugin-loads.sh",
            "apple/scripts/check-pluginkit-abi.sh",
            ".github/actions/setup-xcode/action.yml",
            ".github/actions/setup-xcodegen/action.yml",
            ".github/actions/prepare-build/action.yml",
            ".github/workflows/macos-tests.yml",
        ]:
            with self.subTest(path=path):
                self.assertEqual(self.verdict_after("plugins", path), "true")

    def test_plugins_skips_the_app_its_tests_and_other_workflows(self):
        for path in [
            "apple/TablePro/App.swift",
            "apple/TableProTests/AppTests.swift",
            "apple/TableProUITests/AppUITests.swift",
            "apple/TestPlans/Unit.xctestplan",
            "apple/Packages/TableProMacCore/Sources/MacCore.swift",
            "apple/Packages/TableProEditor/Sources/Editor.swift",
            "apple/TableProMobile/App.swift",
            "apple/scripts/ci/summarize-xcresult.sh",
            "apple/scripts/release/build.sh",
            ".github/workflows/ios-tests.yml",
            ".github/workflows/release-build.yml",
        ]:
            with self.subTest(path=path):
                self.assertEqual(self.verdict_after("plugins", path), "false")

    def test_changelog_files_run_no_suite(self):
        for suite in ["macos", "plugins", "oracle", "hana", "release"]:
            for path in ["apple/CHANGELOG.md", "apple/changelog.d/3500.added.md", "apple/towncrier.toml", "appcast.xml"]:
                with self.subTest(suite=suite, path=path):
                    self.assertEqual(self.verdict_after(suite, path), "false")

    def test_a_change_beside_the_changelog_still_runs(self):
        self.git("checkout", "-q", "-B", "case", self.seed)
        self.commit(["apple/CHANGELOG.md", "apple/TablePro/App.swift"])
        self.assertEqual(self.detect("macos", self.seed), (0, "true"))

    def test_new_branch_at_main_skips(self):
        self.git("update-ref", "refs/remotes/origin/main", self.seed)
        self.assertEqual(self.detect("release", ZERO), (0, "false"))
        self.assertEqual(self.detect("macos", ZERO), (0, "false"))

    def test_new_branch_compares_with_where_it_left_main(self):
        self.git("update-ref", "refs/remotes/origin/main", self.seed)
        self.commit(["apple/TablePro/App.swift"])
        self.assertEqual(self.detect("release", ZERO), (0, "true"))

    def test_new_branch_ignores_commits_main_gained_since(self):
        self.git("checkout", "-q", "-b", "upstream")
        self.git("update-ref", "refs/remotes/origin/main", self.commit(["apple/TablePro/App.swift"]))
        self.git("checkout", "-q", "-B", "release/0.82", self.seed)
        self.commit(["apple/CHANGELOG.md"])
        self.assertEqual(self.detect("release", ZERO), (0, "false"))

    def test_new_branch_without_main_runs(self):
        self.assertEqual(self.detect("release", ZERO), (0, "true"))


if __name__ == "__main__":
    unittest.main()
