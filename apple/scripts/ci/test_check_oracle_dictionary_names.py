#!/usr/bin/env python3
"""Fixture tests for check-oracle-dictionary-names.py."""

import contextlib
import importlib.util
import io
import tempfile
import unittest
from pathlib import Path

SPEC = importlib.util.spec_from_file_location(
    "check_oracle_dictionary_names", Path(__file__).with_name("check-oracle-dictionary-names.py")
)
check = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(check)

# The Actual Plan probe as it shipped in 0.83.0.
REPORTED = '''public enum OracleExplainPlan {
    public static let actualPlanProbe = """
        SELECT p.VALUE
        FROM V$PARAMETER p
        WHERE p.NAME = 'statistics_level'
        AND EXISTS (SELECT 1 FROM V$SESSION s WHERE s.SID = SYS_CONTEXT('USERENV', 'SID'))
        """
}
'''

QUALIFIED = '''enum Queries {
    static let probe = """
        SELECT p.VALUE FROM \\(OracleDictionary.performanceView("V$PARAMETER")) p
        WHERE EXISTS (SELECT 1 FROM SYS.V_$SESSION s)
        """
    static let users = "SELECT USERNAME FROM \\(OracleDictionary.view("DBA_USERS"))"
    static let ping = "SELECT 1 FROM SYS.DUAL"
    static let column = "SELECT c.USER_GENERATED FROM SYS.ALL_TAB_COLS c"
}
'''

NOT_SQL = '''// The probe reads V$SESSION and ALL_TABLES.
/* DBA_USERS needs a grant. */
enum Words {
    static let keywords = ["ROWNUM", "DUAL", "SYSDATE"]
    static var message: String {
        String(localized: "Ask for SELECT on V$SESSION, or for SELECT_CATALOG_ROLE.")
    }
}
'''

# The Estimated Plan statements as they shipped in 0.83.0.
REPORTED_ESTIMATED = '''public enum OracleExplainPlan {
    static func explain(_ id: String) -> String {
        "EXPLAIN PLAN SET STATEMENT_ID = '\\(id)' FOR \\(statement)"
    }
    static func delete(_ id: String) -> String {
        "DELETE FROM PLAN_TABLE WHERE STATEMENT_ID = '\\(id)'"
    }
    static let qualified = "EXPLAIN PLAN SET STATEMENT_ID = 'X' INTO SYS.PLAN_TABLE$ FOR SELECT 1 FROM SYS.DUAL"
}
'''

BARE_IN_INTERPOLATION = '''enum Queries {
    static let rows = """
        SELECT \\(columns.joined(separator: ", ")) FROM ALL_TABLES
        """
    static let nested = "SELECT \\(name("x")) FROM \\(source ?? "DUAL")"
}
'''


class CheckOracleDictionaryNamesTests(unittest.TestCase):
    def violations(self, source):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "Queries.swift"
            path.write_text(source, encoding="utf-8")
            return check.violations(path)

    def test_reported_probe_fails(self):
        self.assertEqual(self.violations(REPORTED), [(4, "V$PARAMETER"), (6, "V$SESSION")])

    def test_reported_estimated_plan_fails(self):
        self.assertEqual(self.violations(REPORTED_ESTIMATED), [(3, "PLAN_TABLE"), (6, "PLAN_TABLE")])

    def test_owner_qualified_names_pass(self):
        self.assertEqual(self.violations(QUALIFIED), [])

    def test_comments_keyword_lists_and_localized_messages_pass(self):
        self.assertEqual(self.violations(NOT_SQL), [])

    def test_text_around_and_inside_an_interpolation_is_checked(self):
        self.assertEqual(self.violations(BARE_IN_INTERPOLATION), [(3, "ALL_TABLES"), (5, "DUAL")])

    def test_the_owner_file_is_skipped_and_others_fail_the_run(self):
        with tempfile.TemporaryDirectory() as directory:
            Path(directory, "OracleDictionary.swift").write_text('let dual = "SELECT 1 FROM DUAL"', encoding="utf-8")
            Path(directory, "Explain.swift").write_text(REPORTED, encoding="utf-8")
            output = io.StringIO()
            with contextlib.redirect_stdout(output):
                status = check.main([directory])
        self.assertEqual(status, 1)
        self.assertNotIn("OracleDictionary.swift", output.getvalue())
        self.assertIn("Explain.swift:4: V$PARAMETER", output.getvalue())

    def test_the_tree_passes(self):
        output = io.StringIO()
        with contextlib.redirect_stdout(output):
            status = check.main([])
        self.assertEqual(status, 0, output.getvalue())


if __name__ == "__main__":
    unittest.main()
