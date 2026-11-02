#!/usr/bin/env python3
"""Fixture tests for check-postgresql-qualified-calls.py."""

import contextlib
import importlib.util
import io
import tempfile
import unittest
from pathlib import Path

SPEC = importlib.util.spec_from_file_location(
    "check_postgresql_qualified_calls", Path(__file__).with_name("check-postgresql-qualified-calls.py")
)
check = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(check)

# The CockroachDB and Redshift statements as they shipped in 0.83.1.
REPORTED = '''final class Driver {
    func probe() {
        _ = "SELECT version()"
        _ = """
            SELECT COUNT(DISTINCT "table") AS table_count
            FROM svv_table_info
            WHERE database = current_database()
            """
    }
}
'''

QUALIFIED = '''enum Queries {
    static let size = "SELECT pg_catalog.pg_database_size($1::pg_catalog.name)"
    static let keys = """
        SELECT a.attname, EXTRACT(EPOCH FROM pg_catalog.now()), CAST(a.attnum AS pg_catalog.int4)
        FROM pg_catalog.pg_constraint con
        CROSS JOIN LATERAL pg_catalog.unnest(con.conkey) WITH ORDINALITY AS k(attnum, position)
        WHERE con.contype IN ('f', 'p') AND COALESCE(con.conname, '') OPERATOR(pg_catalog.<>) ''
          AND NOT EXISTS (SELECT 1 FROM pg_catalog.pg_index i WHERE i.indrelid = con.conrelid)
        """
    static func call(_ routine: String, _ arguments: String) -> String {
        "SELECT \\(routine)(\\(arguments)), \\"ext\\".pldbg_get_source(1)"
    }
}
'''

NOT_SQL = '''// SELECT count(*) in a comment.
/* version() in a block comment. */
enum Words {
    static var message: String {
        String(localized: "Ask for count(*) on the table.")
    }
    func log() {
        logger.warning("Left out invalid index(es) on the table")
    }
    static let template = """
        -- NEW.updated_at := now();
        SELECT 'count(x) in a literal'
        """
}
'''

# The Table Health foreign key test as it shipped in 0.83.1.
REPORTED_OPERATORS = '''enum Health {
    static let unindexed = """
        SELECT 1 FROM pg_catalog.pg_index i
        WHERE pg_catalog.array_length(fk.conkey, 1)
              <= COALESCE((pg_catalog.row_to_json(i) ->> 'indnkeyatts')::pg_catalog.int4, i.indnatts)
          AND (i.indkey::pg_catalog.int2[])[0:pg_catalog.array_length(fk.conkey, 1) - 1] @> fk.conkey
        """
}
'''

QUALIFIED_OPERATORS = '''enum Health {
    static let unindexed = """
        SELECT 1 FROM pg_catalog.pg_index i
        WHERE (pg_catalog.row_to_json(i) OPERATOR(pg_catalog.->>) 'indnkeyatts'::pg_catalog.text) IS NULL
          AND i.indkey::pg_catalog.int2[] OPERATOR(pg_catalog.@>) fk.conkey AND -1 <> 1 AND a <= b AND c >= d
        """
}
'''

# Hidden behind a comment marker inside a string, or quoted.
HIDDEN = '''enum Queries {
    static let marker = "SELECT '--', count(*) FROM pg_catalog.pg_class"
    static let pattern = "SELECT 1 WHERE a LIKE '%/*%' AND lower(z) = 'q' AND w = '*/'"
    static let quoted = "SELECT \\"count\\"(x) FROM pg_catalog.pg_class"
    static let jsonb = "SELECT d #- '{a}' FROM pg_catalog.pg_class"
}
'''

