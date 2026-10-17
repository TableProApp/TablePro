use super::*;

#[test]
fn structure_metadata_declarations_match_the_connection_impl() {
    let d = SqliteDriver;
    let source = include_str!("lib.rs");
    assert!(d.supports_index_metadata());
    assert!(d.supports_foreign_key_metadata());
    assert!(source.contains(&["async fn ", "fetch_indexes("].concat()));
    assert!(source.contains(&["async fn ", "fetch_foreign_keys("].concat()));
}
use tempfile::TempDir;

fn opts_for(path: &str) -> ConnectOptions {
    ConnectOptions {
        database: path.to_string(),
        ..Default::default()
    }
}

#[tokio::test]
async fn a_read_only_connection_cannot_write_even_when_sql_tries() {
    let dir = TempDir::new().unwrap();
    let path = dir.path().join("ro.db");
    let writer = SqliteDriver.connect(opts_for(path.to_str().unwrap())).await.unwrap();
    writer
        .execute("CREATE TABLE foo (id INTEGER PRIMARY KEY)")
        .await
        .unwrap();
    writer.execute("INSERT INTO foo VALUES (1)").await.unwrap();
    drop(writer);

    let reader = SqliteDriver
        .connect(ConnectOptions {
            read_only: true,
            ..opts_for(path.to_str().unwrap())
        })
        .await
        .unwrap();
    assert_eq!(reader.query("SELECT id FROM foo").await.unwrap().rows.len(), 1);
    for sql in [
        "INSERT INTO foo VALUES (2)",
        "CREATE TABLE bar (id INTEGER)",
        "DROP TABLE foo",
        "PRAGMA query_only = OFF",
    ] {
        let outcome = reader.execute(sql).await;
        let wrote = outcome.is_ok() && reader.query("SELECT id FROM foo").await.unwrap().rows.len() != 1;
        assert!(!wrote, "{sql} must not change a read-only database");
    }
    assert_eq!(reader.query("SELECT id FROM foo").await.unwrap().rows.len(), 1);
}

#[tokio::test]
async fn a_read_only_connection_does_not_create_a_missing_file() {
    let dir = TempDir::new().unwrap();
    let path = dir.path().join("missing.db");
    let outcome = SqliteDriver
        .connect(ConnectOptions {
            read_only: true,
            ..opts_for(path.to_str().unwrap())
        })
        .await;
    assert!(outcome.is_err());
    assert!(!path.exists());
}

#[tokio::test]
async fn driver_metadata() {
    let d = SqliteDriver;
    assert_eq!(d.id(), "sqlite");
    assert_eq!(d.display_name(), "SQLite");
    assert_eq!(d.default_port(), 0);
    assert_eq!(d.default_database(), "");
    assert_eq!(d.default_username(), "");
}

#[tokio::test]
async fn an_expression_column_decodes_by_its_runtime_type() {
    let dir = TempDir::new().unwrap();
    let path = dir.path().join("untyped.db");
    let conn = SqliteDriver.connect(opts_for(path.to_str().unwrap())).await.unwrap();
    conn.execute("CREATE TABLE t (id INTEGER PRIMARY KEY, label TEXT)")
        .await
        .unwrap();
    conn.execute("INSERT INTO t (label) VALUES ('a'), ('b')").await.unwrap();

    let counted = conn.query("SELECT count(*) FROM t").await.unwrap();
    assert_eq!(counted.rows, vec![vec![Value::Int(2)]]);

    let mixed = conn
        .query("SELECT 1, 2.5, 'text', NULL, group_concat(label), CAST('text blob' AS BLOB) FROM t")
        .await
        .unwrap();
    assert_eq!(
        mixed.rows,
        vec![vec![
            Value::Int(1),
            Value::Float(2.5),
            Value::Text("text".into()),
            Value::Null,
            Value::Text("a,b".into()),
            Value::Bytes(b"text blob".to_vec()),
        ]]
    );
    let blob_oracle = conn
        .query("SELECT typeof(CAST('text blob' AS BLOB)), hex(CAST('text blob' AS BLOB))")
        .await
        .unwrap();
    assert_eq!(
        blob_oracle.rows,
        vec![vec![
            Value::Text("blob".into()),
            Value::Text("7465787420626C6F62".into())
        ]]
    );
}

#[tokio::test]
async fn a_value_that_does_not_match_its_declared_column_type_keeps_its_text_instead_of_becoming_null() {
    let dir = TempDir::new().unwrap();
    let path = dir.path().join("affinity.db");
    let conn = SqliteDriver.connect(opts_for(path.to_str().unwrap())).await.unwrap();
    conn.execute("CREATE TABLE t (v REAL)").await.unwrap();
    conn.execute("INSERT INTO t (v) VALUES ('not-a-number')").await.unwrap();
    let result = conn.query("SELECT v FROM t").await.unwrap();
    assert_eq!(result.rows, vec![vec![Value::Text("not-a-number".into())]]);
}

#[tokio::test]
async fn connect_create_and_list_tables() {
    let dir = TempDir::new().unwrap();
    let path = dir.path().join("test.db");
    let driver = SqliteDriver;
    let conn = driver.connect(opts_for(path.to_str().unwrap())).await.unwrap();
    conn.execute("CREATE TABLE foo (id INTEGER PRIMARY KEY, name TEXT)")
        .await
        .unwrap();
    conn.execute("INSERT INTO foo (name) VALUES ('a'), ('b'), ('c')")
        .await
        .unwrap();
    let tables = conn.list_tables().await.unwrap();
    assert_eq!(tables.len(), 1);
    assert_eq!(tables[0].name, "foo");
    let cols = conn.fetch_columns(None, "foo").await.unwrap();
    assert_eq!(cols.len(), 2);
    assert_eq!(cols[0].name, "id");
    assert!(cols[0].primary_key);
    let result = conn.fetch_rows(None, "foo", 0, 100).await.unwrap();
    assert_eq!(result.columns.len(), 2);
    assert_eq!(result.rows.len(), 3);
}

