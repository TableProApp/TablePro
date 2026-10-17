#!/usr/bin/env python3

import io
import os
import subprocess
import tempfile
import unittest
from contextlib import redirect_stderr, redirect_stdout
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

    def push_runs(self, workflow, sha):
        self.run_queries.append((workflow, sha))
        snapshots = self._runs.get((workflow, sha), [[]])
        return snapshots.pop(0) if len(snapshots) > 1 else snapshots[0]

    def job_conclusions(self, run_id, job):
        return self._jobs.get((run_id, job), [])


def green_on(sha, prefix="run"):
    runs, jobs = {}, {}
    for workflow, job, _ in version.REQUIRED_RUNS:
        run_id = f"{prefix}-{workflow}"
        runs[(workflow, sha)] = [[(run_id, "completed", "success")]]
        jobs[(run_id, job)] = ["success"]
    return runs, jobs


class FixtureRepository:
    def __init__(self, path: Path):
        self.path = path
        self.git("init", "--quiet", "--initial-branch=main")

    def git(self, *args: str) -> str:
        return subprocess.run(["git", "-C", str(self.path), *args], env=GIT_ENV, check=True,
                              capture_output=True, text=True).stdout.strip()

    def commit(self, message: str, changelog: str = None) -> str:
        if changelog is not None:
            (self.path / "CHANGELOG.md").write_text(changelog, encoding="utf-8")
            self.git("add", "CHANGELOG.md")
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
        self.slept = []
        self.logged = []
        self.diffs = []
        self.changed_suites = set()
        self.base = self.repo.commit("0.81.0", MAIN_CHANGELOG)
        self.repo.git("tag", "v0.81.0")
        self.cut = self.repo.commit("feat: something")
        self.repo.line("0.82", self.cut)

    def changed(self, base, suite):
        self.diffs.append((base, suite))
        return suite in self.changed_suites

    def check(self, tag, github):
        if self.git.exists(f"refs/tags/{tag}"):
            self.repo.git("checkout", "--quiet", "--detach", tag)
        return version.check(tag, self.git, github, changed=self.changed, sleep=self.slept.append,
                             log=self.logged.append)

    def test_a_first_beta_on_a_green_cut_commit_builds(self):
        self.repo.git("tag", "v0.82.0-beta.1", self.cut)
        runs, jobs = green_on(self.cut)
        github = FakeGitHub(releases=[("v0.81.0", False)], runs=runs, jobs=jobs)
        self.assertEqual(self.check("v0.82.0-beta.1", github), [])

    def test_a_skipped_job_borrows_the_nearest_first_parent_verdict(self):
        release_commit = self.repo.commit("chore(release): notes only")
        self.repo.line("0.82", release_commit)
        self.repo.git("tag", "v0.82.0-beta.1", release_commit)
        runs, jobs = green_on(self.cut)
        for workflow, job, _ in version.REQUIRED_RUNS:
            runs[(workflow, release_commit)] = [[("skip-" + workflow, "completed", "success")]]
            jobs[("skip-" + workflow, job)] = ["skipped"]
        github = FakeGitHub(releases=[("v0.81.0", False)], runs=runs, jobs=jobs)
        self.assertEqual(self.check("v0.82.0-beta.1", github), [])
        self.assertIn(f"macOS Tests: green on {self.cut}", self.logged)
        self.assertEqual(self.diffs, [(self.cut, "macos"), (self.cut, "ios"), (self.cut, "release")])

    def test_a_borrowed_verdict_must_still_cover_the_tag(self):
        unrun = self.repo.commit("fix: pushed with no run")
        self.repo.line("0.82", unrun)
        self.repo.git("tag", "v0.82.0-beta.1", unrun)
        self.changed_suites = {"macos"}
        runs, jobs = green_on(self.cut)
        github = FakeGitHub(releases=[("v0.81.0", False)], runs=runs, jobs=jobs)
        self.assertEqual(self.check("v0.82.0-beta.1", github),
                         [f"macOS Tests passed on {self.cut}, but files it reads changed before v0.82.0-beta.1"])

    def test_a_green_tag_commit_needs_no_diff(self):
        self.repo.git("tag", "v0.82.0-beta.1", self.cut)
        runs, jobs = green_on(self.cut)
        self.changed_suites = {"macos", "ios", "release"}
        github = FakeGitHub(releases=[("v0.81.0", False)], runs=runs, jobs=jobs)
        self.assertEqual(self.check("v0.82.0-beta.1", github), [])
        self.assertEqual(self.diffs, [])

    def test_the_walk_needs_the_tag_checked_out(self):
        self.repo.git("tag", "v0.82.0-beta.1", self.base)
        self.repo.line("0.82", self.cut)
        errors = version.check("v0.82.0-beta.1", self.git, FakeGitHub(releases=[("v0.81.0", False)]),
                               changed=self.changed, sleep=self.slept.append, log=self.logged.append)
        self.assertEqual(errors, ["check out v0.82.0-beta.1 first: the coverage check diffs against HEAD"])

    def test_a_pending_run_is_waited_for(self):
        self.repo.git("tag", "v0.82.0-beta.1", self.cut)
        runs, jobs = green_on(self.cut)
        workflow = version.REQUIRED_RUNS[0][0]
        runs[(workflow, self.cut)] = [[("run-" + workflow, "in_progress", "")],
                                      [("run-" + workflow, "queued", "")],
                                      [("run-" + workflow, "completed", "success")]]
        github = FakeGitHub(releases=[("v0.81.0", False)], runs=runs, jobs=jobs)
        self.assertEqual(self.check("v0.82.0-beta.1", github), [])
        self.assertEqual(self.slept, [version.POLL_SECONDS, version.POLL_SECONDS])

    def test_a_failed_job_refuses_the_tag(self):
        self.repo.git("tag", "v0.82.0-beta.1", self.cut)
        runs, jobs = green_on(self.cut)
        jobs[("run-ios-tests.yml", "iOS and Package Tests")] = ["failure"]
        github = FakeGitHub(releases=[("v0.81.0", False)], runs=runs, jobs=jobs)
        self.assertEqual(self.check("v0.82.0-beta.1", github),
                         [f"iOS and Package Tests ended 'failure' on {self.cut} (run run-ios-tests.yml)"])

    def test_a_run_that_failed_before_its_jobs_refuses_the_tag(self):
        self.repo.git("tag", "v0.82.0-beta.1", self.cut)
        runs, jobs = green_on(self.cut)
        runs[("release-build.yml", self.cut)] = [[("broken", "completed", "startup_failure")]]
        github = FakeGitHub(releases=[("v0.81.0", False)], runs=runs, jobs=jobs)
        self.assertEqual(self.check("v0.82.0-beta.1", github),
                         [f"Release Build ended 'startup_failure' on {self.cut} (run broken)"])

    def test_a_success_on_another_branch_run_of_the_same_commit_counts(self):
        self.repo.git("tag", "v0.82.0-beta.1", self.cut)
        runs, jobs = green_on(self.cut)
        for workflow, job, _ in version.REQUIRED_RUNS:
            runs[(workflow, self.cut)][0].append(("branch-" + workflow, "completed", "success"))
            jobs[("branch-" + workflow, job)] = ["skipped"]
        github = FakeGitHub(releases=[("v0.81.0", False)], runs=runs, jobs=jobs)
        self.assertEqual(self.check("v0.82.0-beta.1", github), [])

    def test_no_run_in_the_walk_refuses_the_tag(self):
        self.repo.git("tag", "v0.82.0-beta.1", self.cut)
        runs, jobs = green_on(self.cut)
        del runs[("release-build.yml", self.cut)]
        github = FakeGitHub(releases=[("v0.81.0", False)], runs=runs, jobs=jobs)
        errors = self.check("v0.82.0-beta.1", github)
        self.assertEqual(len(errors), 1)
        self.assertIn("no Release Build run that was not skipped", errors[0])

    def test_a_tag_off_the_release_line_is_refused_before_the_walk(self):
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


