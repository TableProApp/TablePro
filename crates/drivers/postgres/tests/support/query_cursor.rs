use super::{connect, no_timeout, start_pg};
use tablepro_core::{DriverError, OperationControl, Value};
use tokio_util::sync::CancellationToken;

#[tokio::test]
#[ignore = "requires docker"]
async fn query_cursor_requires_an_open_transaction() {
    let (_container, options) = start_pg().await;
    let connection = connect(options).await;
    let mut session = connection.open_session().await.unwrap();
    let result = session
        .open_query_cursor_controlled("SELECT 1", &[], &no_timeout())
        .await;

    assert!(
        matches!(&result, Err(DriverError::Query { sqlstate: Some(code), .. }) if code == "25P01"),
        "{result:?}"
    );
    assert!(session.is_usable());
    session
        .query_params_controlled("BEGIN READ ONLY ISOLATION LEVEL REPEATABLE READ", &[], &no_timeout())
        .await
        .unwrap();
    let cursor = session
        .open_query_cursor_controlled("SELECT 1", &[], &no_timeout())
        .await
        .unwrap();
    let page = session
        .fetch_query_cursor_page_controlled(cursor, &no_timeout())
        .await
        .unwrap();
    assert_eq!(page.result.rows.len(), 1);
    session
        .close_query_cursor_controlled(cursor, &no_timeout())
        .await
        .unwrap();
    session
        .query_params_controlled("ROLLBACK", &[], &no_timeout())
        .await
        .unwrap();
    session.close().await.unwrap();
}

#[tokio::test]
#[ignore = "requires docker"]
async fn query_cursor_returns_ordered_pages_and_an_empty_final_page() {
    let (_container, options) = start_pg().await;
    let connection = connect(options).await;
    let mut session = connection.open_session().await.unwrap();
    session
        .query_params_controlled("BEGIN READ ONLY ISOLATION LEVEL REPEATABLE READ", &[], &no_timeout())
        .await
        .unwrap();
    let cursor = session
        .open_query_cursor_controlled(
            "SELECT value + $1::bigint, value % 2 = 0, \
             CASE WHEN value = 5001 THEN NULL::text ELSE value::text END, \
             jsonb_build_object('n', value), decode('00ff', 'hex') \
             FROM generate_series(1, 10000) AS generated(value) ORDER BY generated.value",
            &[Value::Int(9)],
            &no_timeout(),
        )
        .await
        .unwrap();

    let mut rows = Vec::new();
    for expected_has_next in [true, true, false] {
        let page = session
            .fetch_query_cursor_page_controlled(cursor, &no_timeout())
            .await
            .unwrap();
        assert_eq!(page.has_next_page, expected_has_next);
        assert!(!page.result.truncated);
        assert_eq!(page.result.columns.len(), 5);
        let row_count = page.result.rows.len();
        rows.extend(page.result.rows);
        if expected_has_next {
            assert_eq!(row_count, 5_000);
        } else {
            assert_eq!(row_count, 0);
        }
    }

    assert_eq!(rows.len(), 10_000);
    for (index, row) in rows.iter().enumerate() {
        let source = index as i64 + 1;
        let expected = vec![
            Value::Int(source + 9),
            Value::Bool(source % 2 == 0),
            if source == 5_001 {
                Value::Null
            } else {
                Value::Text(source.to_string())
            },
            Value::Json(serde_json::json!({"n": source})),
            Value::Bytes(vec![0, 255]),
        ];
        assert_eq!(row, &expected, "row index {index}");
    }
    session
        .close_query_cursor_controlled(cursor, &no_timeout())
        .await
        .unwrap();
    session
        .query_params_controlled("ROLLBACK", &[], &no_timeout())
        .await
        .unwrap();
    assert!(session.is_usable());
    session.close().await.unwrap();
}

#[tokio::test]
#[ignore = "requires docker"]
async fn query_cursor_preserves_metadata_for_an_empty_result() {
    let (_container, options) = start_pg().await;
    let connection = connect(options).await;
    let mut session = connection.open_session().await.unwrap();
    session
        .query_params_controlled("BEGIN READ ONLY ISOLATION LEVEL REPEATABLE READ", &[], &no_timeout())
        .await
        .unwrap();
    let cursor = session
        .open_query_cursor_controlled("SELECT 1::bigint AS value WHERE false", &[], &no_timeout())
        .await
        .unwrap();

    let page = session
        .fetch_query_cursor_page_controlled(cursor, &no_timeout())
        .await
        .unwrap();
    assert!(!page.has_next_page);
    assert!(!page.result.truncated);
    assert!(page.result.rows.is_empty());
    assert_eq!(page.result.columns.len(), 1);
    assert_eq!(page.result.columns[0].name, "value");

    session
        .close_query_cursor_controlled(cursor, &no_timeout())
        .await
        .unwrap();
    session
        .query_params_controlled("ROLLBACK", &[], &no_timeout())
        .await
        .unwrap();
    session.close().await.unwrap();
}

