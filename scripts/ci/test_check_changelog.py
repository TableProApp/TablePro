#!/usr/bin/env python3

import importlib.util
import io
import os
import subprocess
import tempfile
import unittest
from contextlib import redirect_stdout
from pathlib import Path
from unittest import mock

SPEC = importlib.util.spec_from_file_location("check_changelog", Path(__file__).with_name("check-changelog.py"))
check = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(check)

LINK = "https://github.com/TableProApp/TablePro/releases/tag"
HEADER = "# Changelog\n\nUnreleased changes are files in `changelog.d/`.\n\n<!-- towncrier release notes start -->\n\n"
NEW = f"## [0.82.0]({LINK}/v0.82.0) - 2026-10-25\n\nOne lead line.\n\n### Added\n\n- A thing. ([#1](x))\n\n"
OLD = "## [0.81.0] - 2026-10-16\n\n### Fixed\n\n- A bug.\n\n## [0.80.0] - 2026-10-11\n\n### Added\n\n- Another.\n"
LINUX = check.PROJECTS[1]
LINUX_NEW = f"## [0.1.0]({LINK}/linux-v0.1.0) - 2026-10-25\n\nOne lead line.\n\n### Added\n\n- A thing. ([#1](x))\n"
GIT_ENV = {
    "GIT_CONFIG_GLOBAL": os.devnull,
    "GIT_CONFIG_NOSYSTEM": "1",
    "GIT_AUTHOR_NAME": "Fixture",
    "GIT_AUTHOR_EMAIL": "fixture@example.com",
    "GIT_COMMITTER_NAME": "Fixture",
    "GIT_COMMITTER_EMAIL": "fixture@example.com",
}


class FragmentTests(unittest.TestCase):
    def setUp(self):
        self.scratch = tempfile.TemporaryDirectory()
        self.addCleanup(self.scratch.cleanup)
        self.directory = Path(self.scratch.name, "changelog.d")
        self.directory.mkdir()
        (self.directory / ".gitkeep").write_text("", encoding="utf-8")

    def problems(self, name, text):
        (self.directory / name).write_text(text, encoding="utf-8")
        return check.fragment_problems(self.directory)

    def test_a_one_line_fragment_passes(self):
        self.assertEqual(self.problems("3446.added.md", "Generate UUID in Set Value.\n"), [])

    def test_counters_and_orphans_pass(self):
        self.assertEqual(self.problems("3452.fixed.1.md", "A bug.\n"), [])
        self.assertEqual(self.problems("+theme-import.changed.md", "A change.\n"), [])

    def test_an_empty_directory_and_a_missing_one_pass(self):
        self.assertEqual(check.fragment_problems(self.directory), [])
        self.assertEqual(check.fragment_problems(self.directory / "missing"), [])

    def test_more_than_one_line_is_refused(self):
        self.assertIn("2 non-blank lines", self.problems("1.added.md", "One.\nTwo.\n")[0])

    def test_a_blank_fragment_is_refused(self):
        self.assertIn("0 non-blank lines", self.problems("1.added.md", "\n\n")[0])

    def test_blank_lines_around_the_entry_pass(self):
        self.assertEqual(self.problems("1.added.md", "\nA thing.\n\n"), [])

    def test_the_line_limit_is_120_characters(self):
        self.assertEqual(self.problems("1.added.md", "x" * 120 + "\n"), [])
        self.assertIn("121 characters", self.problems("1.added.md", "x" * 121 + "\n")[0])

    def test_a_bullet_is_refused(self):
        self.assertIn("`- `", self.problems("1.added.md", "- A thing.\n")[0])

    def test_a_credit_is_refused(self):
        self.assertIn("credit", self.problems("1.added.md", "A thing by @someone.\n")[0])

    def test_a_directory_inside_is_refused(self):
        (self.directory / "added").mkdir()
        self.assertEqual(check.fragment_problems(self.directory), ["changelog.d/added is not a file"])

    def test_a_problem_names_the_project_directory(self):
        (self.directory / "1.added.md").write_text("- A thing.\n", encoding="utf-8")
        problems = check.fragment_problems(self.directory, "linux/changelog.d")
        self.assertEqual(len(problems), 1)
        self.assertTrue(problems[0].startswith("linux/changelog.d/1.added.md starts with"))


