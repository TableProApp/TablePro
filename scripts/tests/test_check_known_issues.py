import importlib.util
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location("check_known_issues", ROOT / "scripts/check-known-issues.py")
checker = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(checker)

PREFIX = (
    "Open work lives on [Bookie Project #3](https://github.com/users/cozyGarage/projects/3).\n\n"
    "## Open work index\n\n"
    "| ID | Issue | Lane |\n"
    "| --- | --- | --- |\n"
)


def problems(rows):
    return checker.problems(PREFIX + rows)


class KnownIssuesTests(unittest.TestCase):
    def test_a_well_formed_index_has_no_problems(self):
        rows = "| UI-1 | [#1](https://github.com/cozyGarage/BookiE/issues/1) | B3 |\n"
        self.assertEqual(problems(rows), [])

    def test_project_url_is_required(self):
        text = "## Open work index\n\n| ID | Issue | Lane |\n| --- | --- | --- |\n| UI-1 | [#1](https://github.com/cozyGarage/BookiE/issues/1) | B3 |\n"
        self.assertTrue(any("project URL" in item for item in checker.problems(text)))

    def test_issue_link_must_match_number(self):
        self.assertEqual(len(problems("| UI-1 | [#1](https://github.com/cozyGarage/BookiE/issues/2) | B3 |\n")), 1)

    def test_lane_must_be_known(self):
        self.assertEqual(len(problems("| UI-1 | [#1](https://github.com/cozyGarage/BookiE/issues/1) | Other |\n")), 1)

    def test_ids_must_be_unique(self):
        rows = (
            "| UI-1 | [#1](https://github.com/cozyGarage/BookiE/issues/1) | B3 |\n"
            "| UI-1 | [#2](https://github.com/cozyGarage/BookiE/issues/2) | B4 |\n"
        )
        self.assertEqual(len(problems(rows)), 1)

    def test_the_real_ledger_is_consistent(self):
        text = (ROOT / "docs/known-issues.md").read_text()
        self.assertEqual(checker.problems(text), [])


if __name__ == "__main__":
    unittest.main()
