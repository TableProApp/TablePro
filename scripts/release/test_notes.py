#!/usr/bin/env python3

import json
import os
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

import notes

ROOT = Path(__file__).resolve().parent.parent.parent
GIT_ENV = {
    **os.environ,
    "GIT_CONFIG_GLOBAL": os.devnull,
    "GIT_CONFIG_NOSYSTEM": "1",
    "GIT_AUTHOR_NAME": "Fixture",
    "GIT_AUTHOR_EMAIL": "fixture@example.com",
    "GIT_COMMITTER_NAME": "Fixture",
    "GIT_COMMITTER_EMAIL": "fixture@example.com",
}
MARKER = "<!-- towncrier release notes start -->"
CHANGELOG = f"""# Changelog

Unreleased changes are files in `changelog.d/`.

{MARKER}

## [0.82.0](https://github.com/TableProApp/TablePro/releases/tag/v0.82.0) - 2026-10-20 [CRITICAL]

Beta updates from a signed feed.
Plugins update with the app.

### Added

- Beta channel by [@someone](https://github.com/someone). ([#3500](https://github.com/TableProApp/TablePro/pull/3500))

### Fixed

- A crash with `#3` and `@MainActor` in code. ([#3501](https://github.com/TableProApp/TablePro/pull/3501))


## [0.81.1](https://github.com/TableProApp/TablePro/releases/tag/v0.81.1) - 2026-10-05

### Fixed

- Hang on connect.

```
## [9.9.9] inside a fence
### Not a subsection
```

## [0.81.0] - 2026-10-16

Old lead line.

### Added

- Old entry. (#3353 by @RaffeYang)
"""


def towncrier_missing():
    try:
        notes.towncrier_command()
    except notes.NotesError:
        return True
    return False


def authors(table):
    calls = []

    def author_of(number):
        calls.append(number)
        return table[number]

    author_of.calls = calls
    return author_of


class FixtureRepository:
    def __init__(self, path: Path):
        self.path = path
        self.git("init", "--quiet", "--initial-branch=main")
        shutil.copy2(ROOT / "towncrier.toml", path / "towncrier.toml")
        (path / "CHANGELOG.md").write_text(
            f"# Changelog\n\n{MARKER}\n\n## [0.81.0] - 2026-10-16\n\n### Fixed\n\n- Old.\n", encoding="utf-8")
        (path / notes.FRAGMENTS).mkdir()
        (path / notes.FRAGMENTS / ".gitkeep").write_text("", encoding="utf-8")

    def git(self, *args: str) -> str:
        return subprocess.run(["git", "-C", str(self.path), *args], env=GIT_ENV, check=True,
                              capture_output=True, text=True).stdout

    def fragment(self, name: str, text: str):
        (self.path / notes.FRAGMENTS / name).write_text(text + "\n", encoding="utf-8")

    def commit(self, message: str) -> None:
        self.git("add", "--all")
        self.git("commit", "--quiet", "--allow-empty", "-m", message)


class SectionTests(unittest.TestCase):
    def test_a_new_heading_gives_its_date_critical_marker_and_lead(self):
        section = notes.find_section(CHANGELOG, "0.82.0")
        self.assertEqual(section.date, "2026-10-20")
        self.assertTrue(section.is_critical)
        self.assertEqual(section.lead, ["Beta updates from a signed feed.", "Plugins update with the app."])
        self.assertEqual(section.entries[0], "### Added")

    def test_an_old_heading_still_parses(self):
        section = notes.find_section(CHANGELOG, "0.81.0")
        self.assertEqual((section.date, section.is_critical, section.lead), ("2026-10-16", False, ["Old lead line."]))

    def test_a_fence_neither_ends_the_section_nor_starts_a_subsection(self):
        section = notes.find_section(CHANGELOG, "0.81.1")
        self.assertEqual(section.lead, [])
        self.assertIn("## [9.9.9] inside a fence", section.entries)
        self.assertIsNone(notes.find_section(CHANGELOG, "9.9.9"))

    def test_the_body_drops_only_the_heading(self):
        body = notes.find_section(CHANGELOG, "0.82.0").body
        self.assertTrue(body.startswith(
            "Beta updates from a signed feed.\nPlugins update with the app.\n\n### Added\n"))
        self.assertTrue(body.endswith("([#3501](https://github.com/TableProApp/TablePro/pull/3501))"))

    def test_a_missing_version_is_none(self):
        self.assertIsNone(notes.find_section(CHANGELOG, "0.0.0-dev"))


