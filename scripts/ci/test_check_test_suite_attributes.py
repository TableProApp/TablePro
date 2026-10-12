#!/usr/bin/env python3
"""Fixture tests for check-test-suite-attributes.py."""

from __future__ import annotations

import importlib.util
import io
import shutil
import sys
import tempfile
import unittest
from contextlib import redirect_stdout
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location(
    "check_test_suite_attributes", Path(__file__).with_name("check-test-suite-attributes.py")
)
check = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(check)

REJECTED = {
    "DisplayName.swift": ('@Suite("Display name")\nstruct DisplayNameTests {}\n', 1),
    "SameLineAsActor.swift": ('import Testing\n\n@MainActor @Suite("Display name")\nstruct ActorTests {}\n', 3),
    "SameLineAsType.swift": ('@Suite("Display name") struct SameLineTests {}\n', 1),
    "Wrapped.swift": ('@Suite(\n    "Display name"\n)\nstruct WrappedTests {}\n', 1),
    "Bare.swift": ("@Suite\nstruct BareTests {}\n", 1),
    "Empty.swift": ("@Suite()\nstruct EmptyTests {}\n", 1),
    "RawString.swift": ('@Suite(#"A "quoted" name"#)\nstruct RawStringTests {}\n', 1),
    "EscapedQuote.swift": ('@Suite("A \\"quoted\\" name")\nstruct EscapedQuoteTests {}\n', 1),
    "Qualified.swift": ('@Testing.Suite("Display name")\nstruct QualifiedTests {}\n', 1),
    "CommentInArguments.swift": ('@Suite("Display name" /* , .serialized */)\nstruct CommentTests {}\n', 1),
    "Conditional.swift": ('#if DEBUG\n    @Suite("Display name")\n    struct ConditionalTests {}\n#endif\n', 2),
    "AfterMultilineString.swift": (
        'let sql = """\n    }\n    """\n\n@Suite("Display name")\nstruct AfterStringTests {}\n',
        5,
    ),
}

ACCEPTED = {
    "Serialized.swift": '@Suite("Display name", .serialized)\nstruct SerializedTests {}\n',
    "TraitOnly.swift": "@Suite(.serialized)\nstruct TraitOnlyTests {}\n",
    "WrappedTraits.swift": (
        '@Suite(\n    "Display name",\n    .serialized,\n    .enabled(if: Server.isConfigured)\n)\n'
        "struct WrappedTraitsTests {}\n"
    ),
    "ConditionWithString.swift": (
        '@Suite("Display name", .enabled(if: ProcessInfo.processInfo.environment["CI"] == nil))\n'
        "struct ConditionTests {}\n"
    ),
    "Nested.swift": 'struct OuterTests {\n    @Suite("Nested")\n    struct InnerTests {}\n}\n',
    "NestedInExtension.swift": 'extension OuterTests {\n    @MainActor @Suite("Nested")\n    struct MoreTests {}\n}\n',
    "BracesInStrings.swift": (
        "struct BraceTests {\n"
        '    let brace = "}"\n'
        '    let raw = #"}"}"#\n'
        '    let interpolated = "\\(["}": "}"].count) }"\n'
        '    let block = """\n        }\n        """\n'
        '    @Suite("Nested")\n'
        "    struct InnerTests {}\n"
        "}\n"
    ),
    "Comments.swift": (
        '// @Suite("Commented out")\n'
        '/* @Suite("Commented out") /* nested } */ @Suite("Still commented out") */\n'
        "struct CommentedTests {}\n"
    ),
    "Strings.swift": 'let text = "@Suite(\\"In a string\\")"\nlet block = """\n@Suite("In a string")\n"""\n',
    "OtherAttribute.swift": "@SuiteHelper\nstruct HelperTests {}\n",
    "TestDisplayName.swift": 'struct NamedTests {\n    @Test("A display name")\n    func named() {}\n}\n',
}


