#!/usr/bin/env python3

import io
import os
import shutil
import subprocess
import tempfile
import unittest
from contextlib import redirect_stderr, redirect_stdout
from dataclasses import replace
from pathlib import Path

import version

GIT_ENV = {
    **os.environ,
    "GIT_CONFIG_GLOBAL": os.devnull,
    "GIT_CONFIG_NOSYSTEM": "1",
    "GIT_AUTHOR_NAME": "Fixture",
    "GIT_AUTHOR_EMAIL": "fixture@example.com",
    "GIT_COMMITTER_NAME": "Fixture",
    "GIT_COMMITTER_EMAIL": "fixture@example.com",
}
MAIN_CHANGELOG = "# Changelog\n\n## [0.81.0] - 2026-10-16\n\n### Fixed\n\n- A bug. (#1)\n"
DETECTOR_SOURCE = Path(__file__).resolve().parents[3] / version.DETECTOR
# What the fake detector in CheckTests calls shipped; AppleTreeTests runs the real one.
SHIPPED_PREFIXES = ("TablePro/", "Plugins/")


class GrammarTests(unittest.TestCase):
    def test_the_versions_table(self):
        cases = [
            ("v0.82.0-beta.1", "0.82.0-beta.1", 820001, "beta", "0.82"),
            ("v0.82.0-beta.2", "0.82.0-beta.2", 820002, "beta", "0.82"),
            ("v0.82.0", "0.82.0", 820099, "stable", "0.82"),
            ("v0.82.1", "0.82.1", 820199, "stable", "0.82"),
            ("v0.83.0-beta.1", "0.83.0-beta.1", 830001, "beta", "0.83"),
        ]
        for tag, text, build, channel, line in cases:
            with self.subTest(tag=tag):
                parsed = version.parse_tag(tag)
                self.assertEqual((str(parsed), parsed.build, parsed.channel, parsed.line, parsed.tag),
                                 (text, build, channel, line, tag))

    def test_the_bounds_are_accepted(self):
        for tag in ("v0.999.99", "v0.82.0-beta.98", "v1.0.0", "v0.0.0"):
            with self.subTest(tag=tag):
                version.parse_tag(tag)

    def test_anything_else_is_refused(self):
        refused = [
            "0.82.0", "v0.82", "v0.82.0.1", "v0.82.0-rc.1", "v0.82.0-beta", "v0.82.1-beta.1",
            "v0.82.0-beta.0", "v0.82.0-beta.99", "v0.1000.0", "v0.82.100", "v01.82.0",
            "v0.82.0-beta.01", "v0.82.0 ", "v0.82.0-beta.1+1", "v0.٨٢.0", "plugin-oracle-v1.0.0",
        ]
        for tag in refused:
            with self.subTest(tag=tag), self.assertRaises(ValueError):
                version.parse_tag(tag)

    def test_semver_order_is_build_order(self):
        ordered = ["v0.81.0", "v0.81.1", "v0.82.0-beta.1", "v0.82.0-beta.2", "v0.82.0-beta.98", "v0.82.0",
                   "v0.82.1", "v0.82.99", "v0.83.0-beta.1", "v0.999.0", "v1.0.0-beta.1", "v1.0.0"]
        builds = [version.parse_tag(tag).build for tag in ordered]
        self.assertEqual(builds, sorted(builds))
        self.assertEqual(len(set(builds)), len(builds))

    def test_parse_prints_the_step_outputs(self):
        output = io.StringIO()
        with redirect_stdout(output):
            self.assertEqual(version.main(["parse", "v0.82.0-beta.2"]), 0)
        self.assertEqual(output.getvalue(), "version=0.82.0-beta.2\nbuild=820002\nchannel=beta\nline=0.82\n")

    def test_parse_refuses_a_bad_tag(self):
        with redirect_stderr(io.StringIO()) as errors:
            self.assertEqual(version.main(["parse", "v0.82.1-beta.1"]), 1)
        self.assertIn("PATCH 0", errors.getvalue())


class FakeGitHub:
    def __init__(self, releases=(), runs=None, jobs=None):
        self._releases = list(releases)
        self._runs = runs or {}
        self._jobs = jobs or {}
        self.run_queries = []

    def releases(self):
        return self._releases

    def push_runs(self, sha, branch):
        self.run_queries.append((sha, branch))
        return self._runs.get((sha, branch), [])

    def job_conclusions(self, run_id, job):
        return self._jobs.get((run_id, job), [])


