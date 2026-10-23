//! The table filter on DuckDB's own types.

use tablepro_core::filter::{FilterOp, FilterRule, FilterSet, FilterValue, build_filter};
use tablepro_core::meta::TableRef;
use tablepro_core::statement::StatementBuilder;
use tablepro_core::{Connection, RowLimit, Value};

use crate::support::{TestFile, apply, call};

async fn ids_where(connection: &dyn Connection, column: &str, op: FilterOp, text: &str) -> Vec<Value> {
    let table = TableRef::unqualified("docs");
    let columns = connection.fetch_columns(&table, call()).await.unwrap();
    let dialect = connection.dialect();
    let mut builder = StatementBuilder::new();
    builder.push_sql(&format!("SELECT id FROM {} WHERE ", dialect.qualify(&table)));
    let filter = FilterSet {
        rules: vec![FilterRule {
            column: column.to_owned(),
            op,
            value: Some(FilterValue::Single(text.to_owned())),
        }],
        ..FilterSet::default()
    };
    build_filter(&mut builder, dialect.as_ref(), &columns, &filter).unwrap();
    builder.push_sql(" ORDER BY id");
    connection
        .query_bound(&builder.finish(), RowLimit::EDITOR_DEFAULT, call())
        .await
        .unwrap()
        .rows
        .into_iter()
        .filter_map(|row| row.into_iter().next())
        .collect()
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn each_type_filters_on_the_text_the_grid_shows() {
    let file = TestFile::new();
    let connection = file.open().await;
    apply(
        connection.as_ref(),
        &[
            "CREATE TYPE mood AS ENUM ('calm', 'cross')",
            "CREATE TABLE docs (id INTEGER PRIMARY KEY, b BLOB, j JSON, m mood, u UUID, h HUGEINT, made TIMESTAMP)",
            "INSERT INTO docs VALUES \
             (1, '\\x0A\\xFF'::BLOB, '{\"tag\":\"red\"}', 'calm', 'a0eebc99-9c0b-4ef8-bb6d-6bb9bd380a11', \
              170141183460469231731687303715884105727, TIMESTAMP '2024-01-01 10:00:00'), \
             (2, '\\x0A'::BLOB, '{\"tag\":\"blue\"}', 'cross', '00000000-0000-0000-0000-000000000000', \
              -1, TIMESTAMP '2025-06-01 10:00:00')",
        ],
    )
    .await
    .unwrap();
    let first = || vec![Value::Int(1)];
    let second = || vec![Value::Int(2)];

    assert_eq!(ids_where(connection.as_ref(), "b", FilterOp::Eq, "0x0AFF").await, first());
    assert_eq!(ids_where(connection.as_ref(), "b", FilterOp::NotEq, "0x0aff").await, second());
    assert_eq!(ids_where(connection.as_ref(), "j", FilterOp::Contains, "red").await, first());
    assert_eq!(ids_where(connection.as_ref(), "m", FilterOp::Eq, "calm").await, first());
    assert_eq!(ids_where(connection.as_ref(), "m", FilterOp::Contains, "ros").await, second());
    assert_eq!(
        ids_where(
            connection.as_ref(),
            "u",
            FilterOp::Eq,
            "A0EEBC99-9C0B-4EF8-BB6D-6BB9BD380A11"
        )
        .await,
        first()
    );
    assert_eq!(
        ids_where(
            connection.as_ref(),
            "h",
            FilterOp::Eq,
            "170141183460469231731687303715884105727"
        )
        .await,
        first()
    );
    assert_eq!(
        ids_where(connection.as_ref(), "made", FilterOp::Gt, "2024-12-31 00:00:00").await,
        second()
    );
    connection.close().await.unwrap();
}
