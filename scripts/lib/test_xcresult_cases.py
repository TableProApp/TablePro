#!/usr/bin/env python3
"""Tests for xcresult-cases.py. The fixtures keep the shape of xcresulttool 25115 output.

Run: python3 -m unittest discover -s scripts/lib -p 'test_*.py'
"""

import importlib.util
import io
import tempfile
import unittest
from contextlib import redirect_stderr, redirect_stdout
from pathlib import Path

SPEC = importlib.util.spec_from_file_location("xcresult_cases", Path(__file__).with_name("xcresult-cases.py"))
parser = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(parser)


def case(ident, result, seconds=0.5, children=None):
    node = {"nodeType": "Test Case", "name": ident.rpartition("/")[2], "nodeIdentifier": ident,
            "result": result, "durationInSeconds": seconds}
    if children:
        node["children"] = children
    return node


def suite(name, *children):
    return {"nodeType": "Test Suite", "name": name, "children": list(children)}


def repetition(result, message=None):
    node = {"nodeType": "Repetition", "name": "First Run", "result": result}
    if message:
        node["children"] = [{"nodeType": "Failure Message", "name": message}]
    return node


MIXED = {"testNodes": [{"nodeType": "Test Plan", "name": "Unit", "children": [
    {"nodeType": "Unit test bundle", "name": "ProbeTests", "children": [
        case("freeFunction()", "Passed"),
        suite("ClassicTests",
              case("ClassicTests/testExpected()", "Expected Failure",
                   children=[{"nodeType": "Expected Failure", "name": "known"}]),
              case("ClassicTests/testFails()", "Failed", children=[
                  repetition("Failed", "XCTAssertEqual failed: (\"4\") is not equal to (\"5\")"),
                  repetition("Failed", "XCTAssertEqual failed: (\"4\") is not equal to (\"5\")")]),
              case("ClassicTests/testFlaky()", "Passed", children=[
                  repetition("Failed", "first try fails"), repetition("Passed")]),
              case("ClassicTests/testSkipped()", "Skipped",
                   children=[{"nodeType": "Skip Message", "name": "Test skipped - not here"}]),
              case("ClassicTests/testOdd()", "unknown")),
        suite("Outer",
              suite("Inner",
                    case("Outer/Inner/nestedPasses()", "Passed", seconds=12.0),
                    case("Outer/Inner/nestedFails()", "Failed", children=[
                        {"nodeType": "Failure Message", "name": "Expectation failed: double(3) == 7\ndouble(3) → 6"}])),
              case("Outer/parameterized(value:)", "Passed", children=[
                  {"nodeType": "Arguments", "name": "2", "result": "Passed",
                   "children": [repetition("Failed", "flaky argument"), repetition("Passed")]}])),
    ]},
    {"nodeType": "UI test bundle", "name": "OnlySkippedTests", "children": [
        suite("OnlySkipped", case("OnlySkipped/testSkipped()", "Skipped"))]},
]}]}

RUNNER_FAILED = {"testNodes": [{"nodeType": "Test Plan", "name": "TableProMobile", "children": [
    {"nodeType": "Unit test bundle", "name": "TableProMobileTests", "children": [
        suite("System Failures", {
            "nodeType": "Test Case", "name": "TableProMobile encountered an error",
            "nodeIdentifier": "TableProMobile encountered an error", "result": "Failed",
            "children": [{"nodeType": "Failure Message",
                          "name": "Failed to prepare device 'iPhone 18 Pro' for impending launch."}]})]}]}]}

RUNNER_BUILD = {"errors": [{"issueType": "Uncategorized", "message":
                            "TableProMobile encountered an error (Failed to prepare device 'iPhone 18 Pro')"}]}

BROKEN_BUILD = {"errors": [
    {"issueType": "Uncategorized", "message": "Testing cancelled because the build failed."},
    {"issueType": "Swift Compiler Error", "message": "Cannot convert value of type 'String' to specified type 'Int'",
     "sourceURL": "file:///Users/runner/work/TablePro/TablePro/Some%20Dir/Broken.swift"
                  "#EndingColumnNumber=21&EndingLineNumber=3&StartingColumnNumber=21&StartingLineNumber=3"
                  "&Timestamp=813945273.172478"},
    {"issueType": "Uncategorized", "message": "Linker command failed with exit code 1"},
]}