def green_on(sha, branch="release/0.82"):
    runs, jobs = [], {}
    for path, name in version.TEST_WORKFLOWS:
        run_id = f"run-{name}"
        runs.append(version.Run(run_id, path, "completed", "success", f"https://ci.example/{run_id}"))
        jobs[(run_id, name)] = ["success"]
    return {(sha, branch): runs}, jobs


def with_run(runs, name, **changes):
    path = next(path for path, job in version.TEST_WORKFLOWS if job == name)
    return {key: [replace(run, **changes) if run.path == path else run for run in found]
            for key, found in runs.items()}


class FixtureRepository:
    def __init__(self, path: Path):
        self.path = path
        self.git("init", "--quiet", "--initial-branch=main")

    def git(self, *args: str) -> str:
        return subprocess.run(["git", "-C", str(self.path), *args], env=GIT_ENV, check=True,
                              capture_output=True, text=True).stdout.strip()

    def commit(self, message: str, changelog: str = None, fragment: str = None, source: str = None) -> str:
        if source is not None:
            path = self.path / source
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(message + "\n", encoding="utf-8")
            self.git("add", str(path))
        if changelog is not None:
            (self.path / "CHANGELOG.md").write_text(changelog, encoding="utf-8")
            self.git("add", "CHANGELOG.md")
        if fragment is not None:
            path = self.path / "changelog.d" / fragment
            path.parent.mkdir(exist_ok=True)
            path.write_text("A fix.\n", encoding="utf-8")
            self.git("add", str(path))
        self.git("commit", "--quiet", "--allow-empty", "-m", message)
        return self.git("rev-parse", "HEAD")

    def line(self, name: str, sha: str):
        self.git("update-ref", f"refs/remotes/origin/release/{name}", sha)