class ChangelogCommandTests(unittest.TestCase):
    def setUp(self):
        directory = tempfile.TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        self.root = Path(directory.name)
        (self.root / "CHANGELOG.md").write_text(CHANGELOG, encoding="utf-8")

    def test_the_stable_feed_is_the_lead_and_a_docs_link(self):
        self.assertEqual(
            notes.feed(self.root, "0.82.0", None),
            "# What's New in TablePro 0.82.0\n\nBeta updates from a signed feed.\n\nPlugins update with the app.\n\n"
            "[View full changelog](https://docs.tablepro.app/changelog)\n",
        )

    def test_a_stable_feed_without_a_lead_carries_the_whole_section(self):
        self.assertTrue(notes.feed(self.root, "0.81.1", None).startswith(
            "# What's New in TablePro 0.81.1\n\n### Fixed\n\n- Hang on connect.\n"))

    def test_the_stable_body_is_the_section_without_its_heading(self):
        body = notes.release_body(self.root, "0.82.0", None)
        self.assertTrue(body.startswith("Beta updates from a signed feed.\n"))
        self.assertNotIn("## [0.82.0]", body)

    def test_lead_and_critical(self):
        self.assertEqual(notes.lead(self.root, "0.82.0"),
                         "Beta updates from a signed feed.\nPlugins update with the app.\n")
        self.assertEqual(notes.lead(self.root, "0.81.1"), "")
        self.assertEqual(notes.lead(self.root, "0.83.0-beta.1"), "")
        self.assertTrue(notes.critical(self.root, "0.82.0"))
        self.assertFalse(notes.critical(self.root, "0.81.1"))
        self.assertFalse(notes.critical(self.root, "0.83.0-beta.1"))

    def test_a_stable_without_a_section_is_an_error(self):
        for command in (notes.lead, notes.critical):
            with self.subTest(command=command.__name__), self.assertRaisesRegex(notes.NotesError, "no ## \\[0.82.1\\]"):
                command(self.root, "0.82.1")