XCTEST_XUNIT = """<?xml version="1.0" encoding="UTF-8"?>
<testsuites>
<testsuite name="TestResults" errors="0" tests="3" failures="1" time="1.0">
<testcase classname="ProbeTests.ClassicTests" name="testPasses" time="0.25">
</testcase>
<testcase classname="ProbeTests.ClassicTests" name="testFails" time="0.5">
<failure message="failure"></failure>
</testcase>
<testcase classname="OtherTests.OnlySkippedTests" name="testSkipped" time="0.1">
</testcase>
</testsuite>
</testsuites>
"""

SWIFT_TESTING_XUNIT = """<?xml version="1.0" encoding="UTF-8"?>
<testsuites>
    <testsuite name="TestResults" errors="0" tests="3" failures="1" skipped="1" time="0.001">
        <testcase classname="ProbeTests.Outer.Inner" name="nestedFails()" time="0.0007">
            <failure message="Expectation failed: double(3) == 7 (error)"/>
        </testcase>
        <testcase classname="ProbeTests.Outer" name="disabled()">
            <skipped>off</skipped>
        </testcase>
        <testcase classname="ProbeTests" name="freeFunction()" time="0.0002"/>
    </testsuite>
</testsuites>
"""


def by_label(cases):
    return {case.label: case for case in cases}


class BundleCaseTests(unittest.TestCase):
    def setUp(self):
        self.targets = parser.bundle_cases(MIXED)
        self.cases = by_label(case for _, cases in self.targets for case in cases)

    def test_labels_are_target_then_node_identifier(self):
        self.assertIn("ProbeTests/freeFunction()", self.cases)
        self.assertIn("ProbeTests/ClassicTests/testFails()", self.cases)
        self.assertIn("ProbeTests/Outer/Inner/nestedPasses()", self.cases)
        self.assertEqual(self.cases["ProbeTests/Outer/Inner/nestedPasses()"].suite, "ProbeTests/Outer/Inner")
        self.assertEqual(self.cases["ProbeTests/freeFunction()"].suite, "ProbeTests")

    def test_a_target_with_only_skipped_cases_is_kept(self):
        self.assertEqual([name for name, _ in self.targets], ["ProbeTests", "OnlySkippedTests"])

    def test_results(self):
        self.assertEqual(self.cases["ProbeTests/ClassicTests/testExpected()"].result, "Expected Failure")
        self.assertEqual(self.cases["ProbeTests/ClassicTests/testSkipped()"].result, "Skipped")
        self.assertEqual(self.cases["ProbeTests/ClassicTests/testOdd()"].result, "Failed")

    def test_a_pass_after_a_failed_repetition_is_a_retry(self):
        self.assertTrue(self.cases["ProbeTests/ClassicTests/testFlaky()"].retried)
        self.assertTrue(self.cases["ProbeTests/Outer/parameterized(value:)"].retried)
        self.assertFalse(self.cases["ProbeTests/ClassicTests/testFails()"].retried)
        self.assertFalse(self.cases["ProbeTests/freeFunction()"].retried)

    def test_a_failure_keeps_its_first_message(self):
        self.assertEqual(self.cases["ProbeTests/ClassicTests/testFails()"].message,
                         "XCTAssertEqual failed: (\"4\") is not equal to (\"5\")")
        self.assertEqual(self.cases["ProbeTests/ClassicTests/testFlaky()"].message, "")

    def test_a_system_failure_is_a_runner_failure(self):
        [(target, cases)] = parser.bundle_cases(RUNNER_FAILED)
        self.assertEqual(target, "TableProMobileTests")
        self.assertEqual([(case.result, case.label) for case in cases],
                         [("System Failure", "TableProMobileTests/TableProMobile encountered an error")])
        self.assertTrue(cases[0].message.startswith("Failed to prepare device"))

    def test_a_plan_without_a_bundle_is_its_own_target(self):
        tree = {"testNodes": [{"nodeType": "Test Plan", "name": "UI", "children": [
            suite("System Failures", case("UI encountered an error", "Failed"))]}]}
        [(target, cases)] = parser.bundle_cases(tree)
        self.assertEqual((target, cases[0].result), ("UI", "System Failure"))

    def test_a_failed_test_build_has_no_target(self):
        self.assertEqual(parser.bundle_cases({"testNodes": []}), [])


class BuildErrorTests(unittest.TestCase):
    def test_lines_are_one_based_and_testing_cancelled_is_dropped(self):
        self.assertEqual(list(parser.build_errors(BROKEN_BUILD)), [
            ("/Users/runner/work/TablePro/TablePro/Some Dir/Broken.swift:4",
             "Cannot convert value of type 'String' to specified type 'Int'"),
            ("", "Linker command failed with exit code 1"),
        ])

    def test_no_build_results(self):
        self.assertEqual(list(parser.build_errors(None)), [])