class ChangelogTests(unittest.TestCase):
    def test_old_and_new_headings_pass(self):
        self.assertEqual(check.changelog_problems(HEADER + NEW + OLD), [])

    def test_a_critical_new_heading_passes(self):
        text = HEADER + NEW.replace("2026-10-25\n", "2026-10-25 [CRITICAL]\n", 1) + OLD
        self.assertEqual(check.changelog_problems(text), [])

    def test_only_old_headings_pass(self):
        self.assertEqual(check.changelog_problems(HEADER + OLD), [])

    def test_a_missing_or_repeated_marker_is_refused(self):
        self.assertIn("0 `", check.changelog_problems(OLD)[0])
        self.assertIn("2 `", check.changelog_problems(HEADER + "<!-- towncrier release notes start -->\n" + OLD)[0])

    def test_text_between_the_marker_and_the_first_version_is_refused(self):
        text = HEADER + "- A stray entry.\n\n" + OLD
        self.assertEqual(len(check.changelog_problems(text)), 1)
        self.assertEqual(len(check.changelog_problems(HEADER + "\n" + OLD)), 1)
        self.assertEqual(len(check.changelog_problems(HEADER.rstrip("\n") + "\n" + OLD)), 1)

    def test_a_heading_above_the_marker_is_refused(self):
        text = "# Changelog\n\n## [Unreleased]\n\n" + HEADER.split("\n", 2)[2] + OLD
        problems = check.changelog_problems(text)
        self.assertEqual(len(problems), 1)
        self.assertIn("above the marker", problems[0])

    def test_a_heading_in_neither_grammar_is_refused(self):
        for heading in ("## [Unreleased]", "## [0.82.0] 2026-10-25", "## [0.82.0-beta.1] - 2026-10-25",
                        f"## [0.82.0]({LINK}/v0.82.1) - 2026-10-25",
                        "## [0.82.0](https://example.com/v0.82.0) - 2026-10-25",
                        "## [0.82.0] - 2026-10-25 [CRITICAL]"):
            with self.subTest(heading=heading):
                problems = check.changelog_problems(HEADER + heading + "\n\n" + OLD)
                self.assertEqual(len(problems), 1)
                self.assertIn("is not `## [X.Y.Z]", problems[0])

    def test_a_heading_without_a_version_is_refused(self):
        problems = check.changelog_problems(HEADER + OLD + "\n## Notes\n")
        self.assertEqual(len(problems), 1)
        self.assertIn("`## Notes` is not", problems[0])

    def test_an_impossible_date_is_refused(self):
        problems = check.changelog_problems(HEADER + OLD.replace("2026-10-16", "2026-02-30"))
        self.assertEqual(problems, ["CHANGELOG.md:7: 2026-02-30 is not a date"])

    def test_a_repeated_version_is_refused(self):
        problems = check.changelog_problems(HEADER + OLD + "\n## [0.80.0] - 2026-10-01\n")
        self.assertEqual(len(problems), 1)
        self.assertIn("repeats", problems[0])

    def test_versions_must_descend(self):
        text = HEADER + "## [0.80.0] - 2026-10-11\n\n## [0.81.0] - 2026-10-16\n"
        problems = check.changelog_problems(text)
        self.assertEqual(len(problems), 1)
        self.assertIn("not below", problems[0])

    def test_versions_compare_as_numbers(self):
        text = HEADER + "## [0.10.0] - 2026-10-11\n\n## [0.9.0] - 2026-10-01\n"
        self.assertEqual(check.changelog_problems(text), [])

    def test_a_new_lead_block_takes_at_most_six_lines(self):
        six = "\n".join(f"Lead {index}." for index in range(6))
        text = HEADER + NEW.replace("One lead line.", six) + OLD
        self.assertEqual(check.changelog_problems(text), [])
        problems = check.changelog_problems(HEADER + NEW.replace("One lead line.", six + "\nLead 6.") + OLD)
        self.assertEqual(len(problems), 1)
        self.assertIn("7 lines", problems[0])

    def test_a_patch_takes_no_lead_block(self):
        patch = f"## [0.82.1]({LINK}/v0.82.1) - 2026-10-26\n\n### Fixed\n\n- A bug. ([#2](x))\n\n"
        self.assertEqual(check.changelog_problems(HEADER + patch + NEW + OLD), [])
        with_lead = patch.replace("### Fixed", "A lead.\n\n### Fixed")
        problems = check.changelog_problems(HEADER + with_lead + NEW + OLD)
        self.assertEqual(len(problems), 1)
        self.assertIn("0.82.1 has a lead block", problems[0])

    def test_a_lead_line_is_plain_text(self):
        for line in ("- A list item.", "#### A heading"):
            with self.subTest(line=line):
                problems = check.changelog_problems(HEADER + NEW.replace("One lead line.", line) + OLD)
                self.assertEqual(len(problems), 1)
                self.assertIn("is not plain text", problems[0])

    def test_an_old_lead_block_is_not_limited(self):
        lead = "\n".join(f"Lead {index}." for index in range(9))
        self.assertEqual(check.changelog_problems(HEADER + OLD.replace("### Fixed", lead + "\n\n### Fixed")), [])


