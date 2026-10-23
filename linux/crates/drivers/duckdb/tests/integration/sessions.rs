//! Editor sessions on DuckDB: what a run reports, where its transaction
//! stands, and how a stop ends it.

use std::future::Future;
use std::task::Poll;
use std::time::Duration;

use tablepro_core::{
    EditorSessionState, ResultEvent, RowLimit, RunEnd, RunOptions, TransactionState, Truncation, Value,
};
use tokio_util::sync::CancellationToken;

use crate::support::{TestFile, run, run_with, session};

const UNBOUNDED: &str = "SELECT sum(a.range * b.range) FROM range(100000000) a, range(100000000) b";

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_temporary_table_stays_with_its_tab() {
    let file = TestFile::new();
    let connection = file.open().await;
    let editor = session(connection.as_ref()).await;
    let other = session(connection.as_ref()).await;

    run(
        editor.as_ref(),
        "CREATE TEMP TABLE scratch (a INTEGER); INSERT INTO scratch VALUES (7)",
    )
    .await;
    let (mine, collected) = run(editor.as_ref(), "SELECT a FROM scratch").await;
    let (theirs, _) = run(other.as_ref(), "SELECT a FROM scratch").await;

    assert_eq!(mine.end, RunEnd::Completed);
    assert_eq!(collected.rows(), vec![vec![Value::Int(7)]]);
    assert!(matches!(theirs.end, RunEnd::Failed(_)), "{:?}", theirs.end);
    editor.close().await;
    other.close().await;
    connection.close().await.unwrap();
}

/// DuckDB reports no autocommit flag, so where a transaction stands is
/// read from the transaction id across two statements.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_run_reports_where_its_transaction_stands() {
    let file = TestFile::new();
    let connection = file.open().await;
    let editor = session(connection.as_ref()).await;

    let (idle, _) = run(editor.as_ref(), "CREATE TABLE t (id INTEGER PRIMARY KEY)").await;
    let (open, _) = run(editor.as_ref(), "BEGIN; INSERT INTO t VALUES (1)").await;
    let (failed, _) = run(editor.as_ref(), "INSERT INTO t VALUES (1)").await;
    let (ended, _) = run(editor.as_ref(), "ROLLBACK").await;

    assert_eq!(idle.transaction_state, TransactionState::Idle);
    assert_eq!(open.transaction_state, TransactionState::InTransaction);
    assert!(matches!(failed.end, RunEnd::Failed(_)), "{:?}", failed.end);
    assert_eq!(failed.transaction_state, TransactionState::Failed);
    assert_eq!(ended.transaction_state, TransactionState::Idle);
    editor.close().await;
    connection.close().await.unwrap();
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_statement_reports_rows_it_changed_or_returned() {
    let file = TestFile::new();
    let connection = file.open().await;
    let editor = session(connection.as_ref()).await;

    let (_, created) = run(editor.as_ref(), "CREATE TABLE t (a INTEGER)").await;
    let (_, inserted) = run(editor.as_ref(), "INSERT INTO t VALUES (1), (2), (3)").await;
    let (_, returned) = run(editor.as_ref(), "DELETE FROM t WHERE a > 1 RETURNING a").await;
    let (_, counted) = run(editor.as_ref(), "SELECT 5 AS \"Count\"").await;

    let commands = |events: Vec<ResultEvent>| -> Vec<Option<u64>> {
        events
            .into_iter()
            .filter_map(|event| match event {
                ResultEvent::CommandCompleted { rows_affected } => Some(rows_affected),
                _ => None,
            })
            .collect()
    };
    assert_eq!(commands(created.events()), [None]);
    assert_eq!(commands(inserted.events()), [Some(3)]);
    assert_eq!(returned.rows(), vec![vec![Value::Int(2)], vec![Value::Int(3)]]);
    assert_eq!(
        counted.rows(),
        vec![vec![Value::Int(5)]],
        "a SELECT of a Count column is rows"
    );
    editor.close().await;
    connection.close().await.unwrap();
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn the_row_limit_stops_reading_and_keeps_later_statements() {
    let file = TestFile::new();
    let connection = file.open().await;
    let editor = session(connection.as_ref()).await;
    let limited = RunOptions::new(CancellationToken::new()).with_row_limit(RowLimit::new(10).unwrap());

    let (summary, collected) = run_with(editor.as_ref(), "SELECT range FROM range(100000); SELECT 1", limited).await;

    assert_eq!(summary.end, RunEnd::Completed);
    let events = collected.events();
    assert!(
        events.contains(&ResultEvent::RowLimitReached { retained: 10 }),
        "{events:?}"
    );
    assert!(events.contains(&ResultEvent::ResultSetFinished {
        retained: 10,
        total_rows: None,
        truncation: Truncation::ReadPastLimit,
    }));
    assert_eq!(collected.rows().len(), 11, "the limited set and the one after it");
    editor.close().await;
    connection.close().await.unwrap();
}

/// A stop interrupts the running statement, and the session takes the
/// next run.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_cancelled_statement_is_interrupted() {
    let file = TestFile::new();
    let connection = file.open().await;
    let editor = session(connection.as_ref()).await;
    let cancel = CancellationToken::new();
    let stopping = cancel.clone();
    tokio::spawn(async move {
        tokio::time::sleep(Duration::from_millis(300)).await;
        stopping.cancel();
    });

    let (summary, _) = run_with(editor.as_ref(), UNBOUNDED, RunOptions::new(cancel)).await;
    let (next, collected) = run(editor.as_ref(), "SELECT 1").await;

    assert_eq!(summary.end, RunEnd::Cancelled);
    assert_eq!(editor.state(), EditorSessionState::Ready);
    assert_eq!(next.end, RunEnd::Completed);
    assert_eq!(collected.rows(), vec![vec![Value::Int(1)]]);
    editor.close().await;
    connection.close().await.unwrap();
}

