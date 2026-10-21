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

    def test_ios_roots_are_the_linked_products_including_a_symlinked_one(self):
        self.write(
            "TableProMobile/project.yml",
            "targets:\n"
            "  App:\n"
            "    dependencies:\n"
            "      - target: Widget\n"
            "      - package: Core\n"
            "        products:\n"
            "          - Models\n"
            "          - Kit\n"
            "      - package: Oracle\n"
            "        product: OracleCore\n"
            "      - framework: ../Libs/ios/Lib.xcframework\n",
        )
        self.write("Packages/Core/Sources/Models/Model.swift", 'String(localized: "Model message")\n')
        self.write("Packages/Core/Sources/Unlinked/Mac.swift", 'String(localized: "Mac only")\n')
        self.write("Packages/Oracle/Sources/OracleCore/Error.swift", 'String(localized: "Oracle message")\n')
        self.write("Plugins/Kit/Error.swift", 'String(localized: "Kit message")\n')
        (self.root / "Packages/Core/Sources/Kit").symlink_to("../../../Plugins/Kit", target_is_directory=True)

        roots = localization.ios_hidden_source_roots(self.root / "TableProMobile/project.yml", self.root / "Packages")

        self.assertEqual(
            roots,
            (
                self.root / "Packages/Core/Sources/Models",
                self.root / "Packages/Core/Sources/Kit",
                self.root / "Packages/Oracle/Sources/OracleCore",
            ),
        )
        self.assertEqual(localization.hidden_keys(roots), ["Model message", "Kit message", "Oracle message"])


class ExtractedStringTests(unittest.TestCase):
    def setUp(self):
        self.root = Path(tempfile.mkdtemp())
        self.objects = self.root / "Intermediates.noindex"

    def tearDown(self):
        shutil.rmtree(self.root)

    def source(self, name: str, text: str) -> Path:
        path = self.root / "src" / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text, encoding="utf8")
        return path

    def stringsdata(self, target, source, entries, configuration="Debug-iphonesimulator", age=0, name=None, value=None):
        folder = self.objects / f"App.build/{configuration}/{target}.build/Objects-normal/arm64"
        path = folder / f"{name or source.stem}.stringsdata"
        path.parent.mkdir(parents=True, exist_ok=True)
        localizable = [
            {"comment": comment, "key": key, "location": {"startingColumn": 1, "startingLine": line}}
            for key, line, comment in entries
        ]
        if value is not None:
            localizable[0]["value"] = value
        plist = [{"comment": "", "key": "Plist", "location": {"startingColumn": 1, "startingLine": 1}}]
        tables = {"Localizable": localizable, "InfoPlist": plist}
        path.write_text(json.dumps({"source": str(source), "tables": tables, "version": 1}), encoding="utf8")
        stamp = 1_000_000 - age
        os.utime(path, (stamp, stamp))

    def test_reads_the_newest_build_of_the_catalog_targets(self):
        view = self.source("View.swift", 'Text("Shown")\n#Preview {\n    Text("Preview only")\n}\n')
        widget = self.source("Widget.swift", 'Text("Widget text", comment: "Home screen")\n')
        shortcuts = self.source("Shortcuts.swift", 'AppShortcut(shortTitle: "Run Query")\n')
        self.stringsdata("App", view, [("Shown", 1, ""), ("Preview only", 2, "")])
        self.stringsdata("App", view, [("Old", 1, "")], configuration="Release-iphoneos", age=60)
        self.stringsdata("App", self.root / "src/Gone.swift", [("Deleted file", 1, "")])
        self.stringsdata("App", shortcuts, [("Run Query", 1, "")])
        self.stringsdata("App", shortcuts, [("Open Connection", 1, "")], name="ExtractedAppShortcutsMetadata")
        self.stringsdata("AppTests", widget, [("Test", 1, "")])
        self.stringsdata("Widget", widget, [("Widget text", 1, "Home screen")])

        found = localization.extracted_strings(self.objects, ("App", "Widget"), "Localizable")

        self.assertEqual(
            localization.extracted_keys(found, "Localizable"),
            ["Open Connection", "Run Query", "Shown", "Widget text"],
        )

    @unittest.skipUnless(shutil.which("xcrun"), "adding a key runs xcstringstool")
    def test_adds_an_entry_as_xcode_writes_it(self):
        menu = self.source("Menu.swift", 'String(localized: "menu.edit", defaultValue: "Edit", comment: "Edit menu")\n')
        view = self.source("View.swift", 'Text("Shown")\n')
        self.stringsdata("App", menu, [("menu.edit", 1, "Edit menu")], value="Edit")
        self.stringsdata("App", view, [("Shown", 1, ""), ("Present", 1, "")])
        found = localization.extracted_strings(self.objects, ("App",), "Localizable")

        entries = localization.synced_entries(Path("Localizable.xcstrings"), found, ["menu.edit", "Shown"])

        self.assertEqual(
            entries,
            {
                "menu.edit": {
                    "comment": "Edit menu",
                    "extractionState": "extracted_with_value",
                    "localizations": {"en": {"stringUnit": {"state": "new", "value": "Edit"}}},
                },
                "Shown": {},
            },
        )


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