class ProjectChangelogTests(unittest.TestCase):
    def test_a_project_heading_links_its_own_tag(self):
        self.assertEqual(check.changelog_problems(HEADER + LINUX_NEW, LINUX), [])
        self.assertEqual(check.changelog_problems(HEADER, LINUX), [])

    def test_a_heading_linking_the_other_projects_tag_is_refused(self):
        problems = check.changelog_problems(HEADER + LINUX_NEW.replace("linux-v0.1.0", "v0.1.0"), LINUX)
        self.assertEqual(len(problems), 1)
        self.assertTrue(problems[0].startswith("linux/CHANGELOG.md:7: `## [0.1.0]"))
        self.assertEqual(len(check.changelog_problems(HEADER + LINUX_NEW)), 1)

    def test_a_project_keeps_the_lead_block_rules(self):
        patch = LINUX_NEW.replace("0.1.0", "0.1.1")
        problems = check.changelog_problems(HEADER + patch, LINUX)
        self.assertEqual(problems, ["linux/CHANGELOG.md:7: 0.1.1 has a lead block; only an X.Y.0 takes one"])

    def test_a_pre_release_takes_no_section(self):
        problems = check.changelog_problems(HEADER + LINUX_NEW.replace("0.1.0", "0.1.0-rc.1"), LINUX)
        self.assertEqual(len(problems), 1)
        self.assertIn("is not `## [X.Y.Z]", problems[0])


class RepositoryTests(unittest.TestCase):
    def setUp(self):
        self.scratch = tempfile.TemporaryDirectory()
        self.addCleanup(self.scratch.cleanup)
        self.root = Path(self.scratch.name)
        (self.root / "CHANGELOG.md").write_text(HEADER + NEW + OLD, encoding="utf-8")
        (self.root / "changelog.d").mkdir()
        (self.root / "changelog.d" / "3446.added.md").write_text("A thing.\n", encoding="utf-8")
        (self.root / "linux" / "changelog.d").mkdir(parents=True)
        (self.root / "linux" / "CHANGELOG.md").write_text(HEADER + LINUX_NEW, encoding="utf-8")
        (self.root / "linux" / "changelog.d" / "3464.added.md").write_text("A thing.\n", encoding="utf-8")

    def run_main(self, *argv):
        captured = io.StringIO()
        with redirect_stdout(captured):
            status = check.main(["--root", str(self.root), *argv])
        return status, captured.getvalue()

    def test_a_good_tree_passes(self):
        self.assertEqual(self.run_main(),
                         (0, "OK: changelog.d/ and CHANGELOG.md, linux/changelog.d/ and linux/CHANGELOG.md\n"))

    def test_every_project_is_checked(self):
        (self.root / "linux" / "changelog.d" / "3464.added.md").write_text("- A thing.\n", encoding="utf-8")
        (self.root / "linux" / "CHANGELOG.md").write_text(HEADER + "## [Unreleased]\n", encoding="utf-8")
        status, out = self.run_main()
        self.assertEqual(status, 1)
        self.assertEqual(out.count("::error title=Changelog::linux/"), 2)

    def test_a_project_without_its_changelog_fails(self):
        (self.root / "linux" / "CHANGELOG.md").unlink()
        status, out = self.run_main()
        self.assertEqual(status, 1)
        self.assertIn("linux/CHANGELOG.md", out)

    def test_problems_from_both_files_are_annotations(self):
        (self.root / "changelog.d" / "3446.added.md").write_text("- A thing.\n", encoding="utf-8")
        (self.root / "CHANGELOG.md").write_text(HEADER + "## [Unreleased]\n\n" + OLD, encoding="utf-8")
        status, out = self.run_main()
        self.assertEqual(status, 1)
        self.assertEqual(out.count("::error title=Changelog::"), 2)


