//! Values read off DuckDB's results, checked against DuckDB's own text
//! for them.

use tablepro_core::RunEnd;
use tablepro_core::meta::TableRef;
use tablepro_core::value::{OtherValue, Value};

use crate::support::{TestFile, apply, call, query, run, session};

/// Nested values an editor run reads come back as DuckDB's own text,
/// the text a table tab gets from `CAST(... AS VARCHAR)`.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn nested_values_read_as_duckdb_prints_them() {
    let file = TestFile::new();
    let connection = file.open().await;
    let editor = session(connection.as_ref()).await;
    let values = [
        "[1, 2, NULL]",
        "['a', 'b c', '', 'it''s', 'x,y', ' lead', 'trail ', 'null', 'a\\b', '[x]', '{y}', 'k=v', 'a:b']",
        "[[1, 2], [3], []]",
        "[1.0, 0.1, 1e300, 1e-7, -2.5]::DOUBLE[]",
        "[1.5, 0.1]::FLOAT[]",
        "[1.5, -0.005]::DECIMAL(10,3)[]",
        "[TIMESTAMP '2024-01-01 10:00:00', TIMESTAMP '2024-01-01 10:00:00.123', NULL]",
        "[TIMESTAMP_NS '2024-01-01 00:00:00.123456789']",
        "[DATE '2024-02-29', DATE '0044-03-15 (BC)', 'infinity'::DATE]",
        "[TIME '12:00:00', TIME '23:59:59.5']",
        "[INTERVAL '1 year 2 months 3 days 04:05:06.789', INTERVAL '-1 day', INTERVAL '0 seconds']",
        "['\\xAA'::BLOB, 'abc'::BLOB, 'a''b\\x5Cc'::BLOB]",
        "[true, false]",
        "[170141183460469231731687303715884105727::HUGEINT]",
        "['a0eebc99-9c0b-4ef8-bb6d-6bb9bd380a11'::UUID]",
        "['10101'::BIT]",
        "[TIMESTAMPTZ '2024-03-10 10:30:00+02']",
        "{'a': 1, 'b': 'x y', 'c': NULL, 'd': 'it''s', 'e f': [1, 2], 'g': {'h': 'i'}}",
        "MAP {'k1': 1, 'k 2': NULL, 'a,b': 3}",
        "MAP {1: [1, 2], 2: []}",
        "[1, 2, 3]::INTEGER[3]",
        "union_value(n := 2)::UNION(n INTEGER, s VARCHAR)",
        "union_value(s := 'x, y')::UNION(n INTEGER, s VARCHAR)",
        "[union_value(s := 'x, y')::UNION(n INTEGER, s VARCHAR)]",
        "[{'k': 'a,b'}, NULL]",
        "['happy'::ENUM('sad', 'happy')]",
    ];
    let mut wrong = Vec::new();
    for value in values {
        let (summary, collected) = run(
            editor.as_ref(),
            &format!("SELECT {value} AS v, CAST({value} AS VARCHAR) AS t"),
        )
        .await;
        assert_eq!(summary.end, RunEnd::Completed, "{value}");
        let rows = collected.rows();
        let (read, text) = (&rows[0][0], &rows[0][1]);
        let Value::Text(expected) = text else {
            panic!("the cast of {value} read as {text:?}");
        };
        match read {
            Value::Other(other) if other.text == *expected => {}
            other => wrong.push(format!("{value}: read {other:?}, DuckDB prints {expected:?}")),
        }
    }
    assert!(wrong.is_empty(), "{}", wrong.join("\n"));
    editor.close().await;
    connection.close().await.unwrap();
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_time_with_an_offset_is_not_read_without_it() {
    let file = TestFile::new();
    let connection = file.open().await;
    let editor = session(connection.as_ref()).await;

    let (_, collected) = run(
        editor.as_ref(),
        "SELECT TIMETZ '12:30:00+05:30' AS t, [TIMETZ '01:00:00+00'] AS l",
    )
    .await;

    for value in &collected.rows()[0] {
        assert!(matches!(value, Value::Undecodable(_)), "{value:?}");
    }
    editor.close().await;
    connection.close().await.unwrap();
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_nested_value_carries_its_type_name() {
    let file = TestFile::new();
    let connection = file.open().await;
    let editor = session(connection.as_ref()).await;

    let (_, collected) = run(editor.as_ref(), "SELECT {'a': 1, 'b c': ['x']} AS v").await;

    assert_eq!(
        collected.rows()[0][0],
        Value::Other(Box::new(OtherValue {
            type_name: "STRUCT(a INTEGER, \"b c\" VARCHAR[])".to_owned(),
            text: "{'a': 1, 'b c': [x]}".to_owned(),
        }))
    );
    editor.close().await;
    connection.close().await.unwrap();
}

/// DuckDB's Arrow output wraps an interval past about 292 years, which
/// reads as unreadable rather than as another interval.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn an_interval_arrow_cannot_carry_is_not_read_as_another() {
    let file = TestFile::new();
    let connection = file.open().await;
    let editor = session(connection.as_ref()).await;

    let (_, collected) = run(
        editor.as_ref(),
        "SELECT INTERVAL '10000000000000000 microseconds' AS long, INTERVAL '1 day' AS short",
    )
    .await;

    let rows = collected.rows();
    assert!(matches!(&rows[0][0], Value::Undecodable(_)), "{:?}", rows[0][0]);
    assert!(matches!(&rows[0][1], Value::Interval(_)), "{:?}", rows[0][1]);
    editor.close().await;
    connection.close().await.unwrap();
}