class CheckTests(unittest.TestCase):
    def setUp(self):
        directory = tempfile.TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        self.repo = FixtureRepository(Path(directory.name))
        self.git = version.Git(self.repo.path)
        self.diffs = []
        self.base = self.repo.commit("0.81.0", MAIN_CHANGELOG)
        self.repo.git("tag", "v0.81.0")
        self.cut = self.repo.commit("feat: something")
        self.repo.line("0.82", self.cut)

    def changed(self, base, head, suite):
        self.diffs.append((base, head, suite))
        paths = self.repo.git("diff-tree", "-r", "--name-only", base, head).splitlines()
        return any(path.startswith(SHIPPED_PREFIXES) for path in paths)

    def check(self, tag, github):
        return version.check(tag, self.git, github, changed=self.changed)

    def stable_on_line(self, name, heading, changelog=MAIN_CHANGELOG):
        release_commit = self.repo.commit(f"chore(release): {name}", changelog.replace(
            "## [0.81.0]", f"## [{heading}] - 2026-10-26\n\n## [0.81.0]"))
        self.repo.line("0.82", release_commit)
        self.repo.git("tag", name, release_commit)
        return release_commit

    def test_a_first_beta_on_a_green_cut_commit_builds(self):
        self.repo.git("tag", "v0.82.0-beta.1", self.cut)
        runs, jobs = green_on(self.cut)
        github = FakeGitHub(releases=[("v0.81.0", False)], runs=runs, jobs=jobs)
        self.assertEqual(self.check("v0.82.0-beta.1", github), [])
        self.assertEqual(github.run_queries, [(self.cut, "release/0.82")])

    def test_a_skipped_test_job_refuses_the_tag(self):
        self.repo.git("tag", "v0.82.0-beta.1", self.cut)
        runs, jobs = green_on(self.cut)
        jobs[("run-macOS Tests", "macOS Tests")] = ["skipped"]
        github = FakeGitHub(releases=[("v0.81.0", False)], runs=runs, jobs=jobs)
        self.assertEqual(self.check("v0.82.0-beta.1", github),
                         ["macOS Tests ran no tests at https://ci.example/run-macOS Tests (job: skipped)"])

    def test_a_run_still_going_refuses_at_once_and_names_its_url(self):
        self.repo.git("tag", "v0.82.0-beta.1", self.cut)
        runs, jobs = green_on(self.cut)
        for status in ("queued", "in_progress"):
            with self.subTest(status=status):
                pending = with_run(runs, "iOS and Package Tests", status=status, conclusion="")
                github = FakeGitHub(releases=[("v0.81.0", False)], runs=pending, jobs=jobs)
                self.assertEqual(self.check("v0.82.0-beta.1", github),
                                 [f"iOS and Package Tests is {status} at https://ci.example/run-iOS and Package "
                                  "Tests: re-run Verify once it is green"])

    def test_a_failed_run_refuses_the_tag(self):
        self.repo.git("tag", "v0.82.0-beta.1", self.cut)
        runs, jobs = green_on(self.cut)
        for conclusion in ("failure", "cancelled", "startup_failure"):
            with self.subTest(conclusion=conclusion):
                failed = with_run(runs, "iOS and Package Tests", conclusion=conclusion)
                github = FakeGitHub(releases=[("v0.81.0", False)], runs=failed, jobs=jobs)
                self.assertEqual(self.check("v0.82.0-beta.1", github),
                                 [f"iOS and Package Tests ended '{conclusion}' at "
                                  "https://ci.example/run-iOS and Package Tests"])

    def test_a_missing_run_refuses_the_tag(self):
        self.repo.git("tag", "v0.82.0-beta.1", self.cut)
        runs, jobs = green_on(self.cut)
        macos_only = {key: [run for run in found if run.path.endswith("macos-tests.yml")]
                      for key, found in runs.items()}
        github = FakeGitHub(releases=[("v0.81.0", False)], runs=macos_only, jobs=jobs)
        self.assertEqual(self.check("v0.82.0-beta.1", github),
                         [f"no iOS and Package Tests push run on release/0.82 at {self.cut}"])

    def test_only_a_push_run_on_the_line_counts(self):
        self.repo.git("tag", "v0.82.0-beta.1", self.cut)
        runs, jobs = green_on(self.cut, branch="main")
        github = FakeGitHub(releases=[("v0.81.0", False)], runs=runs, jobs=jobs)
        self.assertEqual(self.check("v0.82.0-beta.1", github),
                         [f"no macOS Tests push run on release/0.82 at {self.cut}",
                          f"no iOS and Package Tests push run on release/0.82 at {self.cut}"])

    def test_release_build_is_not_required(self):
        self.repo.git("tag", "v0.82.0-beta.1", self.cut)
        runs, jobs = green_on(self.cut)
        runs[(self.cut, "release/0.82")].append(version.Run(
            "build", ".github/workflows/release-build.yml", "completed", "failure", "https://ci.example/build"))
        github = FakeGitHub(releases=[("v0.81.0", False)], runs=runs, jobs=jobs)
        self.assertEqual(self.check("v0.82.0-beta.1", github), [])

    def test_a_second_tag_on_a_tagged_commit_is_refused(self):
        self.repo.git("tag", "--annotate", "--message", "v0.82.0-beta.1", "v0.82.0-beta.1", self.cut)
        self.repo.git("tag", "--annotate", "--message", "v0.82.0-beta.2", "v0.82.0-beta.2", self.cut)
        github = FakeGitHub(releases=[("v0.81.0", False)])
        self.assertEqual(self.check("v0.82.0-beta.2", github),
                         ["v0.82.0-beta.2 is on the same commit as v0.82.0-beta.1: one v* tag per commit"])
        self.assertEqual(github.run_queries, [])

    def test_a_tag_of_another_kind_on_the_commit_is_allowed(self):
        self.repo.git("tag", "linux-v0.1.0", self.cut)
        self.repo.git("tag", "v0.82.0-beta.1", self.cut)
        runs, jobs = green_on(self.cut)
        github = FakeGitHub(releases=[("v0.81.0", False)], runs=runs, jobs=jobs)
        self.assertEqual(self.check("v0.82.0-beta.1", github), [])

    def test_a_tag_off_the_release_line_is_refused_before_the_query(self):
        side = self.repo.commit("off the line")
        self.repo.git("tag", "v0.82.0-beta.1", side)
        self.repo.line("0.82", self.cut)
        github = FakeGitHub(releases=[("v0.81.0", False)])
        self.assertEqual(self.check("v0.82.0-beta.1", github),
                         ["v0.82.0-beta.1 is not reachable from origin/release/0.82"])
        self.assertEqual(github.run_queries, [])

    def test_a_missing_release_branch_is_refused(self):
        self.repo.git("tag", "v0.83.0-beta.1", self.cut)
        errors = self.check("v0.83.0-beta.1", FakeGitHub(releases=[("v0.81.0", False)]))
        self.assertIn("origin/release/0.83 does not exist", errors)

    def test_the_previous_tag_on_the_line_must_be_an_ancestor(self):
        self.repo.git("tag", "v0.82.0-beta.1", self.cut)
        self.repo.git("checkout", "--quiet", "-b", "other", self.base)
        other = self.repo.commit("rewritten line")
        self.repo.line("0.82", other)
        self.repo.git("tag", "v0.82.0-beta.2", other)
        errors = self.check("v0.82.0-beta.2", FakeGitHub(releases=[("v0.81.0", False)]))
        self.assertEqual(errors, ["v0.82.0-beta.1, the previous tag on 0.82, is not an ancestor of v0.82.0-beta.2"])

    def test_a_stable_needs_a_published_beta(self):
        self.repo.git("tag", "v0.82.0-beta.1", self.cut)
        release_commit = self.repo.commit("chore(release): v0.82.0", MAIN_CHANGELOG.replace(
            "## [0.81.0]", "## [0.82.0](https://example.com) - 2026-10-20\n\n### Added\n\n- New.\n\n## [0.81.0]"))
        self.repo.line("0.82", release_commit)
        self.repo.git("tag", "v0.82.0", release_commit)
        for releases in ([("v0.81.0", False)], [("v0.81.0", False), ("v0.82.0-beta.1", True)]):
            with self.subTest(releases=releases):
                self.assertEqual(self.check("v0.82.0", FakeGitHub(releases=releases)),
                                 ["v0.82.0 needs a published v0.82.0-beta.N release first"])
        runs, jobs = green_on(release_commit)
        published = FakeGitHub(releases=[("v0.81.0", False), ("v0.82.0-beta.1", False)], runs=runs, jobs=jobs)
        self.assertEqual(self.check("v0.82.0", published), [])

    def test_a_stable_refuses_shipped_source_after_its_newest_published_beta(self):
        self.repo.git("tag", "v0.82.0-beta.1", self.cut)
        beta = self.repo.commit("fix: first pick", source="TablePro/First.swift")
        self.repo.git("tag", "v0.82.0-beta.2", beta)
        unpublished = self.repo.commit("fix: second pick", source="TablePro/Second.swift")
        self.repo.git("tag", "v0.82.0-beta.3", unpublished)
        self.repo.commit("fix: third pick", source="Plugins/Third.swift")
        self.stable_on_line("v0.82.0", "0.82.0")
        releases = [("v0.81.0", False), ("v0.82.0-beta.1", False), ("v0.82.0-beta.2", False),
                    ("v0.82.0-beta.3", True)]
        github = FakeGitHub(releases=releases)
        self.assertEqual(self.check("v0.82.0", github),
                         ["v0.82.0 changes shipped source since v0.82.0-beta.2, the newest published beta: "
                          "revert that on release/0.82, then tag the next number"])
        self.assertEqual(self.diffs, [("v0.82.0-beta.2", "v0.82.0", "shipped")])
        self.assertEqual(github.run_queries, [])

    def test_a_stable_may_differ_from_its_newest_beta_outside_shipped_source(self):
        beta = self.repo.commit("fix: a fix", fragment="3610.fixed.md")
        self.repo.git("tag", "v0.82.0-beta.1", beta)
        self.repo.commit("ci: pin a runner", source=".github/workflows/release.yml")
        self.repo.commit("docs(changelog): reword a fragment", fragment="3611.fixed.md")
        self.repo.git("rm", "--quiet", "-r", "changelog.d")
        release_commit = self.stable_on_line("v0.82.0", "0.82.0")
        runs, jobs = green_on(release_commit)
        github = FakeGitHub(releases=[("v0.81.0", False), ("v0.82.0-beta.1", False)], runs=runs, jobs=jobs)
        self.assertEqual(self.check("v0.82.0", github), [])

    def test_the_next_number_after_a_refused_stable_is_held_to_the_beta(self):
        self.repo.git("tag", "v0.82.0-beta.1", self.cut)
        pick = self.repo.commit("fix: late pick", source="TablePro/Late.swift")
        refused = self.repo.commit("chore(release): v0.82.0", MAIN_CHANGELOG.replace(
            "## [0.81.0]", "## [0.82.0] - 2026-10-26\n\n## [0.81.0]"))
        self.repo.git("tag", "v0.82.0", refused)
        patch = self.repo.commit("chore(release): v0.82.1", MAIN_CHANGELOG.replace(
            "## [0.81.0]", "## [0.82.1] - 2026-10-27\n\n## [0.81.0]"))
        self.repo.git("tag", "v0.82.1", patch)
        self.repo.git("revert", "--no-edit", pick)
        reverted = self.repo.commit("chore(release): v0.82.2", MAIN_CHANGELOG.replace(
            "## [0.81.0]", "## [0.82.2] - 2026-10-28\n\n## [0.81.0]"))
        self.repo.git("tag", "v0.82.2", reverted)
        self.repo.line("0.82", reverted)
        releases = [("v0.81.0", False), ("v0.82.0-beta.1", False)]
        runs, jobs = green_on(reverted)
        self.assertEqual(self.check("v0.82.1", FakeGitHub(releases=releases)),
                         ["v0.82.1 changes shipped source since v0.82.0-beta.1, the newest published beta: "
                          "revert that on release/0.82, then tag the next number"])
        self.assertEqual(self.check("v0.82.2", FakeGitHub(releases=releases, runs=runs, jobs=jobs)), [])

    def test_a_patch_after_a_stable_that_matched_the_beta_is_exempt(self):
        self.repo.git("tag", "v0.82.0-beta.1", self.cut)
        stable = self.repo.commit("chore(release): v0.82.0", MAIN_CHANGELOG.replace(
            "## [0.81.0]", "## [0.82.0] - 2026-10-26\n\n## [0.81.0]"))
        self.repo.git("tag", "v0.82.0", stable)
        self.repo.commit("fix: a crash", source="TablePro/Crash.swift")
        release_commit = self.repo.commit("chore(release): v0.82.1", MAIN_CHANGELOG.replace(
            "## [0.81.0]", "## [0.82.1] - 2026-10-27\n\n## [0.82.0] - 2026-10-26\n\n## [0.81.0]"))
        self.repo.line("0.82", release_commit)
        self.repo.git("tag", "v0.82.1", release_commit)
        runs, jobs = green_on(release_commit)
        releases = [("v0.81.0", False), ("v0.82.0-beta.1", False), ("v0.82.0", False)]
        self.assertEqual(self.check("v0.82.1", FakeGitHub(releases=releases, runs=runs, jobs=jobs)), [])
        self.assertEqual(self.diffs, [("v0.82.0-beta.1", "v0.82.0", "shipped")])

    def test_a_patch_needs_no_beta(self):
        changelog = MAIN_CHANGELOG.replace(
            "## [0.81.0]", "## [0.82.1] - 2026-10-25\n\n## [0.82.0] - 2026-10-20\n\n## [0.81.0]")
        release_commit = self.repo.commit("chore(release): v0.82.1", changelog)
        self.repo.line("0.82", release_commit)
        self.repo.git("tag", "v0.82.1", release_commit)
        runs, jobs = green_on(release_commit)
        github = FakeGitHub(releases=[("v0.81.0", False), ("v0.82.0", False)], runs=runs, jobs=jobs)
        self.assertEqual(self.check("v0.82.1", github), [])

    def test_no_beta_follows_the_stable_tag(self):
        self.repo.git("tag", "v0.82.0", self.cut)
        later = self.repo.commit("fix: later")
        self.repo.line("0.82", later)
        self.repo.git("tag", "v0.82.0-beta.3", later)
        errors = self.check("v0.82.0-beta.3", FakeGitHub(releases=[("v0.81.0", False)]))
        self.assertIn("v0.82.0 is already tagged, so no beta of it can follow", errors)

    def test_a_stable_needs_its_heading(self):
        self.repo.git("tag", "v0.82.1", self.cut)
        errors = self.check("v0.82.1", FakeGitHub(releases=[("v0.81.0", False)]))
        self.assertEqual(errors, ["CHANGELOG.md at v0.82.1 has no ## [0.82.1]"])

    def test_a_stable_refuses_fragments_left_at_its_tag(self):
        changelog = MAIN_CHANGELOG.replace("## [0.81.0]", "## [0.81.1] - 2026-10-25\n\n## [0.81.0]")
        self.repo.commit("chore: keep the fragment folder", fragment=".gitkeep")
        self.repo.commit("chore(release): v0.81.1", changelog)
        pick = self.repo.commit("fix: a pick after the release PR was cut", fragment="3610.fixed.md")
        self.repo.line("0.81", pick)
        self.repo.git("tag", "v0.81.1", pick)
        runs, jobs = green_on(pick, branch="release/0.81")
        github = FakeGitHub(releases=[("v0.81.0", False)], runs=runs, jobs=jobs)
        self.assertEqual(self.check("v0.81.1", github),
                         ["v0.81.1 still has 3610.fixed.md in changelog.d/; assemble again on the line head"])

    def test_a_beta_ships_with_its_fragments(self):
        tagged = self.repo.commit("fix: a fix", fragment="3610.fixed.md")
        self.repo.line("0.82", tagged)
        self.repo.git("tag", "v0.82.0-beta.1", tagged)
        runs, jobs = green_on(tagged)
        github = FakeGitHub(releases=[("v0.81.0", False)], runs=runs, jobs=jobs)
        self.assertEqual(self.check("v0.82.0-beta.1", github), [])

    def test_a_beta_refuses_a_line_whose_stable_is_assembled(self):
        assembled = self.repo.commit("chore(release): v0.82.0", MAIN_CHANGELOG.replace(
            "## [0.81.0]", "## [0.82.0] - 2026-10-20\n\n## [0.81.0]"))
        self.repo.line("0.82", assembled)
        self.repo.git("tag", "v0.82.0-beta.4", assembled)
        errors = self.check("v0.82.0-beta.4", FakeGitHub(releases=[("v0.81.0", False)]))
        self.assertEqual(errors, ["CHANGELOG.md at v0.82.0-beta.4 already has ## [0.82.0]"])

    def test_a_missing_forward_port_is_refused(self):
        self.repo.git("tag", "v0.83.0-beta.1", self.cut)
        self.repo.line("0.83", self.cut)
        releases = [("v0.80.3", False), ("v0.81.0", False), ("v0.81.1", False), ("v0.81.2", True),
                    ("v0.82.0-beta.1", False)]
        errors = self.check("v0.83.0-beta.1", FakeGitHub(releases=releases))
        self.assertEqual(errors, ["CHANGELOG.md at v0.83.0-beta.1 has no ## [0.81.1]: forward-port that release first"])

    def test_a_bad_tag_stops_at_the_grammar(self):
        github = FakeGitHub()
        self.assertEqual(self.check("v0.82.1-beta.1", github), ["0.82.1-beta.1: a beta exists only on PATCH 0"])
        self.assertEqual(github.run_queries, [])