def changed(filename, status="added"):
    return check.ChangedFile(filename, status)


class PullRequestTests(unittest.TestCase):
    def problems(self, files, title="fix(editor): keep the caret", base="main", number=3600):
        return check.pull_request_problems(number, title, base, files)

    def test_a_fragment_named_for_the_pull_request_passes(self):
        files = [changed("changelog.d/3600.fixed.md"), changed("changelog.d/3600.fixed.1.md"),
                 changed("TablePro/Editor.swift", "modified")]
        self.assertEqual(self.problems(files), [])

    def test_editing_changelog_outside_a_release_names_the_fragment_to_add(self):
        problems = self.problems([changed("CHANGELOG.md", "modified")])
        self.assertEqual(len(problems), 1)
        self.assertIn("changelog.d/3600.<type>.md", problems[0])

    def test_a_release_pull_request_edits_changelog(self):
        files = [changed("CHANGELOG.md", "modified"), changed("changelog.d/3446.added.md", "removed")]
        self.assertEqual(self.problems(files, "chore(release): v0.82.0", "release/0.82"), [])
        self.assertEqual(self.problems(files, "chore(release): v0.82.1 (#3601)"), [])

    def test_a_release_pull_request_changes_nothing_else(self):
        files = [changed("CHANGELOG.md", "modified"), changed("TablePro/x.swift", "modified"),
                 changed("changelog.d/3446.added.md", "removed"), changed("project.yml", "modified")]
        problems = self.problems(files, "chore(release): v0.82.0", "release/0.82")
        self.assertEqual(problems, ["a release pull request changes only CHANGELOG.md and changelog.d/; "
                                    "this one also changes TablePro/x.swift and 1 more"])

    def test_titles_that_are_not_a_stable_release_cannot_edit_changelog(self):
        for title in ("chore(release): v0.82.0-beta.1", "chore(release): 0.82.0", "chore: v0.82.0",
                      "chore(release): v0.82.0 and more", "chore(release): v0.82"):
            with self.subTest(title=title):
                self.assertEqual(len(self.problems([changed("CHANGELOG.md", "modified")], title)), 1)

    def test_renaming_changelog_away_counts_as_editing_it(self):
        self.assertEqual(len(self.problems([changed("CHANGELOG.md", "removed"), changed("CHANGES.md")])), 1)

    def test_a_fragment_named_for_another_pull_request_prints_the_expected_name(self):
        problems = self.problems([changed("changelog.d/3599.fixed.2.md")])
        self.assertEqual(len(problems), 1)
        self.assertIn("Name it changelog.d/3600.fixed.2.md", problems[0])

    def test_an_orphan_fragment_on_main_is_refused(self):
        problems = self.problems([changed("changelog.d/+theme.fixed.md")])
        self.assertIn("Name it changelog.d/3600.fixed.md", problems[0])

    def test_a_file_that_is_not_a_fragment_gets_the_type_placeholder(self):
        for name in ("notes.txt", "README.md", "notes"):
            with self.subTest(name=name):
                problems = self.problems([changed(f"changelog.d/{name}")])
                self.assertEqual(len(problems), 1)
                self.assertIn("Name it changelog.d/3600.<type>.md", problems[0])

    def test_gitkeep_is_not_a_fragment(self):
        self.assertEqual(self.problems([changed("changelog.d/.gitkeep")]), [])

    def test_a_pick_into_a_release_line_keeps_the_original_name(self):
        self.assertEqual(self.problems([changed("changelog.d/3446.fixed.md")], "fix: keep it (#3446)",
                                       "release/0.82"), [])

    def test_editing_another_pull_requests_fragment_passes(self):
        self.assertEqual(self.problems([changed("changelog.d/3446.fixed.md", "modified")]), [])

    def test_retyping_another_pull_requests_fragment_keeps_its_number(self):
        files = [changed("changelog.d/3446.fixed.md", "removed"), changed("changelog.d/3446.changed.md")]
        self.assertEqual(self.problems(files), [])