# Comma forms and quoted grammar words are ordinary lookups; quotes inside names, E-strings and dollar bodies are not
# strings; a line comment ends at an escaped newline.
LOOKUPS = '''enum Queries {
    static let comma = "SELECT substring(c.relname, 1, 3), overlay(c.relname, 'x', 1, 1) FROM pg_catalog.pg_class c"
    static let quotedWord = "SELECT \\"greatest\\"(a, b) FROM pg_catalog.pg_class"
    static let name = "SELECT \\"it's\\", count(*) FROM pg_catalog.pg_class WHERE x = 'y'"
    static let escaped = "SELECT E'a\\\\'b', count(*) FROM pg_catalog.pg_class WHERE x = 'y'"
    static let dollar = "SELECT $$ it's $$, count(*) FROM pg_catalog.pg_class WHERE x = 'y'"
    static let comment = "SELECT 1 -- note\\nFROM pg_catalog.pg_class WHERE lower(x) = 'y'"
    static let bits = "SELECT varbit(x, 3, true), y::varbit(5) FROM pg_catalog.pg_class"
    static let slice = "SELECT (i.indkey::pg_catalog.int2[])[0:array_length(k, 1) - 1] FROM pg_catalog.pg_index i"
    static let block = "DO $$ BEGIN PERFORM lower(x); END $$"
}
'''

GRAMMAR = '''enum Queries {
    static let now = "SELECT CURRENT_TIMESTAMP(3), LOCALTIMESTAMP(0)"
    static let bound = "CREATE TABLE p PARTITION OF t FOR VALUES FROM (1) TO (10)"
    static let insert = "INSERT INTO \\"orders\\" (id) VALUES (1)"
    static let keywordForms = "SELECT substring(a FROM 1 FOR 2), overlay(a PLACING 'x' FROM 1) FROM pg_catalog.pg_class"
}
'''

BARE_IN_INTERPOLATION = '''enum Queries {
    static let rows = "SELECT \\(columns.map { "lower(\\($0))" }.joined()) FROM pg_catalog.pg_class"
}
'''


class CheckPostgreSQLQualifiedCallsTests(unittest.TestCase):
    def violations(self, source):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "Queries.swift"
            path.write_text(source, encoding="utf-8")
            return check.violations(path)

    def test_reported_statements_fail(self):
        self.assertEqual(
            self.violations(REPORTED), [(3, "version"), (5, "COUNT"), (7, "current_database")]
        )

    def test_qualified_calls_grammar_and_alias_columns_pass(self):
        self.assertEqual(self.violations(QUALIFIED), [])

    def test_comments_logged_and_localized_text_and_sql_literals_pass(self):
        self.assertEqual(self.violations(NOT_SQL), [])

    def test_reported_array_and_json_operators_fail(self):
        self.assertEqual(self.violations(REPORTED_OPERATORS), [(5, "->>"), (6, "@>")])

    def test_operators_named_through_pg_catalog_pass(self):
        self.assertEqual(self.violations(QUALIFIED_OPERATORS), [])

    def test_calls_behind_a_comment_marker_in_a_string_or_quoted_fail(self):
        self.assertEqual(
            self.violations(HIDDEN), [(2, "count"), (3, "lower"), (4, '"count"'), (5, "#-")]
        )

    def test_lookups_behind_names_escapes_and_dollar_bodies_fail(self):
        self.assertEqual(
            self.violations(LOOKUPS),
            [
                (2, "overlay"), (2, "substring"), (3, '"greatest"'), (4, "count"), (5, "count"), (6, "count"),
                (7, "lower"), (8, "varbit"), (9, "array_length"), (10, "lower"),
            ],
        )

    def test_value_functions_bounds_and_quoted_tables_pass(self):
        self.assertEqual(self.violations(GRAMMAR), [])

    def test_a_literal_inside_an_interpolation_is_checked(self):
        self.assertEqual(self.violations(BARE_IN_INTERPOLATION), [(2, "lower")])

    def test_a_violation_fails_the_run(self):
        with tempfile.TemporaryDirectory() as directory:
            Path(directory, "Driver.swift").write_text(REPORTED, encoding="utf-8")
            output = io.StringIO()
            with contextlib.redirect_stdout(output):
                status = check.main([directory])
        self.assertEqual(status, 1)
        self.assertIn("Driver.swift:3: version(...) names no schema", output.getvalue())

    def test_the_tree_passes(self):
        output = io.StringIO()
        with contextlib.redirect_stdout(output):
            status = check.main([])
        self.assertEqual(status, 0, output.getvalue())


if __name__ == "__main__":
    unittest.main()
