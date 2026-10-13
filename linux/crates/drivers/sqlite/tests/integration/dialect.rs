//! The dialect's filters against SQLite itself.

use tablepro_core::browse::build_count;
use tablepro_core::column::ColumnType;
use tablepro_core::filter::{FilterOp, FilterRule, FilterSet, FilterValue};
use tablepro_core::meta::TableRef;
use tablepro_core::{Connection, Value};

use crate::support::{TestFile, apply, call, query};

async fn matching(connection: &dyn Connection, table: &TableRef, op: FilterOp, text: &str) -> u64 {
    let columns = connection.fetch_columns(table, call()).await.unwrap();
    let filter = FilterSet {
        rules: vec![FilterRule {
            column: "name".to_owned(),
            op,
            value: Some(FilterValue::Single(text.to_owned())),
        }],
        ..FilterSet::default()
    };
    let dialect = connection.dialect();
    let count = build_count(dialect.as_ref(), table, &columns, &filter).unwrap();
    connection.count_rows(&count, call()).await.unwrap()
}

#[tokio::test]
async fn like_escape_matches_literal_underscore_and_percent() {
    let file = TestFile::new().await;
    let connection = file.open().await;
    apply(
        connection.as_ref(),
        &[
            "CREATE TABLE names (name TEXT)",
            "INSERT INTO names VALUES ('user_id'), ('userXid'), ('50%'), ('500')",
        ],
    )
    .await
    .unwrap();
    let table = TableRef::unqualified("names");

    assert_eq!(
        matching(connection.as_ref(), &table, FilterOp::Contains, "user_id").await,
        1
    );
    assert_eq!(
        matching(connection.as_ref(), &table, FilterOp::Contains, "50%").await,
        1
    );
    assert_eq!(
        matching(connection.as_ref(), &table, FilterOp::StartsWith, "user").await,
        2
    );
    connection.close().await.unwrap();
}

#[tokio::test]
async fn insensitive_filter_matches_mixed_case() {
    let file = TestFile::new().await;
    let connection = file.open().await;
    apply(
        connection.as_ref(),
        &[
            "CREATE TABLE names (name TEXT)",
            "INSERT INTO names VALUES ('Alpha'), ('beta')",
        ],
    )
    .await
    .unwrap();
    let table = TableRef::unqualified("names");

    assert_eq!(matching(connection.as_ref(), &table, FilterOp::Ilike, "%aLP%").await, 1);
    connection.close().await.unwrap();
}

#[tokio::test]
async fn a_text_literal_with_a_nul_reads_back_whole() {
    let file = TestFile::new().await;
    let connection = file.open().await;
    let text = "before\0after 'quoted'";
    let literal = connection
        .dialect()
        .literal(&Value::Text(text.to_owned()), &ColumnType::untyped_text("TEXT"))
        .unwrap();

    let read = query(connection.as_ref(), &format!("SELECT {literal}")).await;

    assert_eq!(read.rows[0][0], Value::Text(text.to_owned()));
    connection.close().await.unwrap();
}
