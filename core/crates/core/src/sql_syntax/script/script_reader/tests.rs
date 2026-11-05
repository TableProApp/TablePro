use super::*;

fn read_in_pieces(grammar: SqlGrammar, text: &str, piece: usize) -> Vec<ScriptUnit> {
    let mut reader = ScriptReader::new(grammar).with_copy_overriding(Some("OVERRIDING SYSTEM VALUE"));
    let mut units = Vec::new();
    let mut start = 0;
    while start < text.len() {
        let mut end = (start + piece).min(text.len());
        while !text.is_char_boundary(end) {
            end += 1;
        }
        units.extend(reader.push(&text[start..end]).expect("a piece"));
        start = end;
    }
    units.extend(reader.finish().expect("the end"));
    units
}

/// Every way of cutting the text into pieces reads the same units.
fn read_every_way(grammar: SqlGrammar, text: &str) -> Vec<ScriptUnit> {
    let whole = read_in_pieces(grammar, text, text.len().max(1));
    for piece in [1, 2, 3, 7, 64] {
        assert_eq!(read_in_pieces(grammar, text, piece), whole, "pieces of {piece}");
    }
    whole
}

fn texts(units: &[ScriptUnit]) -> Vec<&str> {
    units.iter().map(|unit| unit.text.as_str()).collect()
}

#[test]
fn statements_split_at_semicolons_with_their_lines() {
    let units = read_every_way(
        SqlGrammar::PostgreSql,
        "-- head\nCREATE TABLE t (a text);\nINSERT INTO t VALUES ('a;b'),\n('c');\n\nSELECT 1",
    );

    assert_eq!(
        texts(&units),
        [
            "CREATE TABLE t (a text)",
            "INSERT INTO t VALUES ('a;b'),\n('c')",
            "SELECT 1"
        ]
    );
    assert_eq!(units.iter().map(|unit| unit.line).collect::<Vec<_>>(), [2, 3, 6]);
}

#[test]
fn a_dollar_quoted_body_stays_one_statement() {
    let units = read_every_way(
        SqlGrammar::PostgreSql,
        "CREATE FUNCTION f() RETURNS int AS $$ SELECT 1; $$ LANGUAGE sql;\nSELECT f();\n",
    );

    assert_eq!(units.len(), 2, "{units:?}");
    assert!(units[0].text.ends_with("LANGUAGE sql"));
}

#[test]
fn a_mysql_delimiter_holds_across_pieces() {
    let units = read_every_way(
        SqlGrammar::MySql,
        "/*!40101 SET NAMES utf8mb4 */;\nDELIMITER ;;\nCREATE PROCEDURE p()\nBEGIN\n  SELECT 1;\n  SELECT 2;\nEND ;;\nDELIMITER ;\nCALL p();\n",
    );

    assert_eq!(
        texts(&units),
        [
            "/*!40101 SET NAMES utf8mb4 */",
            "CREATE PROCEDURE p()\nBEGIN\n  SELECT 1;\n  SELECT 2;\nEND",
            "CALL p()"
        ]
    );
    assert_eq!(units[1].line, 3);
}

#[test]
fn a_sql_server_batch_ends_at_go_and_keeps_its_count() {
    let units = read_every_way(
        SqlGrammar::MsSql,
        "CREATE TABLE t (a int);\nINSERT INTO t VALUES (1);\nGO\nCREATE VIEW v AS SELECT a FROM t\nGO 2\nSELECT 1\n",
    );

    assert_eq!(
        texts(&units),
        [
            "CREATE TABLE t (a int);\nINSERT INTO t VALUES (1);",
            "CREATE VIEW v AS SELECT a FROM t",
            "SELECT 1"
        ]
    );
    assert_eq!(units.iter().map(|unit| unit.repeat).collect::<Vec<_>>(), [1, 2, 1]);
    assert_eq!(units[1].line, 4);
}

#[test]
fn pg_dump_copy_rows_become_inserts_and_restrict_lines_are_passed_over() {
    let dump = "--\n-- PostgreSQL database dump\n--\n\n\\restrict abc123\n\nSET client_encoding = 'UTF8';\n\nCOPY app.child (id, note) FROM stdin;\n1\tit's\n2\t\\N\n\\.\n\nSELECT pg_catalog.setval('app.child_id_seq', 5, true);\n\n\\unrestrict abc123\n";

    let units = read_every_way(SqlGrammar::PostgreSql, dump);

    let kinds: Vec<&ScriptUnitKind> = units.iter().map(|unit| &unit.kind).collect();
    assert_eq!(
        kinds,
        [
            &ScriptUnitKind::ClientOnly,
            &ScriptUnitKind::Run,
            &ScriptUnitKind::Run,
            &ScriptUnitKind::Run,
            &ScriptUnitKind::ClientOnly
        ],
        "{units:?}"
    );
    assert_eq!(
        units[2].text,
        "INSERT INTO app.child (id, note) OVERRIDING SYSTEM VALUE VALUES\n(E'1', E'it''s'),\n(E'2', NULL)"
    );
    assert_eq!(units[2].line, 10);
    assert_eq!(units[3].line, 14);
}

#[test]
fn a_copy_with_options_is_refused_and_its_rows_skipped() {
    let units = read_every_way(
        SqlGrammar::PostgreSql,
        "COPY t FROM stdin WITH (FORMAT csv);\n1,2\n\\.\nSELECT 1;\n",
    );

    assert_eq!(units.len(), 2, "{units:?}");
    assert_eq!(units[0].kind, ScriptUnitKind::Refused(RefusedUnit::CopyFormat));
    assert_eq!(units[1].text, "SELECT 1");
}

#[test]
fn another_psql_command_is_refused_with_its_name() {
    let units = read_every_way(SqlGrammar::PostgreSql, "SELECT 1;\n\\connect other\nSELECT 2;\n");

    assert_eq!(texts(&units), ["SELECT 1", "\\connect other", "SELECT 2"]);
    assert_eq!(
        units[1].kind,
        ScriptUnitKind::Refused(RefusedUnit::ClientCommand {
            command: "\\connect".to_owned()
        })
    );
    assert_eq!(units[1].line, 2);
}

#[test]
fn a_backslash_line_is_not_special_outside_postgresql() {
    let units = read_every_way(SqlGrammar::MySql, "SELECT '\\\\';\n");

    assert_eq!(texts(&units), ["SELECT '\\\\'"]);
}

#[test]
fn transaction_statements_are_told_apart_from_savepoints() {
    use TransactionControl::{Begin, Commit, Rollback};
    let cases = [
        ("BEGIN", Some(Begin)),
        ("BEGIN TRANSACTION", Some(Begin)),
        ("begin immediate", Some(Begin)),
        ("START TRANSACTION", Some(Begin)),
        ("COMMIT", Some(Commit)),
        ("END", Some(Commit)),
        ("ROLLBACK", Some(Rollback)),
        ("ROLLBACK TO SAVEPOINT a", None),
        ("ROLLBACK TRANSACTION TO a", None),
        ("COMMIT PREPARED 'x'", None),
        ("SELECT 1", None),
    ];
    for (text, expected) in cases {
        assert_eq!(transaction_control(text, SqlGrammar::PostgreSql), expected, "{text}");
    }
}
