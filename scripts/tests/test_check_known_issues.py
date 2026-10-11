import importlib.util
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location("check_known_issues", ROOT / "scripts/check-known-issues.py")
checker = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(checker)

HEADER = "| ID | Issue | Status | Next | Layer |\n| --- | --- | --- | --- | --- |\n"


def problems(rows):
    return checker.problems(HEADER + rows)


class KnownIssuesTests(unittest.TestCase):
    def test_a_well_formed_ledger_has_no_problems(self):
        rows = "| UI-1 | ~~Done thing~~ | DONE | PR | unit |\n| UI-2 | Open thing | OPEN | next | unit |\n"
        self.assertEqual(problems(rows), [])

    def test_a_done_row_must_be_crossed_out(self):
        self.assertEqual(len(problems("| UI-1 | Done thing | DONE | PR | unit |\n")), 1)

    def test_an_open_row_must_not_be_crossed_out(self):
        self.assertEqual(len(problems("| UI-1 | ~~Open thing~~ | OPEN | n | unit |\n")), 1)

    def test_status_must_be_known(self):
        self.assertEqual(len(problems("| UI-1 | Thing | MAYBE | n | unit |\n")), 1)

    def test_ids_must_be_unique(self):
        rows = "| UI-1 | A | OPEN | n | unit |\n| UI-1 | B | OPEN | n | unit |\n"
        self.assertEqual(len(problems(rows)), 1)

    def test_a_done_row_needs_evidence(self):
        self.assertEqual(len(problems("| UI-1 | ~~Done~~ | DONE |  | unit |\n")), 1)

    def test_every_open_row_needs_exactly_one_owner(self):
        rows = "| UI-1 | Open | OPEN | n | unit |\n| UI-2 | ~~Done~~ | DONE | PR | unit |\n"
        owners = "\n## Owners and handoff\n\n| Owner | Open rows | Next |\n| --- | --- | --- |\n"
        self.assertEqual(checker.owner_problems(HEADER + rows + owners + "| A | UI-1 | x |\n"), [])
        self.assertEqual(checker.owner_problems(HEADER + rows + owners + "| A | UI-3 | x |\n").__len__(), 2)
        self.assertEqual(len(checker.owner_problems(HEADER + rows + owners + "| A | UI-1 | x |\n| B | UI-1 | y |\n")), 1)
        self.assertEqual(checker.owner_problems(HEADER + rows), ["the ledger has no owners section"])

    def test_the_real_ledger_is_consistent(self):
        text = (ROOT / "docs/known-issues.md").read_text()
        self.assertEqual(checker.problems(text) + checker.owner_problems(text), [])


if __name__ == "__main__":
    unittest.main()