/// The deadline reads as a timeout DuckDB acted on.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_statement_past_its_deadline_times_out() {
    let file = TestFile::new();
    let connection = file.open().await;
    let editor = session(connection.as_ref()).await;
    let options = RunOptions::new(CancellationToken::new()).with_deadline(Some(Duration::from_millis(300)));

    let (summary, _) = run_with(editor.as_ref(), UNBOUNDED, options).await;

    assert_eq!(summary.end, RunEnd::TimedOut { server_cancelled: true });
    editor.close().await;
    connection.close().await.unwrap();
}

/// DuckDB clears an interrupt as each statement starts, so a stop that
/// lands between statements must still keep the next one from running.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_stop_between_statements_runs_no_more() {
    let file = TestFile::new();
    let connection = file.open().await;
    let editor = session(connection.as_ref()).await;
    run(editor.as_ref(), "CREATE TABLE marks (a INTEGER)").await;
    let cancel = CancellationToken::new();
    let stopping = cancel.clone();
    tokio::spawn(async move {
        tokio::time::sleep(Duration::from_millis(300)).await;
        stopping.cancel();
    });

    let script = format!("SELECT count(*) FROM range(10); {UNBOUNDED}; INSERT INTO marks VALUES (1)");
    let (summary, _) = run_with(editor.as_ref(), &script, RunOptions::new(cancel)).await;
    let (_, marks) = run(editor.as_ref(), "SELECT count(*) FROM marks").await;

    assert_eq!(summary.end, RunEnd::Cancelled);
    assert_eq!(
        marks.rows(),
        vec![vec![Value::Int(0)]],
        "a statement after the stop ran"
    );
    editor.close().await;
    connection.close().await.unwrap();
}

/// A run cancelled before it starts sends nothing.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_run_cancelled_before_it_starts_sends_nothing() {
    let file = TestFile::new();
    let connection = file.open().await;
    let editor = session(connection.as_ref()).await;
    run(editor.as_ref(), "CREATE TABLE marks (a INTEGER)").await;
    let cancel = CancellationToken::new();
    cancel.cancel();

    let (summary, _) = run_with(editor.as_ref(), "INSERT INTO marks VALUES (1)", RunOptions::new(cancel)).await;
    let (_, marks) = run(editor.as_ref(), "SELECT count(*) FROM marks").await;

    assert_eq!(summary.end, RunEnd::Cancelled);
    assert_eq!(marks.rows(), vec![vec![Value::Int(0)]]);
    editor.close().await;
    connection.close().await.unwrap();
}

/// A statement whose WITH clause leads to a row change reports the rows
/// it changed.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_change_after_a_with_clause_reports_its_count() {
    let file = TestFile::new();
    let connection = file.open().await;
    let editor = session(connection.as_ref()).await;
    run(editor.as_ref(), "CREATE TABLE t (a INTEGER)").await;

    let (_, inserted) = run(
        editor.as_ref(),
        "WITH src AS (SELECT range AS a FROM range(4)) INSERT INTO t SELECT a FROM src",
    )
    .await;

    assert!(
        inserted.events().contains(&ResultEvent::CommandCompleted { rows_affected: Some(4) }),
        "{:?}",
        inserted.events()
    );
    editor.close().await;
    connection.close().await.unwrap();
}

/// What a prepared statement or a table function returns is its rows,
/// whatever its one column is called.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn an_execute_or_a_call_returns_its_rows() {
    let file = TestFile::new();
    let connection = file.open().await;
    let editor = session(connection.as_ref()).await;
    run(
        editor.as_ref(),
        "PREPARE q AS SELECT 42 AS \"Count\"; \
         CREATE MACRO checked() AS TABLE SELECT true AS \"Success\"",
    )
    .await;

    let (_, executed) = run(editor.as_ref(), "EXECUTE q").await;
    let (_, called) = run(editor.as_ref(), "CALL checked()").await;

    assert_eq!(executed.rows(), vec![vec![Value::Int(42)]]);
    assert_eq!(called.rows(), vec![vec![Value::Bool(true)]]);
    editor.close().await;
    connection.close().await.unwrap();
}

/// A caller that gives up a state read while it runs leaves the tab's
/// connection with that read, so the tab is lost rather than ready with
/// nothing to run on.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_state_read_given_up_loses_the_session() {
    let file = TestFile::new();
    let connection = file.open().await;
    let editor = session(connection.as_ref()).await;

    let mut reading = Box::pin(editor.transaction_state(crate::support::call()));
    let first = std::future::poll_fn(|context| Poll::Ready(reading.as_mut().poll(context))).await;
    drop(reading);
    let next = editor
        .run(
            tablepro_core::UserSql::new("SELECT 1"),
            RunOptions::new(CancellationToken::new()),
            crate::support::Collected::default().sink(),
        )
        .await;

    assert!(first.is_pending(), "the state read finished before it was given up");
    assert_eq!(editor.state(), EditorSessionState::Lost);
    assert!(
        matches!(next, Err(tablepro_core::DriverError::ConnectionLost { .. })),
        "{next:?}"
    );
    editor.close().await;
    connection.close().await.unwrap();
}
