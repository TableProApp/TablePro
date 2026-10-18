//! Filters on columns that are not text but are searched as text.

use tablepro_core::filter::{FilterOp, FilterRule, FilterSet, FilterValue, build_filter};
use tablepro_core::meta::TableRef;
use tablepro_core::statement::StatementBuilder;
use tablepro_core::{Connection, RowLimit, Value};

use crate::support::{CALL, connect, setup, start, within};

async fn ids_where(connection: &dyn Connection, column: &str, op: FilterOp, text: &str) -> Vec<Value> {
    let table = TableRef::new(Some("public".to_owned()), "docs");
    let columns = connection
        .fetch_columns(&table, within(CALL))
        .await
        .expect("the columns");
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
    build_filter(&mut builder, dialect.as_ref(), &columns, &filter).expect("a filter");
    builder.push_sql(" ORDER BY id");
    connection
        .query_bound(&builder.finish(), RowLimit::EDITOR_DEFAULT, within(CALL))
        .await
        .expect("the filtered rows")
        .rows
        .into_iter()
        .filter_map(|row| row.into_iter().next())
        .collect()
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
#[ignore = "requires docker"]
async fn contains_and_equals_on_json_jsonb_xml_and_enum() {
    let fixture = start().await;
    let connection = connect(&fixture, false).await;
    setup(
        connection.as_ref(),
        &[
            "CREATE TYPE mood AS ENUM ('calm', 'cross')",
            "CREATE TABLE docs (id int PRIMARY KEY, j json, jb jsonb, x xml, m mood)",
            "INSERT INTO docs VALUES \
             (1, '{\"tag\":\"red\"}', '{\"tag\":\"red\"}', '<a>red</a>', 'calm'), \
             (2, '{\"tag\":\"blue\"}', '{\"tag\":\"blue\"}', '<a>blue</a>', 'cross')",
        ],
    )
    .await;
    let first = || vec![Value::Int(1)];

    for column in ["j", "jb", "x"] {
        assert_eq!(
            ids_where(connection.as_ref(), column, FilterOp::Contains, "red").await,
            first(),
            "{column}"
        );
    }
    assert_eq!(
        ids_where(connection.as_ref(), "m", FilterOp::StartsWith, "ca").await,
        first()
    );
    assert_eq!(
        ids_where(connection.as_ref(), "j", FilterOp::Eq, "{\"tag\":\"red\"}").await,
        first()
    );
    assert_eq!(
        ids_where(connection.as_ref(), "x", FilterOp::Eq, "<a>red</a>").await,
        first()
    );
    assert_eq!(ids_where(connection.as_ref(), "m", FilterOp::Eq, "calm").await, first());
}
