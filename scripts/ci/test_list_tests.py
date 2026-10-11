#!/usr/bin/env python3
"""Tests for list_tests.py, whose stdout is read one line per xcodebuild argument.

Run: python3 scripts/ci/test_list_tests.py
"""

import io
import json
import os
import sys
import tempfile
import unittest
from contextlib import redirect_stdout

import list_tests

ENUMERATED = [
    "TableProTests/SomeSuite/someCase()",
    "TableProTests/SomeSuite/otherCase()",
    "TableProTests/OtherSuite/testThing",
]


def run(quarantine_text, mode="", shard="", identifiers=None):
    """(stdout, exit code or None), the way the shell caller sees it."""
    with tempfile.TemporaryDirectory() as work:
        quarantine = os.path.join(work, "quarantine.txt")
        with open(quarantine, "w", encoding="utf-8") as handle:
            handle.write(quarantine_text)
        enumeration = os.path.join(work, "tests.json")
        listed = ENUMERATED if identifiers is None else identifiers
        with open(enumeration, "w", encoding="utf-8") as handle:
            json.dump({"values": [{"enabledTests": [{"identifier": i} for i in listed]}]}, handle)

        environment = {"TARGET": "TableProTests", "QUARANTINE": quarantine, "MODE": mode, "SHARD": shard}
        saved_environment = dict(os.environ)
        saved_argv = sys.argv
        os.environ.update(environment)
        sys.argv = ["list_tests.py", enumeration]
        captured = io.StringIO()
        status = None
        try:
            with redirect_stdout(captured):
                list_tests.main()
        except SystemExit as error:
            status = error.code
        finally:
            sys.argv = saved_argv
            os.environ.clear()
            os.environ.update(saved_environment)
        return captured.getvalue(), status


class SkipModeTests(unittest.TestCase):
    def test_an_empty_list_prints_nothing_at_all(self):
        out, status = run("# header only\n#\n\n", mode="skip")
        self.assertEqual(out, "")
        self.assertIsNone(status)

    def test_a_case_is_skipped_by_its_enumerated_identifier(self):
        out, status = run("# flaky on the runner\nSomeSuite/someCase()\n", mode="skip")
        self.assertEqual(out.splitlines(), ["-skip-testing:TableProTests/SomeSuite/someCase()"])
        self.assertIsNone(status)

    def test_a_whole_suite_skips_each_of_its_cases(self):
        out, _ = run("SomeSuite\n", mode="skip")
        self.assertEqual(
            out.splitlines(),
            ["-skip-testing:TableProTests/SomeSuite/otherCase()", "-skip-testing:TableProTests/SomeSuite/someCase()"],
        )

    def test_no_line_is_ever_empty(self):
        out, _ = run("SomeSuite/someCase()\nOtherSuite/testThing\n", mode="skip")
        self.assertTrue(all(line.strip() for line in out.splitlines()), repr(out))


class InertEntryTests(unittest.TestCase):
    def test_an_entry_that_matches_nothing_fails(self):
        out, status = run("NoSuchSuite/nope()\n", mode="skip")
        self.assertIn("NoSuchSuite/nope()", str(status))
        self.assertEqual(out, "")

    def test_a_swift_testing_case_without_its_parentheses_fails(self):
        out, status = run("SomeSuite/someCase\n")
        self.assertIn("parentheses", str(status))
        self.assertEqual(out, "")


class ShardTests(unittest.TestCase):
    def test_shards_split_the_unquarantined_cases_round_robin(self):
        first, _ = run("OtherSuite/testThing\n", shard="0/2")
        second, _ = run("OtherSuite/testThing\n", shard="1/2")
        self.assertEqual(first.splitlines(), ["-only-testing:TableProTests/SomeSuite/otherCase()"])
        self.assertEqual(second.splitlines(), ["-only-testing:TableProTests/SomeSuite/someCase()"])

    def test_without_a_shard_every_unquarantined_case_runs(self):
        out, _ = run("")
        self.assertEqual(len(out.splitlines()), len(ENUMERATED))

    def test_quarantining_everything_fails(self):
        _, status = run("SomeSuite\nOtherSuite\n")
        self.assertIn("every enumerated case", str(status))


if __name__ == "__main__":
    unittest.main()
