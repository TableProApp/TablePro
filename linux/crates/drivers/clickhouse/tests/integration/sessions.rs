//! Editor sessions: state kept between runs, stops that reach the
//! server, and row limits that stop the read there too.

use std::time::Duration;

use async_trait::async_trait;
use tablepro_core::{
    Connection, DriverError, ReadStatement, ResultEvent, ResultSink, RowLimit, RunEnd, RunOptions, SinkFlow,
    Truncation, UserSql, Value,
};
use tokio::time::Instant;
use tokio_util::sync::CancellationToken;

use crate::support::{
    CALL, connect, count, flush_logs, run, run_ok, run_with, scalar, session, start, text, unique, within,
};

/// A result that holds no line break, so one read as lines is one line
/// that never ends.
fn row_binary(marker: &str) -> String {
    format!("SELECT '{marker}' FROM numbers(10000000000) FORMAT RowBinary")
}

async fn wait_until_gone(connection: &dyn Connection, marker: &str) {
    let running = format!(
        "SELECT count() FROM system.processes WHERE query LIKE '%{marker}%' \
         AND query NOT LIKE '%system.processes%'"
    );
    let give_up = Instant::now() + Duration::from_secs(10);
    while count(connection, &running).await > 0 {
        assert!(Instant::now() < give_up, "the statement is still running");
        tokio::time::sleep(Duration::from_millis(100)).await;
    }
}

struct Discard;

#[async_trait]
impl ResultSink for Discard {
    async fn accept(&mut self, _event: ResultEvent) -> SinkFlow {
        SinkFlow::Continue
    }
}

#[tokio::test]
#[ignore = "requires docker"]
async fn set_and_temporary_table_persist() {
    let fixture = start().await;
    let connection = connect(&fixture, false).await;
    let editor = session(connection.as_ref()).await;

    run_ok(editor.as_ref(), "SET max_threads = 3").await;
    run_ok(editor.as_ref(), "CREATE TEMPORARY TABLE scratch (x UInt8)").await;
    run_ok(editor.as_ref(), "INSERT INTO scratch VALUES (7)").await;
    let setting = run_ok(editor.as_ref(), "SELECT getSetting('max_threads')").await;
    let rows = run_ok(editor.as_ref(), "SELECT x FROM scratch").await;

    assert_eq!(setting.rows(), vec![vec![Value::Int(3)]]);
    assert_eq!(rows.rows(), vec![vec![Value::Int(7)]]);
    editor.close().await;
    connection.close().await.expect("a close");
}

#[tokio::test]
#[ignore = "requires docker"]
async fn sleep_each_row_cancel_gone_from_processes() {
    let fixture = start().await;
    let connection = connect(&fixture, false).await;
    let editor = session(connection.as_ref()).await;
    let marker = unique("cancel");
    let cancel = CancellationToken::new();
    let sql = format!("SELECT sleepEachRow(0.2), '{marker}' FROM numbers(1000) SETTINGS max_block_size = 1");

    let running = run_with(editor.as_ref(), &sql, RunOptions::new(cancel.clone()));
    let cancelling = async {
        tokio::time::sleep(Duration::from_millis(500)).await;
        cancel.cancel();
    };
    let ((summary, _), ()) = tokio::join!(running, cancelling);

    assert_eq!(summary.end, RunEnd::Cancelled);
    let still = count(
        connection.as_ref(),
        &format!(
            "SELECT count() FROM system.processes WHERE query LIKE '%{marker}%' \
             AND query NOT LIKE '%system.processes%'"
        ),
    )
    .await;
    assert_eq!(still, 0, "the cancelled statement is still running");
    run_ok(editor.as_ref(), "SELECT 1").await;
    editor.close().await;
    connection.close().await.expect("a close");
}

