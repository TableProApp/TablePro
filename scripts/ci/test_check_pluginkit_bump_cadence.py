#!/usr/bin/env python3
"""Fixture tests for check-pluginkit-bump-cadence.py, each run against a throwaway git repository."""

from __future__ import annotations

import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

SCRIPT = Path(__file__).with_name("check-pluginkit-bump-cadence.py")
PLUGIN_MANAGER = Path("TablePro/Core/Plugins/PluginManager.swift")

GIT_ENV = {
    **os.environ,
    "GIT_CONFIG_GLOBAL": os.devnull,
    "GIT_CONFIG_NOSYSTEM": "1",
    "GIT_AUTHOR_NAME": "Fixture",
    "GIT_AUTHOR_EMAIL": "fixture@example.com",
    "GIT_COMMITTER_NAME": "Fixture",
    "GIT_COMMITTER_EMAIL": "fixture@example.com",
}


def plugin_manager_source(kit: int) -> str:
    return (
        "final class PluginManager {\n"
        f"    nonisolated static let currentPluginKitVersion = {kit}\n"
        "    nonisolated static let minimumCompatiblePluginKitVersion = 19\n"
        "}\n"
    )


class FixtureRepository:
    def __init__(self, path: Path) -> None:
        self.path = path

    def git(self, *args: str) -> str:
        return subprocess.run(
            ["git", "-C", str(self.path), *args],
            env=GIT_ENV,
            check=True,
            capture_output=True,
            text=True,
        ).stdout

    def write_kit(self, kit: int) -> None:
        target = self.path / PLUGIN_MANAGER
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text(plugin_manager_source(kit), encoding="utf-8")

    def commit_kit(self, kit: int, tag: str | None = None) -> None:
        self.write_kit(kit)
        self.git("add", str(PLUGIN_MANAGER))
        self.git("commit", "--quiet", "--allow-empty", "-m", f"kit {kit}")
        if tag:
            self.git("tag", tag)

    def run_check(self, *args: str) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            [sys.executable, str(SCRIPT), "--repo", str(self.path), *args],
            env=GIT_ENV,
            capture_output=True,
            text=True,
        )


class BumpCadenceTests(unittest.TestCase):
    def setUp(self) -> None:
        self.scratch = tempfile.TemporaryDirectory()
        self.addCleanup(self.scratch.cleanup)
        self.repo = self.make_repository("repo")

    def make_repository(self, name: str) -> FixtureRepository:
        path = Path(self.scratch.name) / name
        path.mkdir()
        repo = FixtureRepository(path)
        repo.git("init", "--quiet", "--initial-branch=main")
        return repo

    def assertPasses(self, result: subprocess.CompletedProcess[str]) -> None:
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def assertFails(self, result: subprocess.CompletedProcess[str], *fragments: str) -> None:
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        for fragment in fragments:
            self.assertIn(fragment, result.stderr)

    def test_the_first_bump_after_a_release_passes(self) -> None:
        self.repo.commit_kit(30, tag="v0.74.0")
        self.repo.commit_kit(31)
        self.assertPasses(self.repo.run_check())

    def test_no_bump_since_the_release_passes(self) -> None:
        self.repo.commit_kit(30, tag="v0.74.0")
        self.repo.commit_kit(30)
        self.assertPasses(self.repo.run_check())

    def test_a_second_bump_in_one_release_cycle_fails(self) -> None:
        self.repo.commit_kit(30, tag="v0.74.0")
        self.repo.commit_kit(31)
        self.repo.commit_kit(32)
        self.assertFails(self.repo.run_check(), "32", "v0.74.0", "30", "31")

    def test_an_uncommitted_second_bump_fails(self) -> None:
        self.repo.commit_kit(30, tag="v0.74.0")
        self.repo.write_kit(32)
        self.assertFails(self.repo.run_check(), "32")

    def test_the_newest_release_is_chosen_by_version_number(self) -> None:
        self.repo.commit_kit(20, tag="v0.9.0")
        self.repo.commit_kit(10, tag="plugin-oracle-v9.0.0")
        self.repo.commit_kit(30, tag="v0.10.0")
        self.repo.commit_kit(31)
        self.assertPasses(self.repo.run_check())

        self.repo.commit_kit(20, tag="v0.9.1")
        self.repo.commit_kit(31)
        self.assertPasses(self.repo.run_check())

    def test_a_repository_without_a_release_tag_fails(self) -> None:
        self.repo.commit_kit(30)
        self.assertFails(self.repo.run_check(), "release tag")

    def test_a_missing_declaration_fails(self) -> None:
        self.repo.commit_kit(30, tag="v0.74.0")
        (self.repo.path / PLUGIN_MANAGER).write_text("final class PluginManager {}\n", encoding="utf-8")
        self.assertFails(self.repo.run_check(), "currentPluginKitVersion")

    def test_a_shallow_clone_reads_the_release_from_its_remote(self) -> None:
        self.repo.commit_kit(25, tag="v0.73.0")
        self.repo.commit_kit(30, tag="v0.74.0")
        self.repo.commit_kit(30)
        clone_path = Path(self.scratch.name) / "clone"
        subprocess.run(
            ["git", "clone", "--quiet", "--depth=1", "--no-tags", self.repo.path.as_uri(), str(clone_path)],
            env=GIT_ENV,
            check=True,
            capture_output=True,
        )
        clone = FixtureRepository(clone_path)
        self.assertEqual(clone.git("tag", "--list").strip(), "")

        clone.write_kit(31)
        self.assertPasses(clone.run_check("--remote", "origin"))

        clone.write_kit(32)
        self.assertFails(clone.run_check("--remote", "origin"), "v0.74.0")

    def test_a_full_clone_stays_complete(self) -> None:
        self.repo.commit_kit(25, tag="v0.73.0")
        self.repo.commit_kit(30, tag="v0.74.0")
        self.repo.commit_kit(30)
        self.repo.commit_kit(31)
        for name, extra in (("full-clone", ["--no-tags"]), ("full-clone-with-tags", [])):
            with self.subTest(clone=name):
                clone_path = Path(self.scratch.name) / name
                subprocess.run(
                    ["git", "clone", "--quiet", *extra, self.repo.path.as_uri(), str(clone_path)],
                    env=GIT_ENV,
                    check=True,
                    capture_output=True,
                )
                clone = FixtureRepository(clone_path)
                commits = clone.git("rev-list", "--count", "HEAD").strip()

                self.assertPasses(clone.run_check("--remote", "origin"))
                self.assertEqual(clone.git("rev-parse", "--is-shallow-repository").strip(), "false")
                self.assertEqual(clone.git("rev-list", "--count", "HEAD").strip(), commits)
                self.assertEqual(
                    clone.git("rev-parse", "v0.74.0^{commit}"),
                    self.repo.git("rev-parse", "v0.74.0^{commit}"),
                )


if __name__ == "__main__":
    unittest.main(verbosity=2)