class DetectorTests(unittest.TestCase):
    def test_the_detector_answer_is_read(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            script = root / version.DETECTOR
            script.parent.mkdir(parents=True)
            script.write_text('#!/bin/sh\n[ "$3" = macos ] && echo true || echo false\n', encoding="utf-8")
            script.chmod(0o755)
            changed = version.detector(root)
            self.assertTrue(changed("abc", "macos"))
            self.assertFalse(changed("abc", "ios"))
            script.write_text("#!/bin/sh\necho broken >&2\nexit 2\n", encoding="utf-8")
            with self.assertRaisesRegex(RuntimeError, "broken"):
                changed("abc", "ios")


class GitHubTests(unittest.TestCase):
    def test_gh_output_is_read_as_rows(self):
        calls = []

        def run(command, **_):
            calls.append(command)
            path = command[command.index("--jq") - 1]
            outputs = {
                "/releases": "v0.82.0\tfalse\nplugin-oracle-v1.0.0\ttrue\n",
                "/runs?": "11\tcompleted\tsuccess\n12\tin_progress\t\n",
                "/jobs?": "success\n\n",
            }
            output = next(text for key, text in outputs.items() if key in path)
            return subprocess.CompletedProcess(command, 0, output, "")

        github = version.GitHub("Owner/Repo", run=run)
        self.assertEqual(github.releases(), [("v0.82.0", False), ("plugin-oracle-v1.0.0", True)])
        self.assertEqual(github.push_runs("macos-tests.yml", "abc"),
                         [("11", "completed", "success"), ("12", "in_progress", "")])
        self.assertEqual(github.job_conclusions("11", "macOS Tests"), ["success", ""])
        self.assertIn("--paginate", calls[0])
        self.assertIn("repos/Owner/Repo/actions/workflows/macos-tests.yml/runs?head_sha=abc&event=push&per_page=100",
                      calls[1])

    def test_a_gh_failure_is_raised(self):
        def run(command, **_):
            return subprocess.CompletedProcess(command, 1, "", "HTTP 404")

        with self.assertRaisesRegex(RuntimeError, "HTTP 404"):
            version.GitHub("Owner/Repo", run=run).releases()


if __name__ == "__main__":
    unittest.main()
