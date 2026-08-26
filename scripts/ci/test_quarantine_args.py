#!/usr/bin/env python3
"""Tests for quarantine_args.py, whose stdout is read one line per xcodebuild argument.

Run: python3 scripts/ci/test_quarantine_args.py

The first test is the one that matters. `print("\\n".join([]))` is a blank line, the caller turns
every line into an argument, and xcodebuild reads an empty argument as a build action: `Unknown
build action ''`, exit 65, before a single test runs. An empty quarantine file is the goal the file
itself states, so main went red the commit the last entry was removed and stayed red for three
commits.
"""
import importlib.util
import io
import json
import os
import sys
import tempfile
from contextlib import redirect_stdout

_spec = importlib.util.spec_from_file_location(
    "quarantine_args",
    os.path.join(os.path.dirname(__file__), "quarantine_args.py"),
)
quarantine_args = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(quarantine_args)

ENUMERATED = ["TableProTests/SomeSuite/someCase()", "TableProTests/OtherSuite/otherCase()"]


def _run(quarantine_text, identifiers=None):
    """Returns (stdout, exit code or None), the way the shell caller sees it."""
    with tempfile.TemporaryDirectory() as work:
        quarantine = os.path.join(work, "quarantine.txt")
        with open(quarantine, "w", encoding="utf-8") as handle:
            handle.write(quarantine_text)

        enumeration = os.path.join(work, "tests.json")
        listed = ENUMERATED if identifiers is None else identifiers
        with open(enumeration, "w", encoding="utf-8") as handle:
            json.dump({"values": [{"enabledTests": [{"identifier": i} for i in listed]}]}, handle)

        os.environ["QUARANTINE"] = quarantine
        os.environ["TARGET"] = "TableProTests"
        argv = sys.argv
        sys.argv = ["quarantine_args.py", enumeration]
        captured = io.StringIO()
        status = None
        try:
            with redirect_stdout(captured):
                quarantine_args.main()
        except SystemExit as error:
            status = error.code
        finally:
            sys.argv = argv
        return captured.getvalue(), status


def test_an_empty_list_prints_nothing_at_all():
    """Not even a newline. One blank line is one empty argument, and xcodebuild refuses the run."""
    out, status = _run("# every entry has been burned down\n#\n")
    assert out == "", repr(out)
    assert status is None, status


def test_a_file_of_only_whitespace_prints_nothing():
    out, status = _run("\n   \n\t\n")
    assert out == "", repr(out)
    assert status is None, status


def test_no_line_is_ever_empty():
    """The caller reads one argument per line, so a blank one is unrepresentable by construction."""
    out, _ = _run("SomeSuite/someCase()\nOtherSuite/otherCase()\n")
    assert out.splitlines() == [
        "-skip-testing:TableProTests/SomeSuite/someCase()",
        "-skip-testing:TableProTests/OtherSuite/otherCase()",
    ], out
    assert all(line.strip() for line in out.splitlines()), repr(out)


def test_a_whole_suite_is_accepted_without_a_case():
    out, _ = _run("SomeSuite\n")
    assert out.splitlines() == ["-skip-testing:TableProTests/SomeSuite"], out


def test_an_entry_that_would_skip_nothing_still_fails_the_job():
    """The guard the script exists for, unchanged by the empty-list fix."""
    out, status = _run("NoSuchSuite/nope()\n")
    assert status == 1, status
    assert out == "", repr(out)


def test_a_swift_testing_case_without_its_parentheses_still_fails():
    out, status = _run("SomeSuite/someCase\n")
    assert status == 1, status
    assert out == "", repr(out)


if __name__ == "__main__":
    test_an_empty_list_prints_nothing_at_all()
    test_a_file_of_only_whitespace_prints_nothing()
    test_no_line_is_ever_empty()
    test_a_whole_suite_is_accepted_without_a_case()
    test_an_entry_that_would_skip_nothing_still_fails_the_job()
    test_a_swift_testing_case_without_its_parentheses_still_fails()
    print("All quarantine-args tests passed.")
