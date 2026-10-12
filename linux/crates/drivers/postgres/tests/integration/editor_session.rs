//! Editor sessions in psql's model: one statement per message, the
//! transaction status followed exactly, and the row limit applied by a
//! cursor that never changes what a script does.

use std::time::Duration;

use tablepro_core::{
    DriverError, EditorSessionState, ResultEvent, RowLimit, RunEnd, RunOptions, TransactionState, Truncation, Value,
};
use tokio_util::sync::CancellationToken;

use crate::support::{
    CALL, EventSink, Events, connect, run, run_ok, run_with, scalar, session, setup, start, text, within,
};

fn limited(rows: u64) -> RunOptions {
    RunOptions::new(CancellationToken::new()).with_row_limit(RowLimit::new(rows).expect("a limit"))
}

fn texts(events: &Events) -> Vec<String> {
    events.rows().iter().flatten().map(text).collect()
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
#[ignore = "requires docker"]
async fn begin_update_rollback_persists_state() {
    let fixture = start().await;
    let connection = connect(&fixture, false).await;
    setup(
        connection.as_ref(),
        &[
            "CREATE TABLE t (id int PRIMARY KEY, v text)",
            "INSERT INTO t VALUES (1, 'a')",
        ],
    )
    .await;
    let session = session(connection.as_ref()).await;

    let (begun, _) = run(session.as_ref(), "BEGIN").await;
    let (updated, _) = run(session.as_ref(), "UPDATE t SET v = 'b' WHERE id = 1").await;
    let elsewhere = scalar(connection.as_ref(), "SELECT v FROM t").await;
    let (rolled_back, _) = run(session.as_ref(), "ROLLBACK").await;

    assert_eq!(begun.transaction_state, TransactionState::InTransaction);
    assert_eq!(updated.transaction_state, TransactionState::InTransaction);
    assert_eq!(text(&elsewhere), "a", "an uncommitted update was visible elsewhere");
    assert_eq!(rolled_back.transaction_state, TransactionState::Idle);
    assert_eq!(
        session.transaction_state(within(CALL)).await,
        Ok(TransactionState::Idle)
    );
    assert_eq!(text(&scalar(connection.as_ref(), "SELECT v FROM t").await), "a");
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
#[ignore = "requires docker"]
async fn set_search_path_and_temp_table_persist() {
    let fixture = start().await;
    let connection = connect(&fixture, false).await;
    let session = session(connection.as_ref()).await;

    run_ok(session.as_ref(), "CREATE SCHEMA app; CREATE TABLE app.items (n int)").await;
    run_ok(session.as_ref(), "SET search_path TO app, public").await;
    run_ok(session.as_ref(), "CREATE TEMP TABLE scratch AS SELECT 7 AS n").await;
    let temp = run_ok(session.as_ref(), "SELECT n FROM scratch").await;
    let path = run_ok(session.as_ref(), "SHOW search_path").await;

    assert_eq!(texts(&temp), ["7"]);
    assert_eq!(texts(&path), ["app, public"]);
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
#[ignore = "requires docker"]
async fn create_function_with_dollar_body() {
    let fixture = start().await;
    let connection = connect(&fixture, false).await;
    let session = session(connection.as_ref()).await;

    let events = run_ok(
        session.as_ref(),
        "CREATE FUNCTION add_one(i int) RETURNS int AS $body$ SELECT i + 1; $body$ LANGUAGE sql;\nSELECT add_one(41)",
    )
    .await;

    assert_eq!(texts(&events), ["42"]);
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
#[ignore = "requires docker"]
async fn create_function_begin_atomic_runs_as_one_statement() {
    let fixture = start().await;
    let connection = connect(&fixture, false).await;
    let session = session(connection.as_ref()).await;

    let events = run_ok(
        session.as_ref(),
        "CREATE FUNCTION two() RETURNS int LANGUAGE sql BEGIN ATOMIC SELECT 1; SELECT 2; END;\nSELECT two()",
    )
    .await;

    assert_eq!(texts(&events), ["2"]);
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
#[ignore = "requires docker"]
async fn vacuum_after_select_in_same_script_succeeds() {
    let fixture = start().await;
    let connection = connect(&fixture, false).await;
    setup(connection.as_ref(), &["CREATE TABLE t (id int)"]).await;
    let session = session(connection.as_ref()).await;

    let (summary, _) = run(session.as_ref(), "SELECT 1; VACUUM t").await;

    assert_eq!(summary.end, RunEnd::Completed, "the cursor left a transaction open");
    assert_eq!(summary.transaction_state, TransactionState::Idle);
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
#[ignore = "requires docker"]
async fn select_inside_begin_uses_savepoint_cursor_row_limit() {
    let fixture = start().await;
    let connection = connect(&fixture, false).await;
    let session = session(connection.as_ref()).await;
    run_ok(session.as_ref(), "BEGIN").await;

    let (summary, events) = run_with(session.as_ref(), "SELECT generate_series(1, 2000000)", limited(100)).await;

    assert_eq!(summary.end, RunEnd::Completed);
    assert_eq!(events.rows().len(), 100);
    assert!(matches!(
        events.finished().as_slice(),
        [ResultEvent::ResultSetFinished {
            retained: 100,
            truncation: Truncation::ReadPastLimit,
            ..
        }]
    ));
    assert_eq!(summary.transaction_state, TransactionState::InTransaction);
    let (committed, _) = run(session.as_ref(), "COMMIT").await;
    assert_eq!(committed.end, RunEnd::Completed);
    assert_eq!(committed.transaction_state, TransactionState::Idle);
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
#[ignore = "requires docker"]
async fn delete_returning_50000_limit_100_deletes_all() {
    let fixture = start().await;
    let connection = connect(&fixture, false).await;
    setup(
        connection.as_ref(),
        &["CREATE TABLE d AS SELECT generate_series(1, 50000) AS n"],
    )
    .await;
    let session = session(connection.as_ref()).await;

    let (summary, events) = run_with(session.as_ref(), "DELETE FROM d RETURNING n", limited(100)).await;

    assert_eq!(summary.end, RunEnd::Completed);
    assert_eq!(events.rows().len(), 100);
    assert!(matches!(
        events.finished().as_slice(),
        [ResultEvent::ResultSetFinished {
            total_rows: Some(50_000),
            truncation: Truncation::ReadPastLimit,
            ..
        }]
    ));
    assert_eq!(
        scalar(connection.as_ref(), "SELECT count(*) FROM d").await,
        Value::Int(0)
    );
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
#[ignore = "requires docker"]
async fn script_insert_select_insert_both_persist() {
    let fixture = start().await;
    let connection = connect(&fixture, false).await;
    setup(connection.as_ref(), &["CREATE TABLE t (id int)"]).await;
    let session = session(connection.as_ref()).await;

    run_ok(
        session.as_ref(),
        "INSERT INTO t VALUES (1); SELECT * FROM t; INSERT INTO t VALUES (2)",
    )
    .await;

    assert_eq!(
        scalar(connection.as_ref(), "SELECT count(*) FROM t").await,
        Value::Int(2)
    );
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
#[ignore = "requires docker"]
async fn cursor_trailing_line_comment_still_fetches() {
    let fixture = start().await;
    let connection = connect(&fixture, false).await;
    let session = session(connection.as_ref()).await;

    let events = run_ok(session.as_ref(), "SELECT 41 + 1 -- the answer").await;

    assert_eq!(texts(&events), ["42"]);
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
#[ignore = "requires docker"]
async fn data_modifying_with_falls_back_0a000() {
    let fixture = start().await;
    let connection = connect(&fixture, false).await;
    setup(
        connection.as_ref(),
        &["CREATE TABLE t (id int)", "INSERT INTO t VALUES (1), (2), (3)"],
    )
    .await;
    let session = session(connection.as_ref()).await;

    let events = run_ok(
        session.as_ref(),
        "WITH gone AS (DELETE FROM t RETURNING id) SELECT count(*) FROM gone",
    )
    .await;

    assert_eq!(texts(&events), ["3"]);
    assert_eq!(
        scalar(connection.as_ref(), "SELECT count(*) FROM t").await,
        Value::Int(0)
    );
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
#[ignore = "requires docker"]
async fn select_into_inside_block_falls_back_42601_and_block_survives() {
    let fixture = start().await;
    let connection = connect(&fixture, false).await;
    let session = session(connection.as_ref()).await;
    run_ok(session.as_ref(), "BEGIN").await;

    let (selected, _) = run(session.as_ref(), "SELECT 5 AS n INTO made").await;
    let (committed, _) = run(session.as_ref(), "COMMIT").await;

    assert_eq!(selected.end, RunEnd::Completed);
    assert_eq!(selected.transaction_state, TransactionState::InTransaction);
    assert_eq!(committed.end, RunEnd::Completed);
    assert_eq!(scalar(connection.as_ref(), "SELECT n FROM made").await, Value::Int(5));
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
#[ignore = "requires docker"]
async fn copy_from_stdin_refused_before_send() {
    let fixture = start().await;
    let connection = connect(&fixture, false).await;
    setup(connection.as_ref(), &["CREATE TABLE t (id int)"]).await;
    let session = session(connection.as_ref()).await;

    let (summary, _) = run(session.as_ref(), "COPY t FROM STDIN").await;

    assert!(
        matches!(summary.end, RunEnd::Failed(DriverError::Unsupported { .. })),
        "{:?}",
        summary.end
    );
    run_ok(session.as_ref(), "SELECT 1").await;
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
#[ignore = "requires docker"]
async fn parse_error_leaves_session_idle() {
    let fixture = start().await;
    let connection = connect(&fixture, false).await;
    let session = session(connection.as_ref()).await;

    let (summary, _) = run(session.as_ref(), "SELEC 1").await;

    let RunEnd::Failed(DriverError::Server(diagnostics)) = &summary.end else {
        panic!("a syntax error ended {:?}", summary.end);
    };
    assert_eq!(diagnostics.sqlstate(), Some("42601"));
    assert_eq!(diagnostics.position, Some(1));
    assert_eq!(summary.transaction_state, TransactionState::Idle);
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
#[ignore = "requires docker"]
async fn a_cursor_error_points_into_the_users_own_statement() {
    let fixture = start().await;
    let connection = connect(&fixture, false).await;
    let session = session(connection.as_ref()).await;

    let (summary, _) = run(session.as_ref(), "SELECT nope FROM pg_class").await;

    let RunEnd::Failed(DriverError::Server(diagnostics)) = &summary.end else {
        panic!("a missing column ended {:?}", summary.end);
    };
    assert_eq!(diagnostics.sqlstate(), Some("42703"));
    assert_eq!(
        diagnostics.position,
        Some(8),
        "the DECLARE prefix leaked into the position"
    );
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
#[ignore = "requires docker"]
async fn call_procedure_with_commit_probes_status() {
    let fixture = start().await;
    let connection = connect(&fixture, false).await;
    setup(
        connection.as_ref(),
        &[
            "CREATE TABLE log (n int)",
            "CREATE PROCEDURE p() LANGUAGE plpgsql AS $$ \
             BEGIN INSERT INTO log VALUES (1); COMMIT; INSERT INTO log VALUES (2); END $$",
        ],
    )
    .await;
    let session = session(connection.as_ref()).await;

    let (summary, _) = run(session.as_ref(), "CALL p()").await;

    assert_eq!(summary.end, RunEnd::Completed);
    assert_eq!(summary.transaction_state, TransactionState::Idle);
    assert_eq!(
        scalar(connection.as_ref(), "SELECT count(*) FROM log").await,
        Value::Int(2)
    );
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
#[ignore = "requires docker"]
async fn do_block_commit_probes_status() {
    let fixture = start().await;
    let connection = connect(&fixture, false).await;
    let session = session(connection.as_ref()).await;

    let (summary, _) = run(
        session.as_ref(),
        "DO $$ BEGIN CREATE TABLE made_in_do (n int); COMMIT; END $$",
    )
    .await;

    assert_eq!(summary.end, RunEnd::Completed);
    assert_eq!(summary.transaction_state, TransactionState::Idle);
    assert_eq!(
        scalar(connection.as_ref(), "SELECT count(*) FROM made_in_do").await,
        Value::Int(0)
    );
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
#[ignore = "requires docker"]
async fn commit_and_chain_stays_in_transaction() {
    let fixture = start().await;
    let connection = connect(&fixture, false).await;
    let session = session(connection.as_ref()).await;
    run_ok(session.as_ref(), "BEGIN").await;

    let (chained, _) = run(session.as_ref(), "COMMIT AND CHAIN").await;
    let (rolled_back, _) = run(session.as_ref(), "ROLLBACK").await;

    assert_eq!(chained.transaction_state, TransactionState::InTransaction);
    assert_eq!(rolled_back.transaction_state, TransactionState::Idle);
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
#[ignore = "requires docker"]
async fn savepoint_probe_25p01_idle_25p02_failed() {
    let fixture = start().await;
    let connection = connect(&fixture, false).await;
    let session = session(connection.as_ref()).await;
    run_ok(session.as_ref(), "BEGIN").await;

    let (failed, _) = run(session.as_ref(), "SELECT 1 / 0").await;
    let (refused, _) = run(session.as_ref(), "SELECT 1").await;
    let state = session.transaction_state(within(CALL)).await;
    let (ended, _) = run(session.as_ref(), "ROLLBACK").await;

    assert!(matches!(failed.end, RunEnd::Failed(_)));
    assert_eq!(failed.transaction_state, TransactionState::Failed);
    assert!(
        matches!(&refused.end, RunEnd::Failed(DriverError::Server(d)) if d.sqlstate() == Some("25P02")),
        "{:?}",
        refused.end
    );
    assert_eq!(state, Ok(TransactionState::Failed));
    assert_eq!(ended.transaction_state, TransactionState::Idle);
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
#[ignore = "requires docker"]
async fn slow_sink_receives_all_rows_in_order() {
    let fixture = start().await;
    let connection = connect(&fixture, false).await;
    let session = session(connection.as_ref()).await;
    let events = Events::default();

    let summary = session
        .run(
            tablepro_core::UserSql::new("SELECT generate_series(1, 1000)"),
            RunOptions::new(CancellationToken::new()),
            Box::new(EventSink::new(&events).slow(Duration::from_millis(5))),
        )
        .await
        .expect("the run");

    assert_eq!(summary.end, RunEnd::Completed);
    let expected: Vec<String> = (1..=1000).map(|n| n.to_string()).collect();
    assert_eq!(texts(&events), expected);
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
#[ignore = "requires docker"]
async fn consumer_gone_cancels_and_session_ready() {
    let fixture = start().await;
    let connection = connect(&fixture, false).await;
    let session = session(connection.as_ref()).await;
    let events = Events::default();

    let summary = session
        .run(
            tablepro_core::UserSql::new("SELECT g FROM generate_series(1, 100000) g; SELECT 2"),
            RunOptions::new(CancellationToken::new()),
            Box::new(EventSink::new(&events).gone_after(1)),
        )
        .await
        .expect("the run");

    assert_eq!(summary.end, RunEnd::Cancelled);
    assert_eq!(session.state(), EditorSessionState::Ready);
    assert_eq!(summary.transaction_state, TransactionState::Idle);
    run_ok(session.as_ref(), "SELECT 1").await;
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
#[ignore = "requires docker"]
async fn notices_reach_the_sink() {
    let fixture = start().await;
    let connection = connect(&fixture, false).await;
    let session = session(connection.as_ref()).await;

    let events = run_ok(session.as_ref(), "DO $$ BEGIN RAISE NOTICE 'hello there'; END $$").await;

    assert!(
        events
            .all()
            .iter()
            .any(|event| matches!(event, ResultEvent::Notice(notice) if notice.message == "hello there")),
        "{:?}",
        events.all()
    );
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
#[ignore = "requires docker"]
async fn standard_conforming_strings_off_splits_with_backslash_escapes() {
    let fixture = start().await;
    let connection = connect(&fixture, false).await;
    let session = session(connection.as_ref()).await;

    let events = run_ok(
        session.as_ref(),
        "SET standard_conforming_strings = off; SELECT 'a\\';b' AS quoted",
    )
    .await;

    assert_eq!(texts(&events), ["a';b"]);
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
#[ignore = "requires docker"]
async fn editor_deadline_times_out_with_the_server_acknowledging() {
    let fixture = start().await;
    let connection = connect(&fixture, false).await;
    let session = session(connection.as_ref()).await;
    let options = RunOptions::new(CancellationToken::new()).with_deadline(Some(Duration::from_secs(1)));

    let (summary, _) = run_with(session.as_ref(), "SELECT pg_sleep(60)", options).await;

    assert_eq!(summary.end, RunEnd::TimedOut { server_cancelled: true });
    assert!(summary.elapsed < Duration::from_secs(3), "{:?}", summary.elapsed);
    assert_eq!(session.state(), EditorSessionState::Ready);
    run_ok(session.as_ref(), "SELECT 1").await;
}