/// A table tab reads a UNION, or a type holding one, as a value of its
/// type rather than as DuckDB's text, which names no member: a SQL export
/// then has no literal for it instead of writing text that reads back as
/// another member.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_union_in_a_table_reads_as_a_value_with_no_literal() {
    let file = TestFile::new();
    let connection = file.open().await;
    apply(
        connection.as_ref(),
        &[
            "CREATE TABLE u (id INTEGER PRIMARY KEY, v UNION(n INTEGER, s VARCHAR), \
             l UNION(n INTEGER, s VARCHAR)[], st STRUCT(a UNION(n INTEGER, s VARCHAR)))",
            "INSERT INTO u VALUES (1, union_value(n := 2), [union_value(s := 'x')], {'a': union_value(n := 3)})",
        ],
    )
    .await
    .unwrap();
    let columns = connection
        .fetch_columns(&TableRef::unqualified("u"), call())
        .await
        .unwrap();
    let dialect = connection.dialect();
    let projected: Vec<String> = columns.iter().map(|column| dialect.projection(column)).collect();

    let read = query(connection.as_ref(), &format!("SELECT {} FROM u", projected.join(", "))).await;

    for (index, column) in columns.iter().enumerate().skip(1) {
        let value = &read.rows[0][index];
        assert!(matches!(value, Value::Other(_)), "{}: {value:?}", column.name);
        assert!(
            dialect.literal(value, &read.columns[index].column_type).is_err(),
            "{} has a literal: {value:?}",
            column.name
        );
    }
    connection.close().await.unwrap();
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn every_cell_expression_is_evaluated_by_the_engine() {
    let file = TestFile::new();
    let connection = file.open().await;
    apply(
        connection.as_ref(),
        &[
            "CREATE TABLE stamps (id INTEGER PRIMARY KEY, seen TIMESTAMP, seen_tz TIMESTAMPTZ, day DATE, clock TIME, \
             defaulted TIMESTAMP DEFAULT TIMESTAMP '2000-01-01')",
            "INSERT INTO stamps (id) VALUES (1)",
        ],
    )
    .await
    .expect("the table");

    let checked =
        tablepro_test_support::check_cell_expressions(connection.as_ref(), &TableRef::unqualified("stamps"), call)
            .await
            .expect("every expression saves");

    assert_eq!(checked, 3);
}
