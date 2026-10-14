#!/usr/bin/env python3
"""Fixture tests for check-string-catalogs.py."""

from __future__ import annotations

import importlib.util
import unittest
from pathlib import Path

SPEC = importlib.util.spec_from_file_location("check", Path(__file__).with_name("check-string-catalogs.py"))
check = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(check)


def catalog(key: str, value: str, source_subs: dict | None = None, value_subs: dict | None = None) -> dict:
    def localization(text: str, subs: dict | None) -> dict:
        entry = {"stringUnit": {"state": "translated", "value": text}}
        if subs:
            entry["substitutions"] = {f"s{i}": {"argNum": i, "formatSpecifier": f} for i, f in subs.items()}
        return entry

    return {
        "sourceLanguage": "en",
        "strings": {key: {"localizations": {"en": localization(key, source_subs), "tr": localization(value, value_subs)}}},
    }


class SpecifierTests(unittest.TestCase):
    def test_plain_length_width_and_literal_percent(self) -> None:
        self.assertEqual(check.specifiers("%@ rows"), [(None, "@")])
        self.assertEqual([t for _, t in check.specifiers("%lld of %d")], ["lld", "d"])
        self.assertEqual(check.specifiers("%-8.2f"), [(None, "f")])
        self.assertEqual(check.specifiers("100%% done"), [])
        self.assertEqual(check.specifiers("%2$@ on %1$@"), [(2, "@"), (1, "@")])

    def test_substitution_placeholder_is_not_a_specifier(self) -> None:
        self.assertEqual(check.specifiers("with %#@points@"), [])


class RuleTests(unittest.TestCase):
    def assertFlags(self, payload: dict, fragment: str | None) -> None:
        found = check.offenders("TablePro", payload)
        if fragment is None:
            self.assertEqual(found, [])
        else:
            self.assertTrue(any(fragment in line for line in found), found)

    def test_reordered_positional_translation_passes(self) -> None:
        self.assertFlags(catalog("%1$@ on %2$@", "%2$@ üzerinde %1$@"), None)

    def test_dropped_retyped_and_mixed_arguments_are_caught(self) -> None:
        self.assertFlags(catalog("%1$@ on %2$@", "%1$@"), "consumes")
        self.assertFlags(catalog("%lld rows", "%@ satır"), "argument 1")
        self.assertFlags(catalog("%1$@ on %2$@", "%1$@ üzerinde %@"), "mixes")

    def test_plural_substitution_counts_as_its_argument(self) -> None:
        source = "%1$@ chart of %2$@ by %3$@ with %#@points@"
        self.assertFlags(catalog(source, "%3$@ %2$@ %4$d %1$@", {4: "d"}), None)
        self.assertFlags(catalog("%1$@ with %#@points@", "%1$@", {2: "d"}), "consumes")
        self.assertFlags(catalog("%1$@ with %#@points@", "%1$@ với %2$@", {2: "d"}), "argument 2")

    def test_markup_tokens_ellipsis_and_sentence_marks(self) -> None:
        self.assertFlags(catalog("Rows", "^[satır](inflect: true)"), "inflection")
        self.assertFlags(catalog("Add a row to ${table}", "Bir satır ekle"), "token")
        self.assertFlags(catalog("Open…", "Aç"), "ellipsis")
        self.assertFlags(catalog("Done.", "Bitti"), "closing .")
        self.assertFlags(catalog("Done.", "已完成。"), None)
        self.assertFlags(catalog("New Table...", "Yeni Tablo…"), "three periods")


if __name__ == "__main__":
    unittest.main()
