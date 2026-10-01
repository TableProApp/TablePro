#!/usr/bin/env python3
"""Tests for check-pr-title.py.

Run: python3 scripts/ci/test_check_pr_title.py
"""

import importlib.util
import io
import unittest
from contextlib import redirect_stdout
from pathlib import Path

SPEC = importlib.util.spec_from_file_location("check_pr_title", Path(__file__).with_name("check-pr-title.py"))
check = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(check)


class SubjectShapeTests(unittest.TestCase):
    def test_every_listed_type_is_accepted(self):
        for kind in check.TYPES:
            with self.subTest(kind=kind):
                self.assertEqual(check.problems(f"{kind}: tidy one thing"), [])

    def test_a_scope_and_a_breaking_marker_are_accepted(self):
        self.assertEqual(check.problems("refactor(ai-providers)!: drop the legacy endpoint"), [])
        self.assertEqual(check.problems("feat!: drop macOS 12"), [])
        self.assertEqual(check.problems("fix(plugin-mongodb): keep binary ids"), [])

    def test_an_unknown_type_is_refused(self):
        self.assertEqual(len(check.problems("release: v0.77.0")), 1)
        self.assertEqual(len(check.problems("feature(editor): add a thing")), 1)

    def test_a_plain_sentence_is_refused(self):
        self.assertEqual(len(check.problems("Update appcast.xml for v0.76.1")), 1)

    def test_a_malformed_scope_is_refused(self):
        for title in ("fix(): empty scope", "fix(Editor): capital scope", "fix(editor) : space", "fix (editor): space"):
            with self.subTest(title=title):
                self.assertEqual(len(check.problems(title)), 1)

    def test_a_missing_description_is_refused(self):
        self.assertEqual(len(check.problems("fix(editor):")), 1)
        self.assertEqual(len(check.problems("fix(editor):  ")), 1)
        self.assertEqual(len(check.problems("fix(editor):no space")), 1)


class LengthTests(unittest.TestCase):
    def test_the_title_alone_is_measured(self):
        title = "fix: " + "x" * (check.MAX_TITLE - len("fix: "))
        self.assertEqual(check.problems(title), [])
        self.assertEqual(len(check.problems(title + "x")), 1)

    def test_a_long_title_in_the_wrong_shape_reports_both(self):
        self.assertEqual(len(check.problems("Fix " + "x" * 100)), 2)


class OutputTests(unittest.TestCase):
    def run_main(self, *argv):
        captured = io.StringIO()
        with redirect_stdout(captured):
            status = check.main(["check-pr-title.py", *argv])
        return status, captured.getvalue()

    def test_a_good_title_passes_and_prints_the_subject(self):
        status, out = self.run_main("fix(editor): keep the caret")
        self.assertEqual(status, 0)
        self.assertIn("OK: fix(editor): keep the caret", out)

    def test_a_bad_title_fails_with_one_annotation_per_problem(self):
        status, out = self.run_main("Fix the editor")
        self.assertEqual(status, 1)
        self.assertEqual(out.count("::error "), 1)

    def test_a_title_cannot_inject_a_workflow_command(self):
        status, out = self.run_main("Bad\n::add-mask::secret %")
        self.assertEqual(status, 1)
        self.assertEqual(len(out.splitlines()), 1)
        self.assertIn("%0A::add-mask::secret %25", out)


if __name__ == "__main__":
    unittest.main()
