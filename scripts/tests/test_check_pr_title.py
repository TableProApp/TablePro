import importlib.util
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location("check_pr_title", ROOT / "scripts/check-pr-title.py")
check = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(check)


class PrTitleTests(unittest.TestCase):
    def test_conventional_subjects_are_accepted(self):
        for title in (
            "fix(editor): keep the caret",
            "feat(driver-postgres): page large results",
            "docs: reconcile post-release claims",
            "refactor(app)!: rename the window message",
            "security(app): omit payloads from cleanup diagnostics",
            "chore(release): 0.2.1",
        ):
            with self.subTest(title=title):
                self.assertEqual(check.problems(title), [])

    def test_branch_derived_and_malformed_titles_are_refused(self):
        for title in (
            "Fix/dump etxtbs",
            "Ux/quit unreachable host",
            "fix:missing space",
            "fix(Editor): uppercase scope",
            "feature(app): unknown type",
            "fix(app): ",
            "",
        ):
            with self.subTest(title=title):
                self.assertTrue(check.problems(title))

    def test_overlong_titles_are_refused(self):
        self.assertTrue(check.problems("fix(app): " + "x" * 100))

    def test_workflow_command_data_escapes_control_characters(self):
        self.assertEqual(check.workflow_command_data("a%b\nc"), "a%25b%0Ac")


if __name__ == "__main__":
    unittest.main()
