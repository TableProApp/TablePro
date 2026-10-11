#![allow(clippy::unwrap_used, clippy::expect_used, clippy::panic)]
use std::sync::Arc;

use tablepro_core::{Connection, DriverError, Value};
use tablepro_release_tests::{Fixture, guard};

async fn scalar_int(connection: &dyn Connection, sql: &str) -> i64 {
    let result = connection.query(sql).await.expect("scalar query");
    match result.rows.first().and_then(|row| row.first()) {
        Some(Value::Int(value)) => *value,
        other => panic!("expected an integer scalar, got {other:?}"),
    }
}

#[tokio::test]
#[ignore = "requires the postgres release fixture"]
async fn read_only_denies_a_data_changing_cte_and_leaves_rows_in_place() {
    let fixture = Fixture::from_env();
    let raw: Arc<dyn Connection> = fixture.connect_verified().await.into();
    let harness = guard(raw.clone(), true);

    let error = harness
        .guard
        .query(
            "WITH removed AS (DELETE FROM release_items WHERE id = 1 RETURNING id) \
             SELECT id FROM removed",
        )
        .await
        .expect_err("a read-only connection must deny a data-changing CTE");
    assert!(
        matches!(error, DriverError::PolicyDenied(_) | DriverError::ReadOnly),
        "expected a policy denial, got {error}"
    );

    assert_eq!(
        scalar_int(raw.as_ref(), "SELECT count(*) FROM release_items WHERE id = 1").await,
        1
    );
}

#[tokio::test]
#[ignore = "requires the postgres release fixture"]
async fn read_only_denies_an_administrative_function() {
    let fixture = Fixture::from_env();
    let raw: Arc<dyn Connection> = fixture.connect_verified().await.into();
    let harness = guard(raw, true);

    let error = harness
        .guard
        .query("SELECT pg_terminate_backend(pg_backend_pid())")
        .await
        .expect_err("a read-only connection must deny administrative functions");
    assert!(
        matches!(error, DriverError::PolicyDenied(_) | DriverError::ReadOnly),
        "expected a policy denial, got {error}"
    );
}

#[tokio::test]
#[ignore = "requires the postgres release fixture"]
async fn batch_rollback_discards_every_statement_after_a_failure() {
    let fixture = Fixture::from_env();
    let raw: Arc<dyn Connection> = fixture.connect_verified().await.into();
    let table = "release_batch_rollback";
    raw.execute(&format!("DROP TABLE IF EXISTS {table}"))
        .await
        .expect("drop batch table");
    raw.execute(&format!("CREATE TABLE {table} (id integer PRIMARY KEY)"))
        .await
        .expect("create batch table");

    let harness = guard(raw.clone(), false);
    let statements = vec![
        (format!("INSERT INTO {table} (id) VALUES ($1)"), vec![Value::Int(1)]),
        (format!("INSERT INTO {table} (id) VALUES ($1)"), vec![Value::Int(1)]),
    ];

    let error = harness
        .guard
        .execute_in_transaction(&statements)
        .await
        .expect_err("a duplicate primary key must fail the batch");
    assert!(
        !matches!(error, DriverError::PolicyDenied(_)),
        "the batch must reach the database, got {error}"
    );

    assert_eq!(
        scalar_int(raw.as_ref(), &format!("SELECT count(*) FROM {table}")).await,
        0
    );
    raw.execute(&format!("DROP TABLE {table}"))
        .await
        .expect("drop batch table");
}

#[tokio::test]
#[ignore = "requires the postgres release fixture"]
async fn interactive_rollback_discards_uncommitted_writes() {
    let fixture = Fixture::from_env();
    let raw: Arc<dyn Connection> = fixture.connect_verified().await.into();
    let table = "release_interactive_rollback";
    raw.execute(&format!("DROP TABLE IF EXISTS {table}"))
        .await
        .expect("drop interactive table");
    raw.execute(&format!("CREATE TABLE {table} (id integer PRIMARY KEY)"))
        .await
        .expect("create interactive table");

    let mut transaction = raw.begin().await.expect("begin interactive transaction");
    transaction
        .execute(&format!("INSERT INTO {table} (id) VALUES (1)"))
        .await
        .expect("insert inside the transaction");
    transaction.rollback().await.expect("rollback");

    assert_eq!(
        scalar_int(raw.as_ref(), &format!("SELECT count(*) FROM {table}")).await,
        0
    );
    raw.execute(&format!("DROP TABLE {table}"))
        .await
        .expect("drop interactive table");
}
