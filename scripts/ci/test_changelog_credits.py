#!/usr/bin/env python3
"""Tests for the contributor credit the release stamps on CHANGELOG entries.

Run: python3 scripts/ci/test_changelog_credits.py
"""

import unittest

import changelog_credits as credits


SHA_A = "a" * 40
SHA_B = "b" * 40


class CreditEntryTests(unittest.TestCase):
    def test_an_entry_with_no_reference_gains_the_pull_request_and_its_author(self):
        self.assertEqual(
            credits.credit_entry("- Two chevrons on the Tags row.", "2919", "datlechin"),
            "- Two chevrons on the Tags row. (#2919 by @datlechin)",
        )

    def test_an_issue_reference_stays_first_and_the_pull_request_joins_it(self):
        self.assertEqual(
            credits.credit_entry("- OceanBase connection type. (#1748)", "2741", "J2TeamNNL"),
            "- OceanBase connection type. (#1748, #2741 by @J2TeamNNL)",
        )

    def test_a_reference_that_is_already_the_pull_request_is_not_repeated(self):
        self.assertEqual(
            credits.credit_entry("- Crash on launch. (#2930)", "2930", "datlechin"),
            "- Crash on launch. (#2930 by @datlechin)",
        )

    def test_several_references_keep_their_order(self):
        self.assertEqual(
            credits.credit_entry("- Spanner plugin. (#1226, #2480)", "2481", "datlechin"),
            "- Spanner plugin. (#1226, #2480, #2481 by @datlechin)",
        )

    def test_a_trailing_parenthetical_that_is_not_a_reference_is_left_as_prose(self):
        self.assertEqual(
            credits.credit_entry("- Empty object copied as an array. (Copy Objects)", "2926", "datlechin"),
            "- Empty object copied as an array. (Copy Objects) (#2926 by @datlechin)",
        )

    def test_crediting_twice_changes_nothing(self):
        once = credits.credit_entry("- Nested fields shown as null.", "2905", "digows")
        self.assertEqual(credits.credit_entry(once, "2905", "digows"), once)

    def test_a_github_app_is_credited_by_its_name(self):
        self.assertEqual(
            credits.credit_entry("- Bumped a dependency.", "12", "app/dependabot"),
            "- Bumped a dependency. (#12 by @dependabot)",
        )

    def test_trailing_whitespace_does_not_hide_the_references(self):
        self.assertEqual(
            credits.credit_entry("- Stale grid. (#100)  ", "101", "filipac"),
            "- Stale grid. (#100, #101 by @filipac)",
        )

    def test_a_maintainer_entry_gains_the_pull_request_alone(self):
        self.assertEqual(
            credits.credit_entry("- Two chevrons on the Tags row.", "2919", None),
            "- Two chevrons on the Tags row. (#2919)",
        )

    def test_a_maintainer_entry_keeps_its_issue_reference_first(self):
        self.assertEqual(
            credits.credit_entry("- OceanBase connection type. (#1748)", "2741", None),
            "- OceanBase connection type. (#1748, #2741)",
        )

    def test_crediting_a_maintainer_entry_twice_changes_nothing(self):
        once = credits.credit_entry("- Crash on launch.", "2930", None)
        self.assertEqual(credits.credit_entry(once, "2930", None), once)


class FakeCompleted:
    def __init__(self, returncode, stdout=""):
        self.returncode = returncode
        self.stdout = stdout


class FakeGitHub:
    def __init__(self, roles):
        self.roles = roles
        self.asked = []

    def __call__(self, command, **_):
        login = command[2].split("/")[-2]
        self.asked.append(login)
        if login not in self.roles:
            return FakeCompleted(1)
        return FakeCompleted(0, self.roles[login] + "\n")


class MaintainerTests(unittest.TestCase):
    def test_admin_and_maintain_roles_are_maintainers(self):
        maintainers = credits.Maintainers(run=FakeGitHub({"owner": "admin", "helper": "maintain"}))
        self.assertTrue(maintainers.includes("owner"))
        self.assertTrue(maintainers.includes("helper"))

    def test_write_triage_and_read_roles_are_contributors(self):
        github = FakeGitHub({"committer": "write", "triager": "triage", "digows": "read"})
        maintainers = credits.Maintainers(run=github)
        self.assertFalse(maintainers.includes("committer"))
        self.assertFalse(maintainers.includes("triager"))
        self.assertFalse(maintainers.includes("digows"))

    def test_each_login_is_asked_once(self):
        github = FakeGitHub({"owner": "admin"})
        maintainers = credits.Maintainers(run=github)
        maintainers.includes("owner")
        maintainers.includes("owner")
        self.assertEqual(github.asked, ["owner"])

    def test_an_unreadable_role_keeps_the_handle_and_is_reported(self):
        maintainers = credits.Maintainers(run=FakeGitHub({}))
        self.assertFalse(maintainers.includes("J2TeamNNL"))
        self.assertEqual(maintainers.unknown, {"J2TeamNNL"})

    def test_a_github_app_is_never_a_maintainer_and_is_not_looked_up(self):
        github = FakeGitHub({})
        maintainers = credits.Maintainers(run=github)
        self.assertFalse(maintainers.includes("app/dependabot"))
        self.assertEqual(github.asked, [])
        self.assertEqual(maintainers.unknown, set())


class SectionTests(unittest.TestCase):
    CHANGELOG = [
        "# Changelog",
        "",
        "## [Unreleased]",
        "",
        "### Fixed",
        "",
        "- One.",
        "",
        "## [1.0.0] - 2026-01-01",
        "",
        "- Old.",
    ]

    def test_the_section_runs_to_the_next_version_heading(self):
        self.assertEqual(credits.section_bounds(self.CHANGELOG, "Unreleased"), (3, 8))

    def test_the_last_section_runs_to_the_end_of_the_file(self):
        self.assertEqual(credits.section_bounds(self.CHANGELOG, "1.0.0"), (9, 11))

    def test_a_missing_section_is_an_error(self):
        with self.assertRaises(ValueError):
            credits.section_bounds(self.CHANGELOG, "9.9.9")


class BlameTests(unittest.TestCase):
    PORCELAIN = "\n".join([
        f"{SHA_A} 7 7 1",
        "author Someone",
        "summary fix(editor): keep the caret (#2915)",
        "filename CHANGELOG.md",
        "\t- One.",
        f"{SHA_B} 8 8 1",
        "author Someone",
        "summary chore: tidy the changelog",
        "filename CHANGELOG.md",
        "\t- Two.",
        f"{credits.UNCOMMITTED} 9 9 1",
        "author Not Committed Yet",
        "summary Version CHANGELOG.md",
        "filename CHANGELOG.md",
        "\t- Three.",
        "",
    ])

    def test_each_line_keeps_the_commit_that_wrote_it(self):
        blamed = credits.parse_blame(self.PORCELAIN)
        self.assertEqual([record.sha for record in blamed], [SHA_A, SHA_B, credits.UNCOMMITTED])

    def test_a_squash_merge_names_its_pull_request(self):
        blamed = credits.parse_blame(self.PORCELAIN)
        self.assertEqual(credits.pull_request_of(blamed[0]), "2915")

    def test_a_direct_push_names_no_pull_request(self):
        blamed = credits.parse_blame(self.PORCELAIN)
        self.assertIsNone(credits.pull_request_of(blamed[1]))

    def test_an_uncommitted_line_names_no_pull_request(self):
        blamed = credits.parse_blame(self.PORCELAIN)
        self.assertIsNone(credits.pull_request_of(blamed[2]))


if __name__ == "__main__":
    unittest.main()