class ErrorsCommandTests(unittest.TestCase):
    def setUp(self):
        self.original = parser.xcresulttool
        parser.xcresulttool = lambda bundle, *arguments: BROKEN_BUILD if arguments == ("build-results",) else None

    def tearDown(self):
        parser.xcresulttool = self.original

    def errors(self, *arguments):
        with redirect_stdout(io.StringIO()) as out:
            code = parser.main(["errors", *arguments])
        return code, out.getvalue().splitlines()

    def test_prints_file_name_line_and_message(self):
        self.assertEqual(self.errors("Build.xcresult"), (0, [
            "Broken.swift:4: Cannot convert value of type 'String' to specified type 'Int'",
            "Linker command failed with exit code 1",
        ]))

    def test_limit_stops_after_n_errors(self):
        self.assertEqual(self.errors("--limit", "1", "Build.xcresult"),
                         (0, ["Broken.swift:4: Cannot convert value of type 'String' to specified type 'Int'"]))

    def test_a_bad_limit_is_a_usage_error(self):
        with redirect_stderr(io.StringIO()):
            self.assertEqual(self.errors("--limit", "x", "Build.xcresult")[0], 2)


class XunitTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.root = Path(self.directory.name)

    def tearDown(self):
        self.directory.cleanup()

    def write(self, name, text):
        path = self.root / name
        path.write_text(text, encoding="utf-8")
        return path

    def test_labels_match_swift_test_filters(self):
        self.write("Core.xml", XCTEST_XUNIT)
        self.write("Core-swift-testing.xml", SWIFT_TESTING_XUNIT)
        cases = by_label(parser.xunit_cases(self.root / "Core.xml"))
        self.assertEqual(sorted(cases), [
            "OtherTests.OnlySkippedTests/testSkipped",
            "ProbeTests.ClassicTests/testFails",
            "ProbeTests.ClassicTests/testPasses",
            "ProbeTests.Outer/Inner/nestedFails()",
            "ProbeTests.Outer/disabled()",
            "ProbeTests.freeFunction()",
        ])
        self.assertEqual(cases["ProbeTests.Outer/Inner/nestedFails()"].result, "Failed")
        self.assertEqual(cases["ProbeTests.Outer/disabled()"].result, "Skipped")
        self.assertEqual(cases["ProbeTests.freeFunction()"].target, "ProbeTests")
        self.assertEqual(cases["ProbeTests.ClassicTests/testFails"].seconds, 0.5)

    def test_the_swift_testing_file_alone_is_read(self):
        self.write("Core-swift-testing.xml", SWIFT_TESTING_XUNIT)
        self.assertEqual(len(parser.xunit_cases(self.root / "Core.xml")), 3)

    def test_a_truncated_file_counts_nothing(self):
        self.write("Core.xml", XCTEST_XUNIT[:120])
        with redirect_stderr(io.StringIO()) as errors:
            self.assertEqual(parser.xunit_cases(self.root / "Core.xml"), [])
        self.assertIn("cannot read", errors.getvalue())


