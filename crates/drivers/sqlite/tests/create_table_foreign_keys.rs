#![allow(clippy::unwrap_used, clippy::expect_used, clippy::panic)]
use drivers_sqlite::SqliteDriver;
use tablepro_core::sql_ddl::{BuildDdlError, DraftColumn, build_add_foreign_key, build_create_table};
use tablepro_core::{ConnectOptions, DatabaseDriver, ForeignKeyInfo};
use tempfile::TempDir;

fn column(name: &str, primary_key: bool) -> DraftColumn {
    DraftColumn {
        original: None,
        name: name.into(),
        data_type: "INTEGER".into(),
        nullable: !primary_key,
        primary_key,
        auto_increment: false,
        default_value: None,
        comment: None,
        collation: None,
    }
}

fn user_key() -> ForeignKeyInfo {
    ForeignKeyInfo {
        name: "orders_user".into(),
        columns: vec!["user_id".into()],
        ref_schema: Some("main".into()),
        ref_table: "users".into(),
        ref_columns: vec!["id".into()],
        on_delete: Some("CASCADE".into()),
        on_update: None,
    }
}

#[tokio::test]
async fn a_new_table_is_created_with_its_foreign_keys() {
    let dir = TempDir::new().unwrap();
    let options = ConnectOptions {
        database: dir.path().join("keys.db").to_string_lossy().to_string(),
        ..Default::default()
    };
    let conn = SqliteDriver.connect(options).await.unwrap();
    conn.execute("CREATE TABLE users (id INTEGER PRIMARY KEY)")
        .await
        .unwrap();

    let statements = build_create_table(
        "sqlite",
        Some("main"),
        "orders",
        &[column("id", true), column("user_id", false)],
        &[],
        &[user_key()],
    )
    .unwrap();
    for statement in &statements {
        conn.execute(statement)
            .await
            .unwrap_or_else(|error| panic!("{statement}: {error}"));
    }

    let keys = conn.fetch_foreign_keys(Some("main"), "orders").await.unwrap();
    assert_eq!(keys.len(), 1, "{keys:?}");
    assert_eq!(keys[0].columns, ["user_id"]);
    assert_eq!(keys[0].ref_table, "users");
    assert_eq!(keys[0].ref_columns, ["id"]);
    assert_eq!(keys[0].on_delete.as_deref(), Some("CASCADE"));
}

#[test]
fn adding_a_foreign_key_to_an_existing_sqlite_table_is_refused_before_sql() {
    let error = build_add_foreign_key("sqlite", None, "orders", &user_key()).unwrap_err();
    assert!(matches!(error, BuildDdlError::SqliteNotSupported(_)), "{error:?}");
}