class AppleTreeTests(unittest.TestCase):
    def test_the_changelog_and_fragments_come_from_the_tree_git_runs_in(self):
        with tempfile.TemporaryDirectory() as directory:
            repo = FixtureRepository(Path(directory))
            apple = repo.path / "apple"
            (apple / "changelog.d").mkdir(parents=True)
            (repo.path / "CHANGELOG.md").write_text(MAIN_CHANGELOG, encoding="utf-8")
            (apple / "CHANGELOG.md").write_text(
                MAIN_CHANGELOG.replace("## [0.81.0]", "## [0.81.1] - 2026-10-25\n\n## [0.81.0]"), encoding="utf-8")
            (apple / "changelog.d" / "3610.fixed.md").write_text("A fix.\n", encoding="utf-8")
            repo.git("add", "--all")
            sha = repo.commit("chore(release): v0.81.1")
            repo.line("0.81", sha)
            repo.git("tag", "v0.81.1", sha)
            errors = version.check("v0.81.1", version.Git(apple), FakeGitHub(releases=[("v0.81.0", False)]),
                                   changed=lambda base, head, suite: True)
            self.assertEqual(errors, ["v0.81.1 still has 3610.fixed.md in changelog.d/; assemble again on the line head"])

    def test_the_shipped_source_rule_reads_the_detector(self):
        cases = {
            ".github/workflows/release.yml": [],
            ".github/actions/setup-xcode/action.yml": [],
            "apple/Plugins/OracleDriverPluginTests/OracleTests.swift": [],
            "apple/TablePro/App.swift": ["v0.82.0 changes shipped source since v0.82.0-beta.1, the newest published "
                                         "beta: revert that on release/0.82, then tag the next number"],
            ".github/plugin-registry.json": ["v0.82.0 changes shipped source since v0.82.0-beta.1, the newest "
                                             "published beta: revert that on release/0.82, then tag the next number"],
        }
        for path, expected in cases.items():
            with self.subTest(path=path), tempfile.TemporaryDirectory() as directory:
                repo = FixtureRepository(Path(directory))
                detector = repo.path / version.DETECTOR
                detector.parent.mkdir(parents=True)
                shutil.copy(DETECTOR_SOURCE, detector)
                apple = repo.path / "apple"
                (apple / "changelog.d").mkdir(parents=True)
                (apple / "changelog.d" / "3610.fixed.md").write_text("A fix.\n", encoding="utf-8")
                (apple / "CHANGELOG.md").write_text(MAIN_CHANGELOG, encoding="utf-8")
                repo.git("add", "--all")
                repo.git("tag", "v0.82.0-beta.1", repo.commit("fix: a fix"))
                repo.git("rm", "--quiet", "-r", "apple/changelog.d")
                (apple / "CHANGELOG.md").write_text(
                    MAIN_CHANGELOG.replace("## [0.81.0]", "## [0.82.0] - 2026-10-26\n\n## [0.81.0]"), encoding="utf-8")
                repo.git("add", "--all")
                repo.git("tag", "v0.82.0", repo.commit("chore(release): v0.82.0", source=path))
                errors = version.stable_tree_errors(version.Git(apple), version.parse_tag("v0.82.0"),
                                                    [("v0.82.0-beta.1", False)], version.detector(repo.path))
                self.assertEqual(errors, expected)


