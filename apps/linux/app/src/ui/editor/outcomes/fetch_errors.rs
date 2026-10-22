use super::*;

async fn fetch_failure(
    sql: &str,
    parameters: &std::collections::HashMap<String, tablepro_core::Value>,
) -> super::super::super::StatementFailure {
    let error = tablepro_core::DriverError::Query {
        message: "division by zero".into(),
        sqlstate: Some("22012".into()),
        position: Some(8),
    };
    let result = run_statements_with_stream(
        StatementRun {
            target: cursor_target(vec![Err(error)], std::sync::Arc::new(CursorCounters::default())),
            statements: vec![sql.into()],
            driver_id: "postgres",
            parameter_values: parameters,
            control: &crate::services::operation_control::bounded(30),
            error_policy: BatchErrorPolicy::StopScript,
            settings_check: None,
            succeeded: |_: &str| {},
        },
        |_| async { true },
    )
    .await;
    match result {
        ScriptRunResult::Streamed(StreamTerminal::Failed(message)) => message,
        _ => panic!("the fetch failure ends the stream"),
    }
}

#[tokio::test]
async fn a_fetch_error_is_located_only_when_the_sent_sql_is_the_written_sql() {
    let plain = fetch_failure("SELECT 1 / id FROM items", &Default::default()).await;
    assert!(plain.contains("Line 1, column 8"), "{plain}");
    assert_eq!(plain.position, Some(8));

    let parameters = [("id".to_string(), tablepro_core::Value::Int(1))].into();
    let bound = fetch_failure("SELECT 1 / id FROM items WHERE id = :id", &parameters).await;
    assert!(bound.contains("division by zero"), "{bound}");
    assert!(!bound.contains("Line "), "{bound}");
    assert_eq!(bound.position, None);
}

#[test]
fn only_reads_the_cursor_guard_accepts_and_known_functions_are_streamed() {
    assert!(super::super::stream_candidate(
        "SELECT id, lower(name) FROM items",
        "postgres"
    ));
    for sql in [
        "SELECT archive_rows()",
        "SELECT set_config('search_path', 'x', false)",
        "SELECT * FROM items FOR UPDATE",
        "SELECT 1; SELECT 2",
    ] {
        assert!(!super::super::stream_candidate(sql, "postgres"), "{sql}");
        assert!(
            !super::super::stream_candidate(sql, "postgres")
                || tablepro_policy::classify(sql, "postgres").is_single_read(),
            "{sql}"
        );
    }
    assert!(!super::super::stream_candidate("SELECT id FROM items", "mysql"));
}
