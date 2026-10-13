use super::*;

pub(super) async fn assert_failed_batch_preserves_rows(
    conn: &dyn Connection,
    batch: &[(String, Vec<Value>)],
    parent_query: &str,
    expected_parent_rows: Vec<Vec<Value>>,
    effect_query: &str,
    expected_effect_rows: Vec<Vec<Value>>,
) {
    let error = conn
        .execute_in_transaction(batch)
        .await
        .expect_err("the second statement must fail");
    assert!(
        matches!(error, DriverError::Transaction { statement_index: 1, .. }),
        "the second statement must be reported as the failure, got {error:?}"
    );
    assert_eq!(
        conn.query(parent_query).await.unwrap().rows,
        expected_parent_rows,
        "the transactional row must be rolled back"
    );
    assert_eq!(
        conn.query(effect_query).await.unwrap().rows,
        expected_effect_rows,
        "the non-transactional trigger effect must survive exactly once"
    );
}