class ProjectPullRequestTests(unittest.TestCase):
    VERSION_FILES = ["linux/meson.build", "linux/data/app.tablepro.TablePro.metainfo.xml.in.in",
                     "linux/build-aux/rpm/tablepro.spec", "linux/data/tablepro.1"]

    def problems(self, files, title="fix(linux): keep the caret", base="main", number=3600):
        return check.pull_request_problems(number, title, base, files)

    def test_a_fragment_named_for_the_pull_request_passes(self):
        files = [changed("linux/changelog.d/3600.fixed.md"), changed("linux/crates/app/src/x.rs", "modified")]
        self.assertEqual(self.problems(files), [])

    def test_a_fragment_named_for_another_pull_request_prints_the_expected_name(self):
        problems = self.problems([changed("linux/changelog.d/3599.fixed.1.md")])
        self.assertEqual(problems, ["linux/changelog.d/3599.fixed.1.md is not named for this pull request. "
                                    "Name it linux/changelog.d/3600.fixed.1.md"])

    def test_a_pick_into_a_maintenance_branch_keeps_the_original_name(self):
        self.assertEqual(self.problems([changed("linux/changelog.d/3446.fixed.md")], base="linux-0.1"), [])

    def test_a_fragment_of_each_project_is_named_for_the_pull_request(self):
        problems = self.problems([changed("changelog.d/3599.fixed.md"), changed("linux/changelog.d/3599.added.md")])
        self.assertEqual(len(problems), 2)
        self.assertIn("Name it changelog.d/3600.fixed.md", problems[0])
        self.assertIn("Name it linux/changelog.d/3600.added.md", problems[1])

    def test_editing_the_project_changelog_outside_a_release_names_its_title_and_fragment(self):
        problems = self.problems([changed("linux/CHANGELOG.md", "modified")])
        self.assertEqual(problems, ["only a `chore(release): linux-vX.Y.Z` pull request edits linux/CHANGELOG.md. "
                                    "Put the entry in linux/changelog.d/3600.<type>.md (.claude/rules/changelog.md)"])

    def test_a_release_pull_request_sets_the_version_and_edits_the_changelog(self):
        files = [changed("linux/CHANGELOG.md", "modified"), changed("linux/changelog.d/3464.added.md", "removed"),
                 *(changed(name, "modified") for name in self.VERSION_FILES)]
        self.assertEqual(self.problems(files, "chore(release): linux-v0.1.0"), [])
        self.assertEqual(self.problems(files, "chore(release): linux-v0.1.1 (#3601)", "linux-0.1"), [])

    def test_a_release_pull_request_changes_nothing_else(self):
        files = [changed("linux/CHANGELOG.md", "modified"), changed("linux/crates/app/src/x.rs", "modified")]
        problems = self.problems(files, "chore(release): linux-v0.1.0")
        self.assertEqual(problems, ["a release pull request changes only linux/CHANGELOG.md, linux/changelog.d/, "
                                    + ", ".join(self.VERSION_FILES[:-1]) + " and linux/data/tablepro.1; "
                                    "this one also changes linux/crates/app/src/x.rs"])

    def test_a_pre_release_pull_request_cannot_edit_the_changelog(self):
        files = [changed("linux/CHANGELOG.md", "modified"), *(changed(name, "modified") for name in self.VERSION_FILES)]
        self.assertEqual(len(self.problems(files, "chore(release): linux-v0.2.0-rc.1")), 1)
        self.assertEqual(self.problems(files[1:], "chore(release): linux-v0.2.0-rc.1"), [])

    def test_the_pull_request_adding_a_project_brings_its_changelog_and_fragments(self):
        files = [changed("linux/towncrier.toml"), changed("linux/CHANGELOG.md", "modified"),
                 changed("linux/changelog.d/3464.added.md"), changed("linux/changelog.d/3413.added.md")]
        self.assertEqual(self.problems(files), [])
        self.assertEqual(len(self.problems(files[1:])), 3)
        self.assertEqual(len(self.problems([changed("linux/towncrier.toml", "modified"), *files[1:]])), 3)

    def test_adding_one_project_leaves_the_other_checked(self):
        files = [changed("linux/towncrier.toml"), changed("CHANGELOG.md", "modified")]
        self.assertEqual(len(self.problems(files)), 1)
        self.assertIn("edits CHANGELOG.md", self.problems(files)[0])

    def test_a_release_of_one_project_cannot_edit_the_other(self):
        root = self.problems([changed("CHANGELOG.md", "modified"), changed("linux/CHANGELOG.md", "modified")],
                             "chore(release): v0.82.0", "release/0.82")
        self.assertEqual(len(root), 2)
        self.assertIn("also changes linux/CHANGELOG.md", root[0])
        self.assertIn("edits linux/CHANGELOG.md", root[1])
        linux = self.problems([changed("CHANGELOG.md", "modified"), changed("linux/CHANGELOG.md", "modified")],
                              "chore(release): linux-v0.1.0")
        self.assertEqual(len(linux), 2)
        self.assertIn("edits CHANGELOG.md", linux[0])
        self.assertIn("also changes CHANGELOG.md", linux[1])


