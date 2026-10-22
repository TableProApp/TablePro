#![allow(clippy::unwrap_used, clippy::expect_used, clippy::panic)]
use std::sync::Arc;

use drivers_sqlite::SqliteDriver;
use tablepro_core::{ConnectOptions, Connection, DatabaseDriver, Value};

async fn seeded() -> Arc<dyn Connection> {
    let connection: Arc<dyn Connection> = SqliteDriver
        .connect(ConnectOptions {
            database: ":memory:".into(),
            ..Default::default()
        })
        .await
        .expect("connect")
        .into();
    for sql in [
        "CREATE TABLE customers (id INTEGER PRIMARY KEY)",
        "CREATE TABLE orders (id INTEGER PRIMARY KEY, customer_id INTEGER REFERENCES customers(id) ON DELETE CASCADE)",
        "INSERT INTO customers VALUES (1)",
        "INSERT INTO orders VALUES (10, 1)",
    ] {
        connection.execute(sql).await.unwrap();
    }
    connection
}

async fn order_count(connection: &dyn Connection) -> Value {
    connection.query("SELECT COUNT(*) FROM orders").await.unwrap().rows[0][0].clone()
}

#[tokio::test]
async fn dropping_a_referenced_parent_is_refused_and_keeps_the_child_rows() {
    let connection = seeded().await;

    let error = connection.execute("DROP TABLE IF EXISTS customers").await.unwrap_err();

    assert!(error.to_string().contains("orders"), "{error}");
    assert_eq!(order_count(&*connection).await, Value::Int(1));
    connection.query("SELECT * FROM customers").await.unwrap();
}

#[tokio::test]
async fn every_execution_path_refuses_the_drop() {
    let connection = seeded().await;
    let control = tablepro_core::OperationControl::with_timeout(std::time::Duration::from_secs(30));

    assert!(connection.execute_params("DROP TABLE customers", &[]).await.is_err());
    assert!(
        connection
            .execute_controlled("DROP TABLE customers", &control)
            .await
            .is_err()
    );
    assert!(connection.query("DROP TABLE customers").await.is_err());
    assert_eq!(order_count(&*connection).await, Value::Int(1));
}

#[tokio::test]
async fn dropping_the_child_or_an_unreferenced_table_still_works() {
    let connection = seeded().await;

    connection.execute("DROP TABLE orders").await.unwrap();
    connection.execute("DROP TABLE customers").await.unwrap();
}

#[tokio::test]
async fn a_table_that_only_references_itself_can_be_dropped() {
    let connection = seeded().await;
    connection
        .execute("CREATE TABLE tree (id INTEGER PRIMARY KEY, parent INTEGER REFERENCES tree(id))")
        .await
        .unwrap();

    connection.execute("DROP TABLE tree").await.unwrap();
}

#[tokio::test]
async fn dropping_a_referenced_parent_in_an_attached_database_is_refused() {
    let directory = tempfile::TempDir::new().expect("temp dir");
    let main = directory.path().join("main.db").to_string_lossy().to_string();
    let attached = directory.path().join("aux.db").to_string_lossy().to_string();
    let connection = SqliteDriver
        .connect(ConnectOptions {
            database: main,
            ..Default::default()
        })
        .await
        .expect("connect");
    let mut session = connection.open_session().await.expect("session");
    let control = tablepro_core::OperationControl::with_timeout(std::time::Duration::from_secs(30));
    for sql in [
        format!("ATTACH DATABASE '{attached}' AS aux"),
        "CREATE TABLE aux.customers (id INTEGER PRIMARY KEY)".into(),
        "CREATE TABLE aux.orders (id INTEGER PRIMARY KEY, customer_id INTEGER REFERENCES customers(id) ON DELETE CASCADE)"
            .into(),
        "INSERT INTO aux.customers VALUES (1)".into(),
        "INSERT INTO aux.orders VALUES (10, 1)".into(),
    ] {
        session.query_params_controlled(&sql, &[], &control).await.unwrap();
    }

    let error = session
        .query_params_controlled("DROP TABLE aux.customers", &[], &control)
        .await
        .unwrap_err();

    assert!(error.to_string().contains("orders"), "{error}");
    let unqualified = session
        .query_params_controlled("DROP TABLE customers", &[], &control)
        .await
        .unwrap_err();
    assert!(unqualified.to_string().contains("orders"), "{unqualified}");
    session
        .query_params_controlled("DROP TABLE IF EXISTS missing.customers", &[], &control)
        .await
        .unwrap();
    let count = session
        .query_params_controlled("SELECT COUNT(*) FROM aux.orders", &[], &control)
        .await
        .unwrap();
    assert_eq!(count.rows[0][0], Value::Int(1));
}
