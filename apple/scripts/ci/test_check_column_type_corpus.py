#!/usr/bin/env python3
"""Fixture tests for check-column-type-corpus.py."""

import importlib.util
import json
import tempfile
import unittest
from pathlib import Path

SPEC = importlib.util.spec_from_file_location(
    "check_column_type_corpus", Path(__file__).with_name("check-column-type-corpus.py")
)
check = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(check)

DICTIONARY = """final class ExamplePlugin: NSObject, DriverPlugin {
    static let databaseGroupingStrategy: GroupingStrategy = .bySchema
    static let columnTypesByCategory: [String: [String]] = [
        "Integer": ["INT", "BIGINT"],
        "String": ["VARCHAR", "TEXT"],
        "Binary": []
    ]
    static let systemSchemaNames = ["pg_catalog"]
}
"""

CATEGORIES = """internal enum ExampleTypeCatalog {
    static let categories: [(name: String, types: [String])] = [
        ("Integer", ["NUMBER"]),
        ("Date", [
            "DATE", "TIMESTAMP WITH TIME ZONE"
        ])
    ]

    static let columnTypesByCategory: [String: [String]] = Dictionary(
        uniqueKeysWithValues: categories.map { ($0.name, $0.types) }
    )
}
"""

COMPUTED = """final class ExamplePlugin: NSObject, DriverPlugin {
    static let columnTypesByCategory = ExampleMetadata.columnTypesByCategory
}
"""


def column(declaration, **extra):
    return {"type": declaration, "values": [], "edit": {"text": "1", "cell": "1"}, **extra}


class CheckColumnTypeCorpusTests(unittest.TestCase):
    def problems(self, source, columns, **extra):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "Plugins").mkdir()
            (root / "Plugins" / "Example.swift").write_text(source, encoding="utf-8")
            corpus = root / "example.json"
            corpus.write_text(
                json.dumps({"typeList": "Plugins/Example.swift", "columns": columns, **extra}), encoding="utf-8"
            )
            return check.problems_in(corpus, root)

    def test_a_covered_dictionary_passes(self):
        columns = [column("INT"), column("BIGINT"), column("VARCHAR(20)"), column("TEXT")]
        self.assertEqual(self.problems(DICTIONARY, columns), [])

    def test_a_listed_type_without_a_column_fails(self):
        problems = self.problems(DICTIONARY, [column("INT"), column("VARCHAR(20)"), column("TEXT")])
        self.assertEqual(problems, ["Plugins/Example.swift lists BIGINT with no corpus column"])

    def test_covers_names_the_listed_type(self):
        columns = [column("INTEGER[]", covers=["INT", "BIGINT"]), column("VARCHAR"), column("TEXT")]
        self.assertEqual(self.problems(DICTIONARY, columns), [])

    def test_a_type_no_column_can_have_is_covered_by_its_reason(self):
        columns = [column("INT"), column("VARCHAR"), column("TEXT")]
        reasons = {"BIGINT": "not a column type"}
        self.assertEqual(self.problems(DICTIONARY, columns, notColumnTypes=reasons), [])

    def test_a_list_built_from_categories_is_read(self):
        problems = self.problems(CATEGORIES, [column("NUMBER(10)"), column("DATE")])
        self.assertEqual(problems, ["Plugins/Example.swift lists TIMESTAMP WITH TIME ZONE with no corpus column"])

    def test_a_list_it_cannot_read_fails(self):
        with self.assertRaises(check.Unreadable):
            self.problems(COMPUTED, [column("INT")])

    def test_a_column_needs_an_edit_or_a_reason(self):
        columns = [column("INT"), column("BIGINT"), column("VARCHAR"), {"type": "TEXT", "values": []}]
        self.assertEqual(self.problems(DICTIONARY, columns), ["TEXT: no edit and no skip reason for it"])

    def test_an_unknown_step_fails(self):
        known = {"grid": {"defect": "x", "matches": "x"}}
        columns = [column("INT", known=known), column("BIGINT"), column("VARCHAR"), column("TEXT")]
        self.assertEqual(self.problems(DICTIONARY, columns), ["INT: known names 'grid', not a step"])

    def test_a_known_issue_names_the_failure_it_stands_for(self):
        columns = [column("INT", known={"browse": "reads wrong"}), column("BIGINT"), column("VARCHAR"), column("TEXT")]
        self.assertEqual(
            self.problems(DICTIONARY, columns), ["INT: known 'browse' needs a defect and the failure it matches"]
        )


if __name__ == "__main__":
    unittest.main()
