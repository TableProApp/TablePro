#!/usr/bin/env python3
"""Fixture tests for check-classifier-text-matching.py."""

import contextlib
import importlib.util
import io
import tempfile
import unittest
from pathlib import Path

SPEC = importlib.util.spec_from_file_location(
    "check_classifier_text_matching", Path(__file__).with_name("check-classifier-text-matching.py")
)
check = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(check)

# The ALTER test as it shipped in 0.84.0-beta.2.
REPORTED = '''enum QueryClassifier {
    static func dropsData(_ body: String) -> Bool {
        body.range(of: " DROP ", options: .literal) != nil
    }
    static let whereClauseRegex = try? NSRegularExpression(pattern: "\\\\sWHERE\\\\s", options: [])
}
'''

TOKENS = '''// A regex or range(of:) would read words another way, so the tokens decide.
/* NSRegularExpression is not used here. */
enum SQLStatementTiering {
    static func dropsData(_ code: StatementCode) -> Bool {
        code.containsAny(["DROP", "TRUNCATE"])
    }
}
'''


class CheckClassifierTextMatchingTests(unittest.TestCase):
    def run_check(self, source):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "QueryClassifier.swift"
            path.write_text(source, encoding="utf-8")
            output = io.StringIO()
            with contextlib.redirect_stdout(output):
                status = check.main([str(path)])
            return status, output.getvalue()

    def test_reported_matchers_fail(self):
        status, output = self.run_check(REPORTED)
        self.assertEqual(status, 1)
        self.assertIn(":3: range(of:", output)
        self.assertIn(":5: NSRegularExpression", output)

    def test_token_reads_and_comments_pass(self):
        status, output = self.run_check(TOKENS)
        self.assertEqual(status, 0, output)

    def test_a_matcher_after_a_string_still_fails(self):
        status, output = self.run_check('let a = "//"; let b = text.range(of: "x")\n')
        self.assertEqual(status, 1)
        self.assertIn(":1: range(of:", output)

    def test_shipped_classifiers_pass(self):
        output = io.StringIO()
        with contextlib.redirect_stdout(output):
            status = check.main([])
        self.assertEqual(status, 0, output.getvalue())

    def test_missing_path_is_an_error(self):
        with contextlib.redirect_stderr(io.StringIO()):
            self.assertEqual(check.main(["/nonexistent/QueryClassifier.swift"]), 2)


if __name__ == "__main__":
    unittest.main()
