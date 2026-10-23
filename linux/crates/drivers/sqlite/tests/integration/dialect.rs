//! The dialect's filters against SQLite itself.

use tablepro_core::browse::{ReferenceError, RowReference, build_count};
use tablepro_core::column::{ColumnType, ResultColumn};
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

/// The cells of each row of `table` under the columns a table tab has.
async fn table_rows(connection: &dyn Connection, table: &str) -> (Vec<ResultColumn>, Vec<Vec<Value>>) {
    let columns = connection
        .fetch_columns(&TableRef::unqualified(table), call())
        .await
        .unwrap()
        .into_iter()
        .map(|info| ResultColumn::new(info.name, info.column_type))
        .collect();
    let rows = query(connection, &format!("SELECT * FROM {table} ORDER BY rowid")).await.rows;
    (columns, rows)
}

async fn rows_found(connection: &dyn Connection, reference: &RowReference) -> u64 {
    let columns = connection.fetch_columns(&reference.table, call()).await.unwrap();
    let dialect = connection.dialect();
    let count = build_count(dialect.as_ref(), &reference.table, &columns, &reference.filter).unwrap();
    connection.count_rows(&count, call()).await.unwrap()
}

/// How many rows the first key of `table` opens from its first row.
async fn followed(connection: &dyn Connection, table: &str) -> Result<u64, ReferenceError> {
    let source = TableRef::unqualified(table);
    let keys = connection.fetch_outbound_foreign_keys(&source, call()).await.unwrap();
    let (columns, rows) = table_rows(connection, table).await;
    let reference = RowReference::referenced(&source, &keys[0], &columns, &rows[0])?;
    Ok(rows_found(connection, &reference).await)
}

/// A followed key opens the rows SQLite matches it to, or says it
/// cannot rather than open others.
#[tokio::test]
async fn a_followed_key_opens_the_rows_it_matches() {
    let file = TestFile::new().await;
    let connection = file.open().await;
    apply(
        connection.as_ref(),
        &[
            "CREATE TABLE owners (id INTEGER PRIMARY KEY, name TEXT)",
            "INSERT INTO owners VALUES (7, 'Bo'), (42, 'Ada')",
            "CREATE TABLE pets (id INTEGER PRIMARY KEY, owner_id INTEGER REFERENCES owners (id))",
            "INSERT INTO pets VALUES (1, 42)",
            "CREATE TABLE quoted (id INTEGER PRIMARY KEY, owner_id \"INTEGER\" REFERENCES owners (id))",
            "INSERT INTO quoted VALUES (1, 42)",
            "CREATE TABLE flags (id BOOLEAN PRIMARY KEY)",
            "INSERT INTO flags VALUES ('true'), ('yes')",
            "CREATE TABLE switches (id INTEGER PRIMARY KEY, flag BOOLEAN REFERENCES flags (id))",
            "INSERT INTO switches VALUES (1, 'true')",
            "CREATE TABLE marks (id INTEGER PRIMARY KEY, flag \"STRING\" REFERENCES flags (id))",
            "INSERT INTO marks VALUES (1, 'true')",
        ],
    )
    .await
    .unwrap();

    assert_eq!(followed(connection.as_ref(), "pets").await, Ok(1));
    assert_eq!(followed(connection.as_ref(), "quoted").await, Ok(1), "a quoted type name");
    assert_eq!(
        followed(connection.as_ref(), "switches").await,
        Err(ReferenceError::NoFilterText { column: "id".to_owned() }),
        "'true' in a BOOLEAN column would be bound as 1"
    );
    assert_eq!(
        followed(connection.as_ref(), "marks").await,
        Err(ReferenceError::ComparedOtherwise {
            table: "flags".to_owned()
        }),
        "\"STRING\" reads as no BOOLEAN"
    );

    let owners = TableRef::unqualified("owners");
    let (columns, rows) = table_rows(connection.as_ref(), "owners").await;
    let inbound = connection.fetch_inbound_foreign_keys(&owners, call()).await.unwrap();
    for key in &inbound {
        let reference = RowReference::referencing(&owners, key, &columns, &rows[1]).unwrap();
        assert_eq!(rows_found(connection.as_ref(), &reference).await, 1, "{}", key.table.name);
    }
    assert_eq!(inbound.len(), 2);
    connection.close().await.unwrap();
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

/// A binary key followed from another table arrives as its hex text.
#[tokio::test]
async fn a_blob_equals_its_hex_form() {
    let file = TestFile::new().await;
    let connection = file.open().await;
    apply(
        connection.as_ref(),
        &[
            "CREATE TABLE names (name BLOB)",
            "INSERT INTO names VALUES (X'0AFF'), (X'0A'), ('0x0aff')",
        ],
    )
    .await
    .unwrap();
    let table = TableRef::unqualified("names");

    assert_eq!(matching(connection.as_ref(), &table, FilterOp::Eq, "0x0aff").await, 1);
    assert_eq!(matching(connection.as_ref(), &table, FilterOp::NotEq, "0x0A").await, 2);
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
