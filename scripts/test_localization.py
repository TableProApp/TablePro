#!/usr/bin/env python3
"""Fixture tests for localization.py."""

from __future__ import annotations

import importlib.util
import json
import os
import shutil
import tempfile
import unittest
from pathlib import Path

SPEC = importlib.util.spec_from_file_location("localization", Path(__file__).with_name("localization.py"))
localization = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(localization)


class SourceLiteralTests(unittest.TestCase):
    def test_single_line_literal_with_escaped_quote(self):
        source = 'let a = String(localized: "Drop \\"%@\\"?")\n'
        self.assertEqual(localization.source_literals(source), ['Drop \\"%@\\"?'])

    def test_call_wrapped_after_the_parenthesis(self):
        source = 'String(\n    localized: "Wrapped"\n)\n'
        self.assertEqual(localization.source_literals(source), ["Wrapped"])

    def test_multiline_literal_strips_the_closing_indent(self):
        source = 'String(\n    localized: """\n    First line\n      indented\n    """\n)\n'
        self.assertEqual(localization.source_literals(source), ["First line\n  indented"])

    def test_multiline_line_continuation_joins_without_a_newline(self):
        source = (
            "String(\n"
            '    localized: """\n'
            "    %d document(s) changed. \\\n"
            "    Check the data.\n"
            '    """\n'
            ")\n"
        )
        self.assertEqual(localization.source_literals(source), ["%d document(s) changed. Check the data."])

    def test_escaped_backslash_at_line_end_keeps_the_newline(self):
        source = 'String(localized: """\n    C:\\\\\n    next\n    """)\n'
        self.assertEqual(localization.source_literals(source), ["C:\\\\\nnext"])


class HiddenKeyTests(unittest.TestCase):
    def setUp(self):
        self.root = Path(tempfile.mkdtemp())

    def tearDown(self):
        shutil.rmtree(self.root)

    def write(self, relative: str, text: str) -> None:
        path = self.root / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text, encoding="utf8")

    def test_collects_plugin_and_package_keys_once(self):
        self.write("Plugins/A/Driver.swift", 'String(localized: "Shared")\nString(localized: "Plugin only")\n')
        self.write("Packages/Core/Sources/Error.swift", 'String(localized: "Shared")\nString(localized: "Tab\\there")\n')
        keys = localization.hidden_keys((self.root / "Plugins", self.root / "Packages"))
        self.assertEqual(keys, ["Shared", "Plugin only", "Tab\there"])

    def test_skips_tests_build_checkouts_and_interpolation(self):
        self.write("Plugins/A/Tests/DriverTests.swift", 'String(localized: "Test only")\n')
        self.write("Packages/Core/.build/checkouts/dep/Dep.swift", 'String(localized: "Third party")\n')
        self.write("Plugins/A/Driver.swift", 'String(localized: "Count \\(n)")\n')
        self.assertEqual(localization.hidden_keys((self.root / "Plugins", self.root / "Packages")), [])


class ManagementTests(unittest.TestCase):
    def test_a_key_is_managed_only_when_manual_without_a_symbol(self):
        self.assertTrue(localization.is_managed({"extractionState": "manual", "generatesSymbol": False}))
        self.assertFalse(localization.is_managed({"extractionState": "manual"}))
        self.assertFalse(localization.is_managed({}))
        self.assertFalse(localization.is_managed({"extractionState": "stale", "generatesSymbol": False}))

    def test_manage_adds_missing_keys_and_keeps_translations(self):
        unit = {"stringUnit": {"state": "translated", "value": "Bonjour"}}
        strings = {"Hello": {"localizations": {"fr": unit}}}
        pending = localization.unmanaged_keys(strings, ["Hello", "New"])
        self.assertEqual(pending, ["Hello", "New"])

        localization.manage(strings, pending)

        self.assertEqual(strings["Hello"]["localizations"]["fr"], unit)
        self.assertEqual(localization.unmanaged_keys(strings, ["Hello", "New"]), [])


@unittest.skipUnless(shutil.which("xcrun"), "writing a catalog uses Foundation through xcrun swift")
class WriteTests(unittest.TestCase):
    def test_writes_what_xcode_writes(self):
        catalog = {
            "version": "1.1",
            "strings": {
                "item 10": {"extractionState": "manual", "generatesSymbol": False},
                "Item 2": {},
                "a/b": {"localizations": {"fr": {"stringUnit": {"state": "translated", "value": "é"}}}},
            },
            "sourceLanguage": "en",
        }
        expected = (
            "{\n"
            '  "sourceLanguage" : "en",\n'
            '  "strings" : {\n'
            '    "a/b" : {\n'
            '      "localizations" : {\n'
            '        "fr" : {\n'
            '          "stringUnit" : {\n'
            '            "state" : "translated",\n'
            '            "value" : "é"\n'
            "          }\n"
            "        }\n"
            "      }\n"
            "    },\n"
            '    "Item 2" : {\n'
            "\n"
            "    },\n"
            '    "item 10" : {\n'
            '      "extractionState" : "manual",\n'
            '      "generatesSymbol" : false\n'
            "    }\n"
            "  },\n"
            '  "version" : "1.1"\n'
            "}"
        )
        with tempfile.TemporaryDirectory() as scratch:
            path = Path(scratch) / "Localizable.xcstrings"
            localization.write(path, catalog)
            self.assertEqual(path.read_text(encoding="utf8"), expected)
            self.assertEqual(json.loads(path.read_text(encoding="utf8")), catalog)


if __name__ == "__main__":
    os.chdir(Path(__file__).resolve().parents[1])
    unittest.main()