#[tokio::test]
#[ignore = "requires docker"]
async fn numbers_1e9_limit_100_server_stopped_read_rows_far_below() {
    let fixture = start().await;
    let connection = connect(&fixture, false).await;
    let editor = session(connection.as_ref()).await;
    let marker = unique("limit");
    let limit = RowLimit::new(100).expect("a limit");
    let sql = format!("SELECT number, '{marker}' FROM numbers(1000000000)");

    let (summary, events) = run_with(
        editor.as_ref(),
        &sql,
        RunOptions::new(CancellationToken::new()).with_row_limit(limit),
    )
    .await;

    assert_eq!(summary.end, RunEnd::Completed);
    assert_eq!(events.rows().len(), 100);
    assert!(
        events.all().contains(&ResultEvent::RowLimitReached { retained: 100 }),
        "{:?}",
        events.finished()
    );
    assert!(matches!(
        events.finished().as_slice(),
        [ResultEvent::ResultSetFinished {
            retained: 100,
            truncation: Truncation::ReadPastLimit,
            ..
        }]
    ));
    flush_logs(connection.as_ref()).await;
    let read_rows = scalar(
        connection.as_ref(),
        &format!(
            "SELECT max(read_rows) FROM system.query_log WHERE query LIKE '%{marker}%' \
             AND query NOT LIKE '%query_log%' AND type != 'QueryStart'"
        ),
    )
    .await
    .as_exact_u64()
    .expect("a row count");
    assert!(
        read_rows < 100_000_000,
        "the server read {read_rows} rows for a limit of 100"
    );
    editor.close().await;
    connection.close().await.expect("a close");
}

#[tokio::test]
#[ignore = "requires docker"]
async fn query_log_http_user_agent_contains_tablepro() {
    let fixture = start().await;
    let connection = connect(&fixture, false).await;
    let editor = session(connection.as_ref()).await;
    let marker = unique("agent");

    run_ok(editor.as_ref(), &format!("SELECT '{marker}'")).await;
    flush_logs(connection.as_ref()).await;
    let agent = scalar(
        connection.as_ref(),
        &format!(
            "SELECT any(http_user_agent) FROM system.query_log WHERE query LIKE '%{marker}%' \
             AND query NOT LIKE '%query_log%'"
        ),
    )
    .await;

    assert!(text(&agent).contains("TablePro/test"), "{agent:?}");
    editor.close().await;
    connection.close().await.expect("a close");
}

#[tokio::test]
#[ignore = "requires docker"]
async fn a_question_mark_in_editor_sql_is_data() {
    let fixture = start().await;
    let connection = connect(&fixture, false).await;
    let editor = session(connection.as_ref()).await;

    let (summary, events) = run(editor.as_ref(), "SELECT 'what?', '??', '?fields'").await;

    assert_eq!(summary.end, RunEnd::Completed);
    assert_eq!(
        events.rows(),
        vec![vec![
            Value::Text("what?".to_owned()),
            Value::Text("??".to_owned()),
            Value::Text("?fields".to_owned())
        ]]
    );
    editor.close().await;
    connection.close().await.expect("a close");
}

#[tokio::test]
#[ignore = "requires docker"]
async fn a_format_clause_fails_the_run_instead_of_filling_memory() {
    let fixture = start().await;
    let connection = connect(&fixture, false).await;
    let editor = session(connection.as_ref()).await;
    let marker = unique("format");

    let (summary, _) = tokio::time::timeout(Duration::from_secs(60), run(editor.as_ref(), &row_binary(&marker)))
        .await
        .expect("the run ended");

    assert!(
        matches!(&summary.end, RunEnd::Failed(DriverError::Protocol(message)) if message.contains("FORMAT")),
        "{:?}",
        summary.end
    );
    wait_until_gone(connection.as_ref(), &marker).await;
    run_ok(editor.as_ref(), "SELECT 1").await;
    editor.close().await;
    connection.close().await.expect("a close");
}

#[tokio::test]
#[ignore = "requires docker"]
async fn a_format_clause_fails_an_export_instead_of_filling_memory() {
    let fixture = start().await;
    let connection = connect(&fixture, false).await;
    let marker = unique("export");
    let read = ReadStatement::User(UserSql::new(row_binary(&marker)));

    let outcome = tokio::time::timeout(
        Duration::from_secs(60),
        connection.stream_read(&read, Box::new(Discard), within(CALL)),
    )
    .await
    .expect("the export ended");

    assert!(
        matches!(&outcome, Err(DriverError::Protocol(message)) if message.contains("FORMAT")),
        "{outcome:?}"
    );
    wait_until_gone(connection.as_ref(), &marker).await;
    connection.close().await.expect("a close");
}