#[tokio::test]
#[ignore = "requires docker"]
async fn query_cursor_preserves_prior_pages_when_a_later_fetch_errors() {
    let (_container, options) = start_pg().await;
    let connection = connect(options).await;
    connection
        .execute(
            "CREATE FUNCTION cursor_fail_after_page(value integer) RETURNS integer AS $$\
             BEGIN IF value = 5001 THEN RAISE EXCEPTION 'cursor fetch failure'; END IF; \
             RETURN value; END; $$ LANGUAGE plpgsql",
        )
        .await
        .unwrap();
    let mut session = connection.open_session().await.unwrap();
    session
        .query_params_controlled("BEGIN READ ONLY ISOLATION LEVEL REPEATABLE READ", &[], &no_timeout())
        .await
        .unwrap();
    let cursor = session
        .open_query_cursor_controlled(
            "SELECT cursor_fail_after_page(value)::bigint FROM generate_series(1, 5001) AS generated(value)",
            &[],
            &no_timeout(),
        )
        .await
        .unwrap();
    let first = session
        .fetch_query_cursor_page_controlled(cursor, &no_timeout())
        .await
        .unwrap();
    assert_eq!(first.result.rows.len(), 5_000);
    assert!(first.has_next_page);

    let later = session.fetch_query_cursor_page_controlled(cursor, &no_timeout()).await;
    assert!(matches!(later, Err(DriverError::Query { .. })), "{later:?}");
    assert!(session.is_usable(), "a statement error keeps the session");
    session
        .close_query_cursor_controlled(cursor, &no_timeout())
        .await
        .expect("closing a failed cursor sends nothing");
    session
        .query_params_controlled("ROLLBACK", &[], &no_timeout())
        .await
        .unwrap();
    let after = session
        .query_params_controlled("SELECT 1::bigint", &[], &no_timeout())
        .await
        .unwrap();
    assert_eq!(after.rows, vec![vec![Value::Int(1)]]);
    session.close().await.unwrap();
}

#[tokio::test]
#[ignore = "requires docker"]
async fn a_rollback_after_a_failed_fetch_needs_no_explicit_cursor_close() {
    let (_container, options) = start_pg().await;
    let connection = connect(options).await;
    let mut session = connection.open_session().await.unwrap();
    session
        .query_params_controlled("BEGIN READ ONLY ISOLATION LEVEL REPEATABLE READ", &[], &no_timeout())
        .await
        .unwrap();
    let cursor = session
        .open_query_cursor_controlled(
            "SELECT 1 / (value - 3) FROM generate_series(1, 5) AS g(value)",
            &[],
            &no_timeout(),
        )
        .await
        .unwrap();
    let failed = session.fetch_query_cursor_page_controlled(cursor, &no_timeout()).await;
    assert!(matches!(failed, Err(DriverError::Query { .. })), "{failed:?}");

    session
        .query_params_controlled("ROLLBACK", &[], &no_timeout())
        .await
        .expect("the editor's rollback runs without closing the failed cursor first");
    let after = session
        .query_params_controlled("SELECT 1::bigint", &[], &no_timeout())
        .await
        .unwrap();
    assert_eq!(after.rows, vec![vec![Value::Int(1)]]);
    session.close().await.unwrap();
}

#[tokio::test]
#[ignore = "requires docker"]
async fn a_cursor_query_with_a_typo_keeps_the_session_and_its_temp_tables() {
    let (_container, options) = start_pg().await;
    let connection = connect(options).await;
    let mut session = connection.open_session().await.unwrap();
    session
        .query_params_controlled("CREATE TEMP TABLE kept (x int)", &[], &no_timeout())
        .await
        .unwrap();
    session
        .query_params_controlled("BEGIN READ ONLY ISOLATION LEVEL REPEATABLE READ", &[], &no_timeout())
        .await
        .unwrap();

    let opened = session
        .open_query_cursor_controlled("SELECT nope FROM kept", &[], &no_timeout())
        .await;

    assert!(matches!(opened, Err(DriverError::Query { .. })), "{opened:?}");
    assert!(session.is_usable());
    session
        .query_params_controlled("ROLLBACK", &[], &no_timeout())
        .await
        .unwrap();
    let count = session
        .query_params_controlled("SELECT count(*)::bigint FROM kept", &[], &no_timeout())
        .await
        .unwrap();
    assert_eq!(count.rows, vec![vec![Value::Int(0)]]);
    session.close().await.unwrap();
}

#[tokio::test]
#[ignore = "requires docker"]
async fn cancelling_a_query_cursor_fetch_retires_the_session() {
    let (_container, options) = start_pg().await;
    let connection = connect(options).await;
    connection
        .execute(
            "CREATE FUNCTION cursor_sleep(value integer) RETURNS bigint AS $$\
             BEGIN PERFORM pg_sleep(0.001); RETURN value; END; $$ LANGUAGE plpgsql",
        )
        .await
        .unwrap();
    let mut session = connection.open_session().await.unwrap();
    session
        .query_params_controlled("BEGIN READ ONLY ISOLATION LEVEL REPEATABLE READ", &[], &no_timeout())
        .await
        .unwrap();
    let cursor = session
        .open_query_cursor_controlled(
            "SELECT cursor_sleep(value) FROM generate_series(1, 5000) AS generated(value) ORDER BY value",
            &[],
            &no_timeout(),
        )
        .await
        .unwrap();
    let token = CancellationToken::new();
    let control = OperationControl::new(token.clone(), None);
    let result = {
        let fetch = session.fetch_query_cursor_page_controlled(cursor, &control);
        tokio::pin!(fetch);
        tokio::select! {
            result = &mut fetch => panic!("cursor fetch completed before cancellation: {result:?}"),
            _ = tokio::time::sleep(std::time::Duration::from_millis(100)) => token.cancel(),
        }
        fetch.await
    };
    assert!(matches!(result, Err(DriverError::Cancelled)), "{result:?}");
    assert!(!session.is_usable());
    session.close().await.unwrap();
}
