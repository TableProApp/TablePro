use crate::sql_syntax::script::copy_rows::COPY_PIECE_BYTES;

use super::*;

fn read_in_pieces(grammar: SqlGrammar, text: &str, piece: usize) -> Vec<ScriptUnit> {
    let mut reader = ScriptReader::new(grammar);
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

fn kinds(units: &[ScriptUnit]) -> Vec<&ScriptUnitKind> {
    units.iter().map(|unit| &unit.kind).collect()
}

/// Every piece of COPY rows joined, as the session receives them.
fn copy_data(units: &[ScriptUnit]) -> String {
    units
        .iter()
        .filter(|unit| unit.kind == ScriptUnitKind::CopyData)
        .map(|unit| unit.text.as_str())
        .collect()
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
fn pg_dump_copy_rows_follow_their_copy_and_restrict_lines_are_passed_over() {
    let dump = "--\n-- PostgreSQL database dump\n--\n\n\\restrict abc123\n\nSET client_encoding = 'UTF8';\n\nCOPY app.child (id, note) FROM stdin;\n1\tit's\n2\t\\N\n\\.\n\nSELECT pg_catalog.setval('app.child_id_seq', 5, true);\n\n\\unrestrict abc123\n";

    let units = read_every_way(SqlGrammar::PostgreSql, dump);

    assert_eq!(
        kinds(&units),
        [
            &ScriptUnitKind::ClientOnly,
            &ScriptUnitKind::Run,
            &ScriptUnitKind::CopyFromStdin,
            &ScriptUnitKind::CopyData,
            &ScriptUnitKind::CopyEnd,
            &ScriptUnitKind::Run,
            &ScriptUnitKind::ClientOnly
        ],
        "{units:?}"
    );
    assert_eq!(units[2].text, "COPY app.child (id, note) FROM stdin");
    assert_eq!(units[3].text, "1\tit's\n2\t\\N\n");
    assert_eq!(
        [units[2].line, units[3].line, units[4].line, units[5].line],
        [9, 10, 12, 14]
    );
}

#[test]
fn crlf_rows_pass_byte_exact_and_a_crlf_end_marker_is_not_sent() {
    let units = read_every_way(
        SqlGrammar::PostgreSql,
        "COPY t FROM stdin;\r\n1\tx\r\n\\.x\r\n2\t\\\\.\r\n\\.\r\nSELECT 1;\r\n",
    );

    assert_eq!(
        kinds(&units),
        [
            &ScriptUnitKind::CopyFromStdin,
            &ScriptUnitKind::CopyData,
            &ScriptUnitKind::CopyEnd,
            &ScriptUnitKind::Run
        ],
        "{units:?}"
    );
    assert_eq!(copy_data(&units), "1\tx\r\n\\.x\r\n2\t\\\\.\r\n");
    assert_eq!(units[3].text, "SELECT 1");
}

#[test]
fn rows_without_an_end_marker_run_to_the_end_of_the_file() {
    let units = read_every_way(SqlGrammar::PostgreSql, "COPY t FROM stdin;\n1\n2");

    assert_eq!(
        kinds(&units),
        [
            &ScriptUnitKind::CopyFromStdin,
            &ScriptUnitKind::CopyData,
            &ScriptUnitKind::CopyEnd
        ],
        "{units:?}"
    );
    assert_eq!(copy_data(&units), "1\n2");
}

#[test]
fn an_end_marker_on_the_last_line_without_a_line_break_is_not_sent() {
    for file in ["COPY t FROM stdin;\n1\n\\.", "COPY t FROM stdin;\n1\n\\.\r"] {
        let units = read_every_way(SqlGrammar::PostgreSql, file);

        assert_eq!(copy_data(&units), "1\n", "{file:?}");
        assert_eq!(units.last().map(|unit| &unit.kind), Some(&ScriptUnitKind::CopyEnd));
    }
}

#[test]
fn what_follows_a_copy_on_its_line_runs_after_its_rows() {
    let units = read_every_way(
        SqlGrammar::PostgreSql,
        "COPY t FROM stdin; SELECT 1; -- after\n1\n\\.\nSELECT 2;\n",
    );

    assert_eq!(
        kinds(&units),
        [
            &ScriptUnitKind::CopyFromStdin,
            &ScriptUnitKind::CopyData,
            &ScriptUnitKind::CopyEnd,
            &ScriptUnitKind::Run,
            &ScriptUnitKind::Run
        ],
        "{units:?}"
    );
    assert_eq!(copy_data(&units), "1\n");
    assert_eq!(texts(&units)[3..], ["SELECT 1", "SELECT 2"]);
    assert_eq!([units[3].line, units[4].line], [1, 4]);
}

#[test]
fn a_second_copy_on_the_line_reads_the_rows_after_the_first() {
    let units = read_every_way(
        SqlGrammar::PostgreSql,
        "COPY a FROM stdin; COPY b FROM stdin;\n1\n\\.\n2\n\\.\nSELECT 3;\n",
    );

    assert_eq!(
        kinds(&units),
        [
            &ScriptUnitKind::CopyFromStdin,
            &ScriptUnitKind::CopyData,
            &ScriptUnitKind::CopyEnd,
            &ScriptUnitKind::CopyFromStdin,
            &ScriptUnitKind::CopyData,
            &ScriptUnitKind::CopyEnd,
            &ScriptUnitKind::Run
        ],
        "{units:?}"
    );
    assert_eq!(texts(&units)[3], "COPY b FROM stdin");
    assert_eq!(units[4].text, "2\n");
    let lines: Vec<u64> = units.iter().map(|unit| unit.line).collect();
    assert_eq!(lines, [1, 2, 3, 1, 4, 5, 6]);
}

#[test]
fn a_copy_on_a_long_line_waits_for_the_rest_of_its_line() {
    // The line reaches the length the reader plans a long line at just
    // after the COPY's `;`, partway through the statement after it.
    let inserts = "INSERT INTO t VALUES (1);".repeat(2_620);
    let file = format!("{inserts} COPY t FROM stdin; DELETE FROM t WHERE a = 'tmp';\nkeep me\n\\.\n");
    assert!((inserts.len() + 19..inserts.len() + 50).contains(&PLAN_STEP));

    let units = read_every_way(SqlGrammar::PostgreSql, &file);

    assert_eq!(units.len(), 2_624, "{:?}", &units[2_615..]);
    assert_eq!(
        kinds(&units)[2_620..],
        [
            &ScriptUnitKind::CopyFromStdin,
            &ScriptUnitKind::CopyData,
            &ScriptUnitKind::CopyEnd,
            &ScriptUnitKind::Run
        ]
    );
    assert_eq!(copy_data(&units), "keep me\n");
    assert_eq!(units[2_623].text, "DELETE FROM t WHERE a = 'tmp'");
    assert_eq!(units[2_623].line, 1);
}

#[test]
fn the_rows_start_on_the_line_after_the_copys_terminator() {
    let units = read_every_way(SqlGrammar::PostgreSql, "COPY t FROM stdin\n;\n1\n\\.\nSELECT 1;\n");

    assert_eq!(texts(&units)[0], "COPY t FROM stdin");
    assert_eq!(copy_data(&units), "1\n");
    assert_eq!([units[1].line, units[3].line], [3, 5]);
}

#[test]
fn a_copy_with_no_rows_still_ends() {
    let units = read_every_way(SqlGrammar::PostgreSql, "COPY t FROM stdin;\n\\.\nSELECT 1;\n");

    assert_eq!(
        kinds(&units),
        [
            &ScriptUnitKind::CopyFromStdin,
            &ScriptUnitKind::CopyEnd,
            &ScriptUnitKind::Run
        ],
        "{units:?}"
    );
}

#[test]
fn a_csv_copy_with_options_passes_its_rows_as_written() {
    let rows = "id;note\n1;\"two\nlines\"\n2;x\n";
    let units = read_every_way(
        SqlGrammar::PostgreSql,
        &format!("COPY t FROM stdin WITH (FORMAT csv, HEADER true, DELIMITER ';', NULL 'x');\n{rows}\\.\nSELECT 1;\n"),
    );

    assert_eq!(
        units[0].text,
        "COPY t FROM stdin WITH (FORMAT csv, HEADER true, DELIMITER ';', NULL 'x')"
    );
    assert_eq!(units[0].kind, ScriptUnitKind::CopyFromStdin);
    assert_eq!(copy_data(&units), rows);
    assert_eq!(units.last().map(|unit| unit.text.as_str()), Some("SELECT 1"));
}

#[test]
fn a_binary_copy_is_refused_and_its_rows_passed_over() {
    for copy in [
        "COPY t FROM stdin (FORMAT binary);",
        "COPY t FROM STDIN WITH (format 'binary');",
        "COPY BINARY t FROM stdin;",
        "COPY t FROM stdin WITH BINARY;",
    ] {
        let units = read_every_way(
            SqlGrammar::PostgreSql,
            &format!("{copy}\nPGCOPY\n\u{1}\u{2}\n\\.\nSELECT 1;\n"),
        );

        assert_eq!(
            kinds(&units),
            [&ScriptUnitKind::Refused(RefusedUnit::CopyBinary), &ScriptUnitKind::Run],
            "{copy}: {units:?}"
        );
        assert_eq!(units[1].text, "SELECT 1");
    }
}

#[test]
fn long_rows_come_in_pieces_cut_by_size_whatever_the_reads() {
    let rows: String = (0..60_000).map(|n| format!("{n}\tr\u{e9}sum\u{e9} {n}\n")).collect();
    let file = format!("COPY t (a, b) FROM stdin;\n{rows}\\.\nSELECT 1;\n");

    let whole = read_in_pieces(SqlGrammar::PostgreSql, &file, file.len());
    for piece in [4_096, 100_003] {
        assert_eq!(
            read_in_pieces(SqlGrammar::PostgreSql, &file, piece),
            whole,
            "reads of {piece}"
        );
    }

    let pieces: Vec<&ScriptUnit> = whole
        .iter()
        .filter(|unit| unit.kind == ScriptUnitKind::CopyData)
        .collect();
    assert!(pieces.len() >= 3, "{} pieces", pieces.len());
    assert!(pieces.iter().all(|piece| piece.text.len() <= COPY_PIECE_BYTES));
    assert_eq!(copy_data(&whole), rows);
    assert_eq!(pieces[0].line, 2);
    let second_starts = 2 + pieces[0].text.matches('\n').count() as u64;
    assert_eq!(pieces[1].line, second_starts);
    assert_eq!(whole.last().map(|unit| unit.line), Some(60_003));
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

#[test]
fn a_file_on_one_line_is_cut_where_its_statements_end() {
    let line: String = (0..20_000).map(|n| format!("INSERT INTO t VALUES ({n});")).collect();
    let mut reader = ScriptReader::new(SqlGrammar::Sqlite);

    let early = reader.push(&line).expect("the line");

    assert!(
        early.len() > 19_000,
        "only {} statements came before the end",
        early.len()
    );
    let rest = reader.finish().expect("the end");
    assert_eq!(early.len() + rest.len(), 20_000);
}

#[test]
fn a_session_without_backslash_escapes_reads_a_file_that_sets_nothing() {
    let mut reader = ScriptReader::new(SqlGrammar::MySql).with_settings(LexicalSettings {
        backslash_escapes: false,
    });

    let mut units = reader
        .push("INSERT INTO t VALUES ('a\\'); INSERT INTO t VALUES ('b;c');\n")
        .expect("the file");
    units.extend(reader.finish().expect("the end"));

    assert_eq!(
        texts(&units),
        ["INSERT INTO t VALUES ('a\\')", "INSERT INTO t VALUES ('b;c')"]
    );
}

#[test]
fn a_long_line_after_a_comment_line_is_cut_where_its_statements_end() {
    let line: String = (0..20_000).map(|n| format!("INSERT INTO t VALUES ({n});")).collect();
    let mut reader = ScriptReader::new(SqlGrammar::Sqlite);

    let early = reader
        .push(&format!("-- header\nINSERT INTO t VALUES\n(-1);{line}"))
        .expect("the line");

    assert!(
        early.len() > 19_000,
        "only {} statements came before the end",
        early.len()
    );
    let rest = reader.finish().expect("the end");
    assert_eq!(early.len() + rest.len(), 20_001);
}

#[test]
fn a_routine_made_under_no_backslash_escapes_splits_as_the_server_reads_it() {
    let units = read_every_way(
        SqlGrammar::MySql,
        "SET @saved_sql_mode = @@sql_mode;\nSET sql_mode = 'NO_BACKSLASH_ESCAPES';\nDELIMITER ;;\nCREATE FUNCTION f() RETURNS text RETURN 'a\\';;\nDELIMITER ;\nSET sql_mode = @saved_sql_mode;\nSELECT 'it\\'s';\n",
    );

    assert_eq!(
        texts(&units),
        [
            "SET @saved_sql_mode = @@sql_mode",
            "SET sql_mode = 'NO_BACKSLASH_ESCAPES'",
            "CREATE FUNCTION f() RETURNS text RETURN 'a\\'",
            "SET sql_mode = @saved_sql_mode",
            "SELECT 'it\\'s'"
        ]
    );
}