#[tokio::test]
async fn fetch_rows_paginates() {
    let dir = TempDir::new().unwrap();
    let path = dir.path().join("page.db");
    let driver = SqliteDriver;
    let conn = driver.connect(opts_for(path.to_str().unwrap())).await.unwrap();
    conn.execute("CREATE TABLE n (i INTEGER)").await.unwrap();
    for i in 1..=10 {
        conn.execute(&format!("INSERT INTO n VALUES ({i})")).await.unwrap();
    }
    let page = conn.fetch_rows(None, "n", 5, 3).await.unwrap();
    assert_eq!(page.rows.len(), 3);
}

#[test]
fn quote_ident_doubles_embedded_quotes() {
    assert_eq!(quote_ident("users"), "\"users\"");
    assert_eq!(quote_ident("My Table"), "\"My Table\"");
    assert_eq!(
        quote_ident("evil\"; DROP TABLE x; --"),
        "\"evil\"\"; DROP TABLE x; --\""
    );
}

#[tokio::test]
async fn fetch_rows_handles_table_with_embedded_quote() {
    let dir = TempDir::new().unwrap();
    let path = dir.path().join("hostile.db");
    let driver = SqliteDriver;
    let conn = driver.connect(opts_for(path.to_str().unwrap())).await.unwrap();
    conn.execute("CREATE TABLE \"weird\"\"name\" (i INTEGER)")
        .await
        .unwrap();
    conn.execute("INSERT INTO \"weird\"\"name\" VALUES (1), (2)")
        .await
        .unwrap();
    let result = conn.fetch_rows(None, "weird\"name", 0, 100).await.unwrap();
    assert_eq!(result.rows.len(), 2);
}

#[tokio::test]
async fn autoincrement_detected_via_sqlite_sequence() {
    let dir = TempDir::new().unwrap();
    let path = dir.path().join("ai.db");
    let driver = SqliteDriver;
    let conn = driver.connect(opts_for(path.to_str().unwrap())).await.unwrap();
    conn.execute("CREATE TABLE t (id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT)")
        .await
        .unwrap();
    conn.execute("INSERT INTO t (name) VALUES ('a')").await.unwrap();
    let cols = conn.fetch_columns(None, "t").await.unwrap();
    assert!(cols[0].is_auto_increment, "AUTOINCREMENT id should be flagged");
    assert!(!cols[1].is_auto_increment, "name column should not be flagged");
}

#[tokio::test]
async fn integer_primary_key_no_autoincrement_is_rowid_alias() {
    let dir = TempDir::new().unwrap();
    let path = dir.path().join("rowid.db");
    let driver = SqliteDriver;
    let conn = driver.connect(opts_for(path.to_str().unwrap())).await.unwrap();
    conn.execute("CREATE TABLE t (id INTEGER PRIMARY KEY, name TEXT)")
        .await
        .unwrap();
    let cols = conn.fetch_columns(None, "t").await.unwrap();
    assert!(cols[0].is_auto_increment);
}

#[tokio::test]
async fn integer_primary_key_with_default_is_not_auto_increment() {
    let dir = TempDir::new().unwrap();
    let path = dir.path().join("def.db");
    let driver = SqliteDriver;
    let conn = driver.connect(opts_for(path.to_str().unwrap())).await.unwrap();
    conn.execute("CREATE TABLE t (id INTEGER PRIMARY KEY DEFAULT 0, name TEXT)")
        .await
        .unwrap();
    let cols = conn.fetch_columns(None, "t").await.unwrap();
    assert!(!cols[0].is_auto_increment);
}

#[tokio::test]
async fn composite_primary_key_no_auto_increment() {
    let dir = TempDir::new().unwrap();
    let path = dir.path().join("composite.db");
    let driver = SqliteDriver;
    let conn = driver.connect(opts_for(path.to_str().unwrap())).await.unwrap();
    conn.execute("CREATE TABLE t (a INTEGER, b TEXT, PRIMARY KEY(a, b))")
        .await
        .unwrap();
    let cols = conn.fetch_columns(None, "t").await.unwrap();
    assert!(!cols[0].is_auto_increment);
    assert!(!cols[1].is_auto_increment);
}

#[tokio::test]
async fn column_named_autoincrement_substring_is_not_flagged() {
    let dir = TempDir::new().unwrap();
    let path = dir.path().join("substr.db");
    let driver = SqliteDriver;
    let conn = driver.connect(opts_for(path.to_str().unwrap())).await.unwrap();
    conn.execute("CREATE TABLE t (id INTEGER PRIMARY KEY, autoincrementflag INTEGER)")
        .await
        .unwrap();
    let cols = conn.fetch_columns(None, "t").await.unwrap();
    assert!(cols[0].is_auto_increment, "id is INTEGER PRIMARY KEY (rowid alias)");
    assert!(!cols[1].is_auto_increment, "non-PK INTEGER must not be flagged");
}
include!("../tests/support/pragma_shadow_tests.rs");