class CheckTestSuiteAttributesTests(unittest.TestCase):
    def setUp(self) -> None:
        self.root = Path(tempfile.mkdtemp())

    def tearDown(self) -> None:
        shutil.rmtree(self.root)

    def write(self, directory: str, name: str, text: str) -> None:
        folder = self.root / directory
        folder.mkdir(parents=True, exist_ok=True)
        (folder / name).write_text(text, encoding="utf-8")

    def test_every_suite_without_a_trait_is_reported_on_its_own_line(self) -> None:
        for name, (text, _) in REJECTED.items():
            self.write("TableProTests/Rejected", name, text)
        found = {(path, line) for path, line, _ in check.offenders(self.root)}
        expected = {(f"TableProTests/Rejected/{name}", line) for name, (_, line) in REJECTED.items()}
        self.assertEqual(found, expected)

    def test_suites_with_traits_nested_suites_and_non_code_are_not_reported(self) -> None:
        for name, text in ACCEPTED.items():
            self.write("TableProTests/Accepted", name, text)
        self.assertEqual(check.offenders(self.root), [])

    def test_the_report_quotes_the_attribute_on_one_line(self) -> None:
        self.write("TableProTests", "Wrapped.swift", REJECTED["Wrapped.swift"][0])
        self.write("TableProTests", "SameLineAsActor.swift", REJECTED["SameLineAsActor.swift"][0])
        self.assertEqual(
            check.offenders(self.root),
            [
                ("TableProTests/SameLineAsActor.swift", 3, '@Suite("Display name")'),
                ("TableProTests/Wrapped.swift", 1, '@Suite( "Display name" )'),
            ],
        )

    def test_only_the_app_test_target_is_scanned(self) -> None:
        self.write("TableProTests", "App.swift", REJECTED["DisplayName.swift"][0])
        self.write("Packages/Core/Tests/CoreTests", "Package.swift", REJECTED["DisplayName.swift"][0])
        self.write("TableProUITests", "UI.swift", REJECTED["DisplayName.swift"][0])
        found = [path for path, _, _ in check.offenders(self.root)]
        self.assertEqual(found, ["TableProTests/App.swift"])

    def test_a_failure_names_the_site_the_cause_and_the_remedy(self) -> None:
        self.write("TableProTests", "App.swift", REJECTED["DisplayName.swift"][0])
        output = io.StringIO()
        with redirect_stdout(output):
            self.assertEqual(check.main_for(self.root), 1)
        text = output.getvalue()
        self.assertIn('TableProTests/App.swift:1: @Suite("Display name")', text)
        self.assertIn("quadratically", text)
        self.assertIn("Leave the type unannotated", text)

    def test_a_clean_tree_passes_silently(self) -> None:
        self.write("TableProTests", "App.swift", ACCEPTED["Serialized.swift"])
        output = io.StringIO()
        with redirect_stdout(output):
            self.assertEqual(check.main_for(self.root), 0)
        self.assertEqual(output.getvalue(), "")

    def test_a_file_whose_braces_do_not_balance_fails_instead_of_passing(self) -> None:
        conditional_header = (
            "#if canImport(AppKit)\n"
            "extension Foo: NSObjectProtocol {\n"
            "#else\n"
            "extension Foo {\n"
            "#endif\n"
            "    func a() {}\n"
            "}\n\n"
            '@Suite("After the conditional header")\n'
            "struct AfterTests {}\n"
        )
        self.write("TableProTests", "ConditionalHeader.swift", conditional_header)
        self.write("TableProTests", "ExtraClose.swift", '}\n@Suite("After a stray brace")\nstruct StrayTests {}\n')
        _, unreadable = check.scan(self.root)
        self.assertEqual(
            unreadable,
            ["TableProTests/ConditionalHeader.swift", "TableProTests/ExtraClose.swift"],
        )
        output = io.StringIO()
        with redirect_stdout(output):
            self.assertEqual(check.main_for(self.root), 1)
        self.assertIn("TableProTests/ConditionalHeader.swift: braces do not balance", output.getvalue())

    def test_the_repository_itself_is_clean(self) -> None:
        self.assertEqual(check.scan(ROOT), ([], []))


if __name__ == "__main__":
    sys.exit(unittest.main())
