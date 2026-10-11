#![allow(clippy::unwrap_used, clippy::expect_used, clippy::panic)]

use crate::{connect, start_pg};

#[tokio::test]
#[ignore = "requires docker"]
async fn list_databases_returns_connectable_user_databases_only() {
    let (_c, opts) = start_pg().await;
    let conn = connect(opts).await;
    conn.execute("CREATE DATABASE alpha_db").await.unwrap();

    let names = conn.list_databases().await.unwrap();

    assert_eq!(
        names,
        vec!["alpha_db".to_string(), "postgres".to_string(), "test".to_string()]
    );
}

#[tokio::test]
#[ignore = "requires docker"]
async fn a_failed_statement_reports_the_character_position_of_the_error() {
    let (_c, opts) = start_pg().await;
    let conn = connect(opts).await;

    let error = conn.query("SELECT 'é', * FROM missing_table").await.unwrap_err();

    let tablepro_core::DriverError::Query { sqlstate, position, .. } = error else {
        panic!("expected a query error, got {error:?}")
    };
    assert_eq!(sqlstate.as_deref(), Some("42P01"));
    assert_eq!(position, Some(20));
}