class MergeCommitTests(unittest.TestCase):
    def setUp(self):
        environment = mock.patch.dict(os.environ, GIT_ENV)
        environment.start()
        self.addCleanup(environment.stop)
        scratch = tempfile.TemporaryDirectory()
        self.addCleanup(scratch.cleanup)
        self.root = Path(scratch.name)
        self.git("init", "--quiet", "--initial-branch=main")
        self.write("CHANGELOG.md", HEADER + OLD)
        self.write("changelog.d/3446.fixed.md", "A bug.\n")
        self.write("TablePro/x.swift", "let x = 1\n")
        self.commit("base")

    def git(self, *args):
        subprocess.run(["git", "-C", str(self.root), *args], check=True, capture_output=True)

    def write(self, path, text):
        (self.root / path).parent.mkdir(parents=True, exist_ok=True)
        (self.root / path).write_text(text, encoding="utf-8")

    def commit(self, message):
        self.git("add", "--all")
        self.git("commit", "--quiet", "--allow-empty", "-m", message)

    def run_main(self, title="fix: x", base="main"):
        captured = io.StringIO()
        with redirect_stdout(captured):
            status = check.main(["--pr", "3600", "--title", title, "--base", base, "--root", str(self.root)])
        return status, captured.getvalue()

    def test_reads_the_changes_against_the_first_parent(self):
        self.write("changelog.d/3600.fixed.md", "Another bug.\n")
        (self.root / "changelog.d/3446.fixed.md").rename(self.root / "changelog.d/3446.changed.md")
        (self.root / "CHANGELOG.md").unlink()
        self.write("TablePro/x.swift", "let x = 2\n")
        self.commit("the pull request")
        self.assertEqual(sorted(check.changed_files(self.root)), [
            changed("CHANGELOG.md", "removed"),
            changed("TablePro/x.swift", "modified"),
            changed("changelog.d/3446.changed.md"),
            changed("changelog.d/3446.fixed.md", "removed"),
            changed("changelog.d/3600.fixed.md"),
        ])
        status, out = self.run_main()
        self.assertEqual(status, 1)
        self.assertEqual(out.count("::error title=Changelog::"), 1)
        self.assertIn("edits CHANGELOG.md", out)

    def test_a_clean_pull_request_passes(self):
        self.write("changelog.d/3600.fixed.md", "Another bug.\n")
        self.commit("the pull request")
        self.assertEqual(self.run_main(), (0, "OK: the changelog files of #3600\n"))

    def test_a_missing_parent_fails_the_check(self):
        status, out = self.run_main()
        self.assertEqual(status, 1)
        self.assertIn("git diff HEAD^1 HEAD", out)

    def test_pr_needs_a_title_and_a_base(self):
        with redirect_stdout(io.StringIO()), mock.patch("sys.stderr", io.StringIO()), \
                self.assertRaises(SystemExit):
            check.main(["--pr", "3600", "--root", str(self.root)])

    def test_an_annotation_cannot_inject_a_workflow_command(self):
        self.write("changelog.d/x\n::add-mask::secret", "A bug.\n")
        self.commit("the pull request")
        status, out = self.run_main()
        self.assertEqual(status, 1)
        self.assertEqual(len(out.splitlines()), 1)
        self.assertIn("%0A::add-mask::secret", out)


if __name__ == "__main__":
    unittest.main()