class DetectorTests(unittest.TestCase):
    def test_the_detector_answer_is_read(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            script = root / version.DETECTOR
            script.parent.mkdir(parents=True)
            script.write_text('#!/bin/sh\n[ "$1 $2 $3 $4 $5" = "--base abc --head v1 shipped" ] && echo true '
                              '|| echo false\n', encoding="utf-8")
            script.chmod(0o755)
            changed = version.detector(root)
            self.assertTrue(changed("abc", "v1", "shipped"))
            self.assertFalse(changed("abc", "v1", "release"))
            script.write_text("#!/bin/sh\necho broken >&2\nexit 2\n", encoding="utf-8")
            with self.assertRaisesRegex(RuntimeError, "broken"):
                changed("abc", "v1", "shipped")


class GitHubTests(unittest.TestCase):
    def test_gh_output_is_read_as_rows(self):
        calls = []

        def run(command, **_):
            calls.append(command)
            path = command[command.index("--jq") - 1]
            outputs = {
                "/releases": "v0.82.0\tfalse\nplugin-oracle-v1.0.0\ttrue\n",
                "/runs?": ("11\t.github/workflows/macos-tests.yml\tcompleted\tsuccess\thttps://ci.example/11\n"
                           "12\t.github/workflows/ios-tests.yml\tin_progress\t\thttps://ci.example/12\n"),
                "/jobs?": "success\n\n",
            }
            output = next(text for key, text in outputs.items() if key in path)
            return subprocess.CompletedProcess(command, 0, output, "")

        github = version.GitHub("Owner/Repo", run=run)
        self.assertEqual(github.releases(), [("v0.82.0", False), ("plugin-oracle-v1.0.0", True)])
        self.assertEqual(github.push_runs("abc", "release/0.83"), [
            version.Run("11", ".github/workflows/macos-tests.yml", "completed", "success", "https://ci.example/11"),
            version.Run("12", ".github/workflows/ios-tests.yml", "in_progress", "", "https://ci.example/12"),
        ])
        self.assertEqual(github.job_conclusions("11", "macOS Tests"), ["success", ""])
        self.assertIn("--paginate", calls[0])
        self.assertIn("repos/Owner/Repo/actions/runs?head_sha=abc&event=push&branch=release/0.83&per_page=100",
                      calls[1])

    def test_a_gh_failure_is_raised(self):
        def run(command, **_):
            return subprocess.CompletedProcess(command, 1, "", "HTTP 404")

        with self.assertRaisesRegex(RuntimeError, "HTTP 404"):
            version.GitHub("Owner/Repo", run=run).releases()


if __name__ == "__main__":
    unittest.main()
