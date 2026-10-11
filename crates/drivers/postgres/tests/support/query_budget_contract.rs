use super::*;

#[tokio::test]
#[ignore = "requires docker"]
async fn a_query_truncated_at_the_shared_byte_budget_preserves_order_and_pool_reuse() {
    let (_container, opts) = super::start_pg().await;
    let observer = super::connect(opts.clone()).await;
    let connection = super::connect(opts).await;
    let payload = "x".repeat(4 * 1024);
    let started = std::time::Instant::now();
    let result = connection
        .query(&format!(
            "SELECT i, repeat('x', {}) AS payload \
             FROM generate_series(1, 20000) AS t(i) ORDER BY i /* bookie_pg_byte_cap */",
            payload.len()
        ))
        .await
        .expect("bounded query returns its admitted rows");

    assert!(result.truncated, "omitted server rows must be reported");
    assert!(!result.rows.is_empty());
    assert!(result.rows.len() < 20_000);
    assert!(result.rows.len() * payload.len() <= tablepro_core::MAX_QUERY_RESULT_BYTES);
    assert!(result.rows.iter().enumerate().all(|(index, row)| {
        row.first() == Some(&Value::Int(index as i64 + 1))
            && matches!(row.get(1), Some(Value::Text(value)) if value == &payload)
    }));
    super::assert_capped_and_server_stopped(
        observer.as_ref(),
        super::QueryResultProbe {
            truncated: result.truncated,
            rows: result.rows.len(),
            elapsed: started.elapsed(),
        },
        "bookie_pg_byte_cap",
    )
    .await;

    let next = connection
        .query("SELECT 42::bigint AS usable")
        .await
        .expect("pool connection is reusable after truncation");
    assert_eq!(next.rows, vec![vec![Value::Int(42)]]);
}

#[tokio::test]
#[ignore = "requires docker"]
async fn a_byte_capped_query_aborts_its_transaction_until_rollback_then_reuses_the_connection() {
    let (_container, opts) = super::start_pg().await;
    let observer = super::connect(opts.clone()).await;
    let connection = super::connect(opts).await;
    let mut transaction = connection.begin().await.expect("begin transaction");
    let sql = "SELECT repeat('x', 1048576) FROM (SELECT generate_series(1, 4000000000) AS i) AS g /* bookie_pg_transaction_byte_cap */";
    let started = std::time::Instant::now();
    let result = transaction
        .query(sql)
        .await
        .expect("capped query returns admitted rows");
    assert!(result.truncated);
    assert!(result.rows.len() < 100);
    super::assert_capped_and_server_stopped(
        observer.as_ref(),
        super::QueryResultProbe {
            truncated: result.truncated,
            rows: result.rows.len(),
            elapsed: started.elapsed(),
        },
        "bookie_pg_transaction_byte_cap",
    )
    .await;

    let aborted = transaction
        .query("SELECT 42")
        .await
        .expect_err("cancelled statement aborts the PostgreSQL transaction");
    assert!(matches!(aborted, tablepro_core::DriverError::Query { sqlstate: Some(code), .. } if code == "25P02"));
    transaction.rollback().await.expect("rollback aborted transaction");
    let next = connection
        .query("SELECT 42::bigint")
        .await
        .expect("pooled connection recovers after rollback");
    assert_eq!(next.rows, vec![vec![Value::Int(42)]]);
}
