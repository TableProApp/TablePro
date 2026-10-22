#![allow(clippy::unwrap_used, clippy::expect_used, clippy::panic)]
use drivers_sqlite::SqliteDriver;
use tablepro_core::sql_ddl::{BuildDdlError, build_create_index};
use tablepro_core::{ConnectOptions, DatabaseDriver};

#[tokio::test(flavor = "multi_thread")]
async fn an_expression_index_is_marked_and_not_rebuilt_as_a_column_index() {
    let connection = SqliteDriver
        .connect(ConnectOptions {
            database: ":memory:".into(),
            ..Default::default()
        })
        .await
        .expect("connect");
    for sql in [
        "CREATE TABLE people (id INTEGER PRIMARY KEY, email TEXT)",
        "CREATE INDEX people_email_lower ON people (lower(email), id)",
        "CREATE INDEX people_email ON people (email)",
    ] {
        connection.execute(sql).await.unwrap();
    }

    let indexes = connection.fetch_indexes(None, "people").await.unwrap();
    let functional = indexes.iter().find(|index| index.name == "people_email_lower").unwrap();
    assert!(functional.has_expression_key);
    assert_eq!(functional.columns.len(), 2);
    assert!(!functional.columns[0].is_empty());
    assert_eq!(functional.columns[1], "id");
    let error = build_create_index("sqlite", None, "people", functional).unwrap_err();
    assert!(matches!(error, BuildDdlError::ExpressionIndex), "{error:?}");

    let plain = indexes.iter().find(|index| index.name == "people_email").unwrap();
    assert!(!plain.has_expression_key);
    assert_eq!(plain.columns, ["email"]);
}
