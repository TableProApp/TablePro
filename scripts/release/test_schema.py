#!/usr/bin/env python3

import io
import tempfile
import unittest
from contextlib import redirect_stderr, redirect_stdout
from pathlib import Path

import schema

SNAPSHOT = Path(__file__).resolve().parents[2] / "CloudKit/production-schema.ckdb"
CONNECTION_FIELD = "        sshConfigJson        BYTES QUERYABLE SORTABLE,\n"
APP_SETTINGS_GRANT = '        GRANT CREATE TO "_icloud",\n'


def snapshot() -> str:
    return SNAPSHOT.read_text(encoding="utf-8")


def without(text: str, line: str) -> str:
    assert line in text, line
    return text.replace(line, "", 1)


def with_type(text: str, definition: str) -> str:
    return text.rstrip() + "\n\n" + definition + "\n"


def with_role(text: str) -> str:
    assert text.startswith("DEFINE SCHEMA\n")
    return text.replace("DEFINE SCHEMA\n", "DEFINE SCHEMA\n\n    CREATE ROLE Extra;\n", 1)


def gaps(snapshot_text: str, production_text: str):
    return schema.gaps(schema.parse(snapshot_text), schema.parse(production_text))


class ParseTests(unittest.TestCase):
    def test_reads_the_checked_in_snapshot(self):
        parsed = schema.parse(snapshot())
        self.assertIn("Connection", parsed.types)
        connection = parsed.types["Connection"]
        self.assertEqual(connection.fields["sshConfigJson"],
                         schema.Field("BYTES", frozenset({"QUERYABLE", "SORTABLE"})))
        self.assertEqual(connection.fields["___recordID"], schema.Field("REFERENCE", frozenset({"QUERYABLE"})))
        self.assertEqual(connection.fields["tagIds"], schema.Field("LIST<STRING>", frozenset()))
        self.assertIn(("CREATE", "_icloud"), connection.grants)

    def test_reads_every_form_of_the_grammar(self):
        parsed = schema.parse("""
            DEFINE SCHEMA
                // a comment
                CREATE ROLE Editor;
                RECORD TYPE "Note" (
                    title  STRING QUERYABLE SEARCHABLE SORTABLE,  -- another comment
                    secret ENCRYPTED STRING,
                    count  NUMBER PREFERRED AS INT64,
                    tags   LIST<ENCRYPTED STRING>,
                    "GRANT" STRING,
                    GRANT READ, WRITE TO "Editor",
                    GRANT CREATE TO "_icloud"
                );
        """)
        self.assertEqual(parsed.roles, {"Editor"})
        note = parsed.types["Note"]
        self.assertEqual(note.fields["title"].indexes, {"QUERYABLE", "SEARCHABLE", "SORTABLE"})
        self.assertEqual(note.fields["secret"].type, "ENCRYPTED STRING")
        self.assertEqual(note.fields["count"].type, "NUMBER PREFERRED AS INT64")
        self.assertEqual(note.fields["tags"].type, "LIST<ENCRYPTED STRING>")
        self.assertEqual(note.fields["GRANT"].type, "STRING")
        self.assertEqual(note.grants, {("READ", "Editor"), ("WRITE", "Editor"), ("CREATE", "_icloud")})

    def test_refuses_a_file_it_cannot_read(self):
        for text in ("", "RECORD TYPE A (b STRING);", "DEFINE SCHEMA RECORD TYPE A (b STRING",
                     "DEFINE SCHEMA RECORD TYPE A (b STRING FAST);",
                     "DEFINE SCHEMA RECORD TYPE A (b STRING, b INT64);",
                     "DEFINE SCHEMA RECORD TYPE A (GRANT DELETE TO x);",
                     "DEFINE SCHEMA DROP TYPE A;"):
            with self.subTest(text=text), self.assertRaises(schema.SchemaError):
                schema.parse(text)


class ProductionAheadPasses(unittest.TestCase):
    def test_identical(self):
        self.assertEqual(gaps(snapshot(), snapshot()), [])

    def test_a_field_only_production_has(self):
        self.assertEqual(gaps(without(snapshot(), CONNECTION_FIELD), snapshot()), [])

    def test_a_record_type_only_production_has(self):
        self.assertEqual(gaps(snapshot(), with_type(snapshot(), "RECORD TYPE Extra (name STRING);")), [])

    def test_an_index_only_production_has(self):
        lean = snapshot().replace(CONNECTION_FIELD, "        sshConfigJson        BYTES,\n")
        self.assertEqual(gaps(lean, snapshot()), [])

    def test_a_grant_only_production_has(self):
        self.assertEqual(gaps(without(snapshot(), APP_SETTINGS_GRANT), snapshot()), [])

    def test_a_role_only_production_has(self):
        self.assertEqual(gaps(snapshot(), with_role(snapshot())), [])


class SnapshotAheadFails(unittest.TestCase):
    def test_a_field_production_lacks(self):
        self.assertEqual(gaps(snapshot(), without(snapshot(), CONNECTION_FIELD)),
                         ["Connection.sshConfigJson: not in production"])

    def test_a_record_type_production_lacks(self):
        self.assertEqual(gaps(with_type(snapshot(), "RECORD TYPE Extra (name STRING);"), snapshot()),
                         ["record type Extra: not in production"])

    def test_a_field_type_that_differs(self):
        production = snapshot().replace(CONNECTION_FIELD, "        sshConfigJson        STRING QUERYABLE SORTABLE,\n")
        self.assertEqual(gaps(snapshot(), production),
                         ["Connection.sshConfigJson: BYTES in the snapshot, STRING in production"])

    def test_an_index_production_lacks(self):
        production = snapshot().replace(CONNECTION_FIELD, "        sshConfigJson        BYTES SORTABLE,\n")
        self.assertEqual(gaps(snapshot(), production), ["Connection.sshConfigJson: QUERYABLE not in production"])

    def test_a_grant_production_lacks(self):
        self.assertEqual(gaps(snapshot(), without(snapshot(), APP_SETTINGS_GRANT)),
                         ["AppSettings: GRANT CREATE TO _icloud not in production"])

    def test_a_role_production_lacks(self):
        self.assertEqual(gaps(with_role(snapshot()), snapshot()), ["role Extra: not in production"])


class CommandTests(unittest.TestCase):
    def run_covers(self, snapshot_text: str, production_text: str):
        with tempfile.TemporaryDirectory() as directory:
            snapshot_file = Path(directory) / "snapshot.ckdb"
            production_file = Path(directory) / "production.ckdb"
            snapshot_file.write_text(snapshot_text, encoding="utf-8")
            production_file.write_text(production_text, encoding="utf-8")
            out, err = io.StringIO(), io.StringIO()
            with redirect_stdout(out), redirect_stderr(err):
                code = schema.main(["covers", str(snapshot_file), str(production_file)])
        return code, out.getvalue(), err.getvalue()

    def test_passes_when_production_is_ahead(self):
        code, _, err = self.run_covers(without(snapshot(), CONNECTION_FIELD), snapshot())
        self.assertEqual((code, err), (0, ""))

    def test_fails_and_names_each_gap(self):
        code, _, err = self.run_covers(snapshot(), without(snapshot(), CONNECTION_FIELD))
        self.assertEqual((code, err), (1, "Connection.sshConfigJson: not in production\n"))

    def test_fails_on_a_file_it_cannot_parse(self):
        code, _, err = self.run_covers(snapshot(), "not a schema")
        self.assertEqual(code, 1)
        self.assertTrue(err.startswith("error: "), err)


if __name__ == "__main__":
    unittest.main()