class TallyTests(unittest.TestCase):
    def test_counts_targets_retries_and_failures(self):
        cases = [case for _, found in parser.bundle_cases(MIXED) for case in found]
        filters = [("ClassicTests", parser.re.compile(r"^ProbeTests/ClassicTests(\(\))?(/|$)")),
                   ("Nope", parser.re.compile(r"^ProbeTests/Nope(\(\))?(/|$)"))]
        self.assertEqual(parser.tally(cases, filters), [
            "tests: 8 executed, 4 passed, 3 failed, 2 skipped, 1 expected failures",
            "targets: ProbeTests 8 (1 skipped), OnlySkippedTests 0 (1 skipped)",
            "ran nothing: Nope",
            "passed only on retry, a flake to fix:",
            "  ProbeTests/ClassicTests/testFlaky()",
            "  ProbeTests/Outer/parameterized(value:)",
            "failures:",
            "  ProbeTests/ClassicTests/testFails(): XCTAssertEqual failed: (\"4\") is not equal to (\"5\")",
            "  ProbeTests/Outer/Inner/nestedFails(): Expectation failed: double(3) == 7",
            "8 3 1 0",
        ])

    def test_a_runner_failure_is_not_an_executed_test(self):
        cases = [case for _, found in parser.bundle_cases(RUNNER_FAILED) for case in found]
        self.assertEqual(parser.tally(cases, []), [
            "tests: 0 executed, 0 passed, 0 failed, 0 skipped, 1 runner failures",
            "failures:",
            "  TableProMobileTests/TableProMobile encountered an error: "
            "Failed to prepare device 'iPhone 18 Pro' for impending launch.",
            "0 0 0 1",
        ])

    def test_filters_file(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "run.filters"
            path.write_text("Suite\t^T/Suite(\\(\\))?(/|$)\tT/Suite\n\nbroken\t[unclosed\n", encoding="utf-8")
            filters = parser.read_filters(str(path))
        self.assertEqual([label for label, _ in filters], ["Suite", "broken"])
        self.assertTrue(filters[0][1].search("T/Suite/case()"))
        self.assertFalse(filters[0][1].search("T/SuiteTwo/case()"))
        self.assertTrue(filters[1][1].search("x[unclosed"))

    def test_command_line(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "Core-swift-testing.xml").write_text(SWIFT_TESTING_XUNIT, encoding="utf-8")
            (root / "run.filters").write_text("Outer\t^ProbeTests\\.Outer(\\(\\))?(/|$)\n", encoding="utf-8")
            with redirect_stdout(io.StringIO()) as out:
                code = parser.main(["tally", "--filters", str(root / "run.filters"), str(root / "Core.xml")])
        self.assertEqual(code, 0)
        self.assertEqual(out.getvalue().splitlines()[-1], "2 1 0 0")


class SummaryTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.root = Path(self.directory.name)
        self.bundles = {}
        self.original = parser.xcresulttool
        parser.xcresulttool = lambda bundle, *arguments: self.bundles.get(Path(bundle).stem, {}).get(arguments)

    def tearDown(self):
        parser.xcresulttool = self.original
        self.directory.cleanup()

    def bundle(self, name, tests=None, build=None):
        (self.root / f"{name}.xcresult").mkdir()
        self.bundles[name] = {("test-results", "tests"): tests, ("build-results",): build}
        return str(self.root / f"{name}.xcresult")

    def summarize(self, *arguments):
        summary, annotations = io.StringIO(), io.StringIO()
        code = parser.summarize(arguments, summary, annotations)
        return code, summary.getvalue(), annotations.getvalue()

    def test_build_errors_point_at_the_real_line(self):
        code, summary, _ = self.summarize(self.bundle("Build", build=BROKEN_BUILD))
        self.assertEqual(code, 0)
        self.assertIn("### Build: 2 build errors", summary)
        self.assertIn("`/Users/runner/work/TablePro/TablePro/Some Dir/Broken.swift:4` Cannot convert", summary)
        self.assertNotIn("Testing cancelled", summary)

    def test_a_runner_failure_is_listed_apart_and_ran_no_test(self):
        code, summary, annotations = self.summarize(self.bundle("iOS", RUNNER_FAILED, RUNNER_BUILD))
        self.assertEqual(code, 1)
        self.assertIn("### iOS: TableProMobileTests executed no test", summary)
        self.assertIn("### iOS: 1 runner failure outside any test", summary)
        self.assertIn("- `TableProMobileTests/TableProMobile encountered an error`: Failed to prepare device", summary)
        self.assertNotIn("build error", summary)
        self.assertNotIn("not passing", summary)
        self.assertIn("::error::iOS: TableProMobileTests executed no test", annotations)

    def test_counts_failures_and_retries(self):
        code, summary, annotations = self.summarize(self.bundle("Unit", MIXED))
        self.assertEqual(code, 1)
        self.assertIn("### Unit: OnlySkippedTests executed no test", summary)
        self.assertIn("### Unit: 8 cases, 0.3 min, 3 not passing", summary)
        self.assertIn("- failed: `ProbeTests/ClassicTests/testOdd()`", summary)
        self.assertIn("| nestedPasses() | ProbeTests/Outer/Inner | 12.0 |", summary)
        self.assertIn("::warning title=Passed only on retry::ProbeTests/ClassicTests/testFlaky()", annotations)

    def test_xunit_and_missing_inputs(self):
        (self.root / "Core.xml").write_text(XCTEST_XUNIT, encoding="utf-8")
        (self.root / "Empty.xml").write_text("<testsuites/>", encoding="utf-8")
        code, summary, annotations = self.summarize(
            str(self.root / "Core.xml"), str(self.root / "Empty.xml"), str(self.root / "Oracle.xml"),
            str(self.root / "UI.xcresult"))
        self.assertEqual(code, 1)
        self.assertIn("### Core: 3 cases, 0.0 min, 1 not passing", summary)
        self.assertIn("| testFails | ProbeTests.ClassicTests | 0.5 |", summary)
        self.assertIn("### Empty: swift test executed no test", summary)
        self.assertNotIn("Oracle", summary)
        self.assertEqual(annotations, "::error::Empty: swift test executed no test\n")


if __name__ == "__main__":
    unittest.main()