class WhatsNewTests(unittest.TestCase):
    def setUp(self):
        directory = tempfile.TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        self.changelog = Path(directory.name) / "CHANGELOG.md"
        self.changelog.write_text(CHANGELOG, encoding="utf-8")
        self.out = Path(directory.name) / "WhatsNew.md"

    def test_the_lead_becomes_the_window(self):
        self.assertTrue(notes.whats_new("0.82.0", self.changelog, self.out))
        self.assertEqual(self.out.read_text(encoding="utf-8"),
                         "# TablePro 0.82.0\n\nBeta updates from a signed feed.\n\nPlugins update with the app.\n")

    def test_no_lead_writes_a_pointer(self):
        notes.whats_new("0.81.1", self.changelog, self.out)
        self.assertEqual(self.out.read_text(encoding="utf-8"), f"# TablePro 0.81.1\n\n{notes.NO_LEAD}\n")

    def test_no_section_writes_nothing_and_removes_a_stale_file(self):
        self.out.write_text("stale", encoding="utf-8")
        self.assertFalse(notes.whats_new("0.0.0-dev", self.changelog, self.out))
        self.assertFalse(self.out.exists())
        self.assertFalse(notes.whats_new("0.0.0-dev", self.changelog, self.out))

    def test_the_cli_runs_without_version_py(self):
        directory = Path(self.out.parent)
        shutil.copy2(Path(notes.__file__), directory / "notes.py")
        result = subprocess.run(
            [sys.executable, "-I", str(directory / "notes.py"), "whats-new", "0.82.0",
             "--changelog", str(self.changelog), "--out", str(self.out)],
            capture_output=True, text=True,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue(self.out.read_text(encoding="utf-8").startswith("# TablePro 0.82.0\n"))


class CreditTests(unittest.TestCase):
    def test_an_outside_author_goes_before_the_final_period(self):
        self.assertEqual(notes.credit("Schema picker.\n", ("i87ce", "CONTRIBUTOR")), "Schema picker by @i87ce.\n")

    def test_a_line_without_a_period_gets_the_credit_at_the_end(self):
        self.assertEqual(notes.credit("Schema picker", ("i87ce", "NONE")), "Schema picker by @i87ce")

    def test_owners_and_members_are_not_credited(self):
        for association in ("OWNER", "MEMBER"):
            with self.subTest(association=association):
                self.assertEqual(notes.credit("Schema picker.\n", ("datlechin", association)), "Schema picker.\n")

    def test_a_credited_line_is_left_alone(self):
        self.assertEqual(notes.credit("Picker by @i87ce.\n", ("i87ce", "CONTRIBUTOR")), "Picker by @i87ce.\n")

    def test_only_pull_request_fragments_are_credited(self):
        with tempfile.TemporaryDirectory() as directory:
            folder = Path(directory)
            for name in ("3436.added.md", "3436.fixed.1.md", "+tidy.changed.md", ".gitkeep"):
                (folder / name).write_text("An entry.\n", encoding="utf-8")
            author_of = authors({3436: ("i87ce", "FIRST_TIME_CONTRIBUTOR")})
            notes.credit_fragments(folder, author_of)
            self.assertEqual((folder / "3436.added.md").read_text(encoding="utf-8"), "An entry by @i87ce.\n")
            self.assertEqual((folder / "3436.fixed.1.md").read_text(encoding="utf-8"), "An entry by @i87ce.\n")
            self.assertEqual((folder / "+tidy.changed.md").read_text(encoding="utf-8"), "An entry.\n")
            self.assertEqual(author_of.calls, [3436, 3436])

    def test_gh_is_asked_once_per_pull_request(self):
        calls = []

        def run(command, **_):
            calls.append(command)
            return subprocess.CompletedProcess(command, 0, json.dumps({"login": "i87ce", "association": "NONE"}), "")

        lookup = notes.PullRequestAuthors("Owner/Repo", run=run)
        self.assertEqual(lookup(12), ("i87ce", "NONE"))
        self.assertEqual(lookup(12), ("i87ce", "NONE"))
        self.assertEqual(len(calls), 1)
        self.assertIn("repos/Owner/Repo/pulls/12", calls[0])

    def test_a_gh_failure_names_the_pull_request(self):
        def run(command, **_):
            return subprocess.CompletedProcess(command, 1, "", "HTTP 404")

        with self.assertRaisesRegex(notes.NotesError, "#12: HTTP 404"):
            notes.PullRequestAuthors("Owner/Repo", run=run)(12)


class LeadFileTests(unittest.TestCase):
    def read(self, text):
        with tempfile.NamedTemporaryFile("w", suffix=".txt", delete=False) as handle:
            handle.write(text)
        self.addCleanup(os.unlink, handle.name)
        return notes.read_lead(Path(handle.name))

    def test_blank_lines_are_dropped(self):
        self.assertEqual(self.read("One.\n\nTwo.\n"), ["One.", "Two."])

    def test_more_than_six_lines_are_refused(self):
        with self.assertRaisesRegex(notes.NotesError, "at most 6"):
            self.read("".join(f"Line {n}.\n" for n in range(7)))

    def test_headings_and_list_items_are_refused(self):
        for text in ("### Added\n", "- An entry.\n"):
            with self.subTest(text=text), self.assertRaises(notes.NotesError):
                self.read(text)


class DocsTests(unittest.TestCase):
    MDX = (
        '---\ntitle: "Changelog"\n---\n\n'
        '<Update label="v0.81.0" description="October 16, 2026">\n  ### Bug Fixes\n\n  - Old.\n</Update>\n\n'
        '<Update label="v0.9.0" description="January 2, 2025">\n  ### New Features\n\n  - Older.\n</Update>\n'
    )

    def block(self, version):
        return notes.render_update(notes.find_section(CHANGELOG, version), "TableProApp/TablePro")

    def test_a_block_renames_sections_and_links_credits(self):
        self.assertEqual(self.block("0.82.0"), "\n".join([
            '<Update label="v0.82.0" description="October 20, 2026">',
            "  Beta updates from a signed feed.",
            "",
            "  Plugins update with the app.",
            "",
            "  ### New Features",
            "",
            "  - Beta channel by [@someone](https://github.com/someone). "
            "([#3500](https://github.com/TableProApp/TablePro/pull/3500))",
            "",
            "  ### Bug Fixes",
            "",
            "  - A crash with `#3` and `@MainActor` in code. "
            "([#3501](https://github.com/TableProApp/TablePro/pull/3501))",
            "</Update>",
        ]))

    def test_old_references_become_links(self):
        self.assertIn(
            "  - Old entry. ([#3353](https://github.com/TableProApp/TablePro/issues/3353) by "
            "[@RaffeYang](https://github.com/RaffeYang))",
            self.block("0.81.0"),
        )

    def test_the_date_has_no_leading_zero(self):
        self.assertEqual(notes.docs_date("2026-10-05"), "October 5, 2026")

    def test_a_new_block_lands_in_version_order_and_a_rerun_changes_nothing(self):
        merged = notes.merge_update(self.MDX, "0.82.0", self.block("0.82.0"))
        self.assertLess(merged.index('label="v0.82.0"'), merged.index('label="v0.81.0"'))
        self.assertTrue(merged.startswith('---\ntitle: "Changelog"\n---\n\n<Update label="v0.82.0"'))
        self.assertTrue(merged.endswith("  - Older.\n</Update>\n"))
        self.assertEqual(notes.merge_update(merged, "0.82.0", self.block("0.82.0")), merged)

        patch = notes.merge_update(merged, "0.81.1", self.block("0.81.1"))
        labels = [match.group(1) for match in notes.UPDATE_BLOCK.finditer(patch)]
        self.assertEqual(labels, ["0.82.0", "0.81.1", "0.81.0", "0.9.0"])

    def test_an_existing_block_is_replaced(self):
        merged = notes.merge_update(self.MDX, "0.81.0", self.block("0.81.0"))
        self.assertNotIn("  - Old.\n", merged)
        self.assertEqual(merged.count('label="v0.81.0"'), 1)

    def test_an_unchanged_file_round_trips(self):
        first = next(notes.UPDATE_BLOCK.finditer(self.MDX)).group(0)
        self.assertEqual(notes.merge_update(self.MDX, "0.81.0", first), self.MDX)

    def test_stray_text_and_duplicates_are_refused(self):
        stray = self.MDX.replace("</Update>\n\n<Update", "</Update>\n\nStray.\n\n<Update")
        duplicate = self.MDX.replace('label="v0.9.0"', 'label="v0.81.0"')
        for mdx in (stray, duplicate):
            with self.subTest(mdx=mdx), self.assertRaises(notes.NotesError):
                notes.merge_update(mdx, "0.82.0", self.block("0.82.0"))

    def test_docs_reads_the_changelog_at_the_ref(self):
        with tempfile.TemporaryDirectory() as directory:
            repo = FixtureRepository(Path(directory))
            (repo.path / "CHANGELOG.md").write_text(CHANGELOG, encoding="utf-8")
            repo.commit("chore(release): v0.82.0")
            repo.git("tag", "v0.82.0")
            (repo.path / "CHANGELOG.md").write_text("# Changelog\n", encoding="utf-8")
            mdx = repo.path / "changelog.mdx"
            mdx.write_text(self.MDX, encoding="utf-8")
            notes.docs(repo.path, "0.82.0", "v0.82.0", mdx)
            self.assertIn('<Update label="v0.82.0" description="October 20, 2026">', mdx.read_text(encoding="utf-8"))
            with self.assertRaisesRegex(notes.NotesError, "beta"):
                notes.docs(repo.path, "0.83.0-beta.1", "v0.82.0", mdx)


class AssembleRefusalTests(unittest.TestCase):
    def setUp(self):
        directory = tempfile.TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        self.repo = FixtureRepository(Path(directory.name))
        self.repo.fragment("3500.added.md", "Beta channel.")
        self.repo.commit("feat: beta channel")
        self.repo.git("update-ref", "refs/remotes/origin/release/0.82", "HEAD")

    def assemble(self, version="0.82.0", lead_lines=(), date="2026-10-20"):
        notes.assemble(self.repo.path, version, authors({}), list(lead_lines), False, date)

    def test_refusals(self):
        cases = [
            ({"version": "0.82.0-beta.1"}, "a beta is a tag"),
            ({"version": "0.82.1", "lead_lines": ["A lead."]}, "X.Y.0 only"),
            ({"date": "20 Oct"}, "YYYY-MM-DD"),
            ({"version": "0.83.0"}, "origin/release/0.83 does not exist"),
        ]
        for arguments, message in cases:
            with self.subTest(arguments=arguments), self.assertRaisesRegex(notes.NotesError, message):
                self.assemble(**arguments)

    def test_a_commit_beyond_the_line_is_refused(self):
        self.repo.commit("fix: not picked")
        with self.assertRaisesRegex(notes.NotesError, "not on origin/release/0.82: fix: not picked"):
            self.assemble()

    def test_a_head_without_the_line_is_refused(self):
        self.repo.git("checkout", "--quiet", "--orphan", "elsewhere")
        self.repo.commit("unrelated")
        with self.assertRaisesRegex(notes.NotesError, "HEAD does not contain origin/release/0.82"):
            self.assemble()

    def test_no_fragments_is_refused(self):
        self.repo.git("rm", "--quiet", f"{notes.FRAGMENTS}/3500.added.md")
        self.repo.commit("chore: drop")
        self.repo.git("update-ref", "refs/remotes/origin/release/0.82", "HEAD")
        with self.assertRaisesRegex(notes.NotesError, "no fragments"):
            self.assemble()

    def test_an_assembled_version_is_refused(self):
        self.repo.git("update-ref", "refs/remotes/origin/release/0.81", "HEAD")
        with self.assertRaisesRegex(notes.NotesError, "already has ## \\[0.81.0\\]"):
            notes.assemble(self.repo.path, "0.81.0", authors({}), [], False, "2026-10-20")


@unittest.skipIf(towncrier_missing(), "towncrier is not installed")
class TowncrierTests(unittest.TestCase):
    def setUp(self):
        directory = tempfile.TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        self.repo = FixtureRepository(Path(directory.name))
        self.repo.fragment("3500.added.md", "Beta channel.")
        self.repo.fragment("3501.fixed.md", "Crash on open.")
        self.repo.fragment("3501.fixed.1.md", "Hang on close.")
        self.repo.fragment("+tidy.changed.md", "Quieter logs.")
        self.repo.commit("feat: fragments")
        self.repo.git("update-ref", "refs/remotes/origin/release/0.82", "HEAD")
        self.author_of = authors({3500: ("i87ce", "CONTRIBUTOR"), 3501: ("datlechin", "OWNER")})

    def test_a_beta_body_is_the_credited_draft_without_a_heading(self):
        body = notes.release_body(self.repo.path, "0.82.0-beta.1", self.author_of)
        self.assertTrue(body.startswith("\n".join([
            "### Added",
            "",
            "- Beta channel by @i87ce. ([#3500](https://github.com/TableProApp/TablePro/pull/3500))",
            "",
            "### Changed",
            "",
            "- Quieter logs.",
            "",
            "### Fixed",
            "",
        ])))
        self.assertEqual(sorted(body.splitlines()[-2:]), [
            "- Crash on open. ([#3501](https://github.com/TableProApp/TablePro/pull/3501))",
            "- Hang on close. ([#3501](https://github.com/TableProApp/TablePro/pull/3501))",
        ])
        self.assertTrue(body.endswith("))\n"))
        self.assertEqual((self.repo.path / notes.FRAGMENTS / "3500.added.md").read_text(encoding="utf-8"),
                         "Beta channel.\n")

    def test_a_beta_feed_links_the_github_release(self):
        text = notes.feed(self.repo.path, "0.82.0-beta.1", self.author_of)
        self.assertTrue(text.startswith("# What's New in TablePro 0.82.0-beta.1\n\n### Added\n"))
        self.assertTrue(text.endswith(
            "\n\n[View release notes](https://github.com/TableProApp/TablePro/releases/tag/v0.82.0-beta.1)\n"))

    def test_a_bad_fragment_name_fails_the_draft(self):
        self.repo.fragment("3502.feature.md", "Wrong type.")
        self.author_of = authors({3500: ("i87ce", "CONTRIBUTOR"), 3501: ("a", "OWNER"), 3502: ("a", "OWNER")})
        with self.assertRaisesRegex(notes.NotesError, "3502.feature.md"):
            notes.release_body(self.repo.path, "0.82.0-beta.1", self.author_of)

    def test_assemble_writes_the_section_and_consumes_the_fragments(self):
        notes.assemble(self.repo.path, "0.82.0", self.author_of, ["Beta updates.", "Plugins follow the app."],
                       True, "2026-10-20")
        changelog = (self.repo.path / "CHANGELOG.md").read_text(encoding="utf-8")
        self.assertIn(
            f"{MARKER}\n\n"
            "## [0.82.0](https://github.com/TableProApp/TablePro/releases/tag/v0.82.0) - 2026-10-20 [CRITICAL]\n\n"
            "Beta updates.\nPlugins follow the app.\n\n### Added\n\n"
            "- Beta channel by @i87ce. ([#3500](https://github.com/TableProApp/TablePro/pull/3500))\n",
            changelog,
        )
        self.assertIn("\n## [0.81.0] - 2026-10-16\n", changelog)
        section = notes.find_section(changelog, "0.82.0")
        self.assertTrue(section.is_critical)
        self.assertEqual(section.lead, ["Beta updates.", "Plugins follow the app."])
        self.assertEqual(sorted(path.name for path in (self.repo.path / notes.FRAGMENTS).iterdir()), [".gitkeep"])
        staged = self.repo.git("diff", "--cached", "--name-status").splitlines()
        self.assertIn("M\tCHANGELOG.md", staged)
        self.assertIn(f"D\t{notes.FRAGMENTS}/3500.added.md", staged)
        self.assertEqual(self.repo.git("diff", "--name-only"), "")

    def test_assemble_after_a_revert_of_an_unpublished_stable(self):
        self.repo.commit('Revert "chore(release): v0.82.0"')
        notes.assemble(self.repo.path, "0.82.1", self.author_of, [], False, "2026-10-21")
        changelog = (self.repo.path / "CHANGELOG.md").read_text(encoding="utf-8")
        section = notes.find_section(changelog, "0.82.1")
        self.assertEqual((section.date, section.is_critical, section.lead), ("2026-10-21", False, []))


if __name__ == "__main__":
    unittest.main()
