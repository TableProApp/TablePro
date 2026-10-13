//! Editor sessions and the workspace connection, side by side.

use std::time::Duration;

use tablepro_core::{
    CallOptions, DriverError, EditorSessionOptions, EditorSessionState, ErrorCategory, ReadStatement, ResultEvent,
    RowLimit, RunEnd, RunOptions, TransactionState, Truncation, UserSql, Value, WorkspaceSettings, WriteKind,
};
use tokio::time::Instant;
use tokio_util::sync::CancellationToken;

use crate::support::{TestFile, apply, batch, call, connect, query, run, run_with, statement};

const UNBOUNDED: &str = "WITH RECURSIVE r(n) AS (SELECT 1 UNION ALL SELECT n + 1 FROM r) SELECT count(*) FROM r";

#[tokio::test]
async fn temp_table_visible_across_runs() {
    let file = TestFile::new().await;
    let connection = file.open().await;
    let session = connection
        .open_editor_session(EditorSessionOptions::default(), CancellationToken::new())
        .await
        .unwrap();

    run(
        session.as_ref(),
        "CREATE TEMP TABLE scratch (a); INSERT INTO scratch VALUES (7)",
    )
    .await;
    let (summary, collected) = run(session.as_ref(), "SELECT a FROM scratch").await;

    assert_eq!(summary.end, RunEnd::Completed);
    assert_eq!(collected.rows(), vec![vec![Value::Int(7)]]);
    session.close().await;
    connection.close().await.unwrap();
}

/// sqlite re-prepares a statement whose table changed shape, so the same
/// text can come back with more columns than the first run had.
#[tokio::test]
async fn select_star_after_add_column_reads_the_new_column() {
    let file = TestFile::new().await;
    let connection = file.open().await;
    let session = connection
        .open_editor_session(EditorSessionOptions::default(), CancellationToken::new())
        .await
        .unwrap();
    run(session.as_ref(), "CREATE TABLE grown (a); INSERT INTO grown VALUES (1)").await;
    run(session.as_ref(), "SELECT * FROM grown").await;

    run(session.as_ref(), "ALTER TABLE grown ADD COLUMN b DEFAULT 2").await;
    let (summary, collected) = run(session.as_ref(), "SELECT * FROM grown").await;

    assert_eq!(summary.end, RunEnd::Completed);
    assert_eq!(collected.rows(), vec![vec![Value::Int(1), Value::Int(2)]]);
    session.close().await;
    connection.close().await.unwrap();
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn recursive_cte_cancelled() {
    let file = TestFile::new().await;
    let connection = file.open().await;
    let session = connection
        .open_editor_session(EditorSessionOptions::default(), CancellationToken::new())
        .await
        .unwrap();
    let cancel = CancellationToken::new();
    let stopper = cancel.clone();
    tokio::spawn(async move {
        tokio::time::sleep(Duration::from_millis(300)).await;
        stopper.cancel();
    });

    let started = Instant::now();
    let (summary, _) = run_with(session.as_ref(), UNBOUNDED, RunOptions::new(cancel)).await;

    assert_eq!(summary.end, RunEnd::Cancelled);
    assert!(
        started.elapsed() < Duration::from_secs(2),
        "the cancel took {:?}",
        started.elapsed()
    );
    assert_eq!(session.state(), EditorSessionState::Ready);
    let (after, _) = run(session.as_ref(), "SELECT 1").await;
    assert_eq!(after.end, RunEnd::Completed);
    session.close().await;
    connection.close().await.unwrap();
}

#[tokio::test]
async fn a_run_past_its_deadline_times_out_on_the_server() {
    let file = TestFile::new().await;
    let connection = file.open().await;
    let session = connection
        .open_editor_session(EditorSessionOptions::default(), CancellationToken::new())
        .await
        .unwrap();
    let bounded = RunOptions::new(CancellationToken::new()).with_deadline(Some(Duration::from_millis(200)));

    let (summary, _) = run_with(session.as_ref(), UNBOUNDED, bounded).await;

    assert_eq!(summary.end, RunEnd::TimedOut { server_cancelled: true });
    session.close().await;
    connection.close().await.unwrap();
}

#[tokio::test]
async fn transaction_state_after_begin_in_transaction() {
    let file = TestFile::new().await;
    let connection = file.open().await;
    apply(connection.as_ref(), &["CREATE TABLE t (a)"]).await.unwrap();
    let session = connection
        .open_editor_session(EditorSessionOptions::default(), CancellationToken::new())
        .await
        .unwrap();

    let (begun, _) = run(session.as_ref(), "BEGIN; INSERT INTO t VALUES (1)").await;
    let asked = session.transaction_state(call()).await.unwrap();
    let (committed, _) = run(session.as_ref(), "COMMIT").await;

    assert_eq!(begun.transaction_state, TransactionState::InTransaction);
    assert_eq!(asked, TransactionState::InTransaction);
    assert_eq!(committed.transaction_state, TransactionState::Idle);
    assert_eq!(session.transaction_state(call()).await.unwrap(), TransactionState::Idle);
    session.close().await;
    connection.close().await.unwrap();
}

#[tokio::test]
async fn begin_insert_big_select_commit_persists() {
    let file = TestFile::new().await;
    let connection = file.open().await;
    apply(connection.as_ref(), &["CREATE TABLE t (a)"]).await.unwrap();
    let session = connection
        .open_editor_session(EditorSessionOptions::default(), CancellationToken::new())
        .await
        .unwrap();
    let limited = RunOptions::new(CancellationToken::new()).with_row_limit(RowLimit::new(10).unwrap());

    run(session.as_ref(), "BEGIN; INSERT INTO t VALUES (1)").await;
    let (big, collected) = run_with(
        session.as_ref(),
        "WITH RECURSIVE r(n) AS (SELECT 1 UNION ALL SELECT n + 1 FROM r WHERE n < 100000) SELECT n FROM r; INSERT INTO t VALUES (2)",
        limited,
    )
    .await;
    let (committed, _) = run(session.as_ref(), "COMMIT").await;

    assert_eq!(big.end, RunEnd::Completed);
    assert_eq!(collected.rows().len(), 10);
    let finished: Vec<_> = collected
        .events()
        .into_iter()
        .filter_map(|event| match event {
            tablepro_core::ResultEvent::ResultSetFinished { truncation, .. } => Some(truncation),
            _ => None,
        })
        .collect();
    assert_eq!(finished, [Truncation::ReadPastLimit]);
    assert_eq!(committed.end, RunEnd::Completed);
    let persisted = query(connection.as_ref(), "SELECT count(*) FROM t").await;
    assert_eq!(
        persisted.rows[0][0],
        Value::Int(2),
        "the statement after the limited read did not land"
    );
    session.close().await;
    connection.close().await.unwrap();
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn session_read_concurrent_with_workspace_write_busy_or_commit_never_hangs() {
    let file = TestFile::new().await;
    let settings = WorkspaceSettings {
        lock_timeout: Duration::from_millis(500),
        ..WorkspaceSettings::workspace(false)
    };
    let connection = connect(file.endpoint(), settings).await.unwrap();
    apply(connection.as_ref(), &["CREATE TABLE t (a)", "INSERT INTO t VALUES (1)"])
        .await
        .unwrap();
    let session = connection
        .open_editor_session(EditorSessionOptions::default(), CancellationToken::new())
        .await
        .unwrap();
    // An open read transaction holds a shared lock until it ends.
    run(session.as_ref(), "BEGIN; SELECT a FROM t").await;

    let started = Instant::now();
    let written = connection
        .write_batch(&batch(WriteKind::RowChanges, &["INSERT INTO t VALUES (2)"]), call())
        .await;
    let elapsed = started.elapsed();

    let acceptable = match &written {
        Ok(_) => true,
        Err(DriverError::RolledBack { source, .. }) => matches!(**source, DriverError::Busy),
        Err(DriverError::Busy) => true,
        Err(_) => false,
    };
    assert!(acceptable, "{written:?}");
    assert!(elapsed < Duration::from_secs(5), "the write took {elapsed:?}");
    run(session.as_ref(), "COMMIT").await;
    let after = connection
        .write_batch(&batch(WriteKind::RowChanges, &["INSERT INTO t VALUES (3)"]), call())
        .await;
    assert!(
        after.is_ok(),
        "the connection is unusable after a busy commit: {after:?}"
    );
    session.close().await;
    connection.close().await.unwrap();
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn write_interrupt_before_commit_rolls_back() {
    let file = TestFile::new().await;
    let connection = file.open().await;
    apply(connection.as_ref(), &["CREATE TABLE t (a)"]).await.unwrap();
    let cancel = CancellationToken::new();
    let stopper = cancel.clone();
    tokio::spawn(async move {
        tokio::time::sleep(Duration::from_millis(300)).await;
        stopper.cancel();
    });
    let slow = batch(
        WriteKind::RowChanges,
        &[
            "INSERT INTO t VALUES (1)",
            "INSERT INTO t SELECT n FROM (WITH RECURSIVE r(n) AS (SELECT 1 UNION ALL SELECT n + 1 FROM r) SELECT n FROM r)",
        ],
    );

    let written = connection.write_batch(&slow, CallOptions::new(None, cancel)).await;

    assert!(
        matches!(&written, Err(DriverError::RolledBack { statement_index: 1, source }) if **source == DriverError::Cancelled),
        "{written:?}"
    );
    let rows = query(connection.as_ref(), "SELECT count(*) FROM t").await;
    assert_eq!(rows.rows[0][0], Value::Int(0), "a stopped save left rows behind");
    connection.close().await.unwrap();
}

/// ON CONFLICT ROLLBACK ends the transaction inside SQLite before the
/// batch gets to roll back itself; the workspace connection, and the
/// temporary table on it, must survive that.
#[tokio::test]
async fn a_batch_sqlite_already_rolled_back_keeps_its_connection() {
    let file = TestFile::new().await;
    let connection = file.open().await;
    apply(
        connection.as_ref(),
        &[
            "CREATE TABLE t (a INTEGER UNIQUE ON CONFLICT ROLLBACK)",
            "INSERT INTO t VALUES (1)",
            "CREATE TEMP TABLE kept (a)",
        ],
    )
    .await
    .unwrap();

    let written = connection
        .write_batch(
            &batch(
                WriteKind::RowChanges,
                &["INSERT INTO t VALUES (2)", "INSERT INTO t VALUES (1)"],
            ),
            call(),
        )
        .await;

    assert!(
        matches!(&written, Err(DriverError::RolledBack { statement_index: 1, .. })),
        "{written:?}"
    );
    let rows = query(connection.as_ref(), "SELECT count(*) FROM t").await;
    assert_eq!(rows.rows[0][0], Value::Int(1));
    let kept = query(connection.as_ref(), "SELECT count(*) FROM temp.kept").await;
    assert_eq!(kept.rows[0][0], Value::Int(0), "the workspace connection was replaced");
    let after = connection
        .write_batch(&batch(WriteKind::RowChanges, &["INSERT INTO t VALUES (3)"]), call())
        .await;
    assert!(after.is_ok(), "{after:?}");
    connection.close().await.unwrap();
}

#[tokio::test]
async fn a_second_run_while_one_is_going_is_refused() {
    let file = TestFile::new().await;
    let connection = file.open().await;
    let session = connection
        .open_editor_session(EditorSessionOptions::default(), CancellationToken::new())
        .await
        .unwrap();
    let cancel = CancellationToken::new();
    let first = run_with(session.as_ref(), UNBOUNDED, RunOptions::new(cancel.clone()));
    let second = async {
        tokio::time::sleep(Duration::from_millis(200)).await;
        let refused = session
            .run(
                tablepro_core::UserSql::new("SELECT 1"),
                RunOptions::new(CancellationToken::new()),
                crate::support::Collected::default().sink(),
            )
            .await;
        cancel.cancel();
        refused
    };

    let ((summary, _), refused) = tokio::join!(first, second);

    assert!(matches!(refused, Err(DriverError::EditorSessionBusy)), "{refused:?}");
    assert_eq!(summary.end, RunEnd::Cancelled);
    session.close().await;
    assert_eq!(session.state(), EditorSessionState::Lost);
    connection.close().await.unwrap();
}

#[tokio::test]
async fn stream_read_sends_every_row_and_refuses_writes() {
    let file = TestFile::new().await;
    let connection = file.open().await;
    apply(
        connection.as_ref(),
        &[
            "CREATE TABLE t (a)",
            "INSERT INTO t SELECT value FROM json_each('[1,2,3,4,5,6,7,8,9,10]')",
        ],
    )
    .await
    .unwrap();
    let generated = crate::support::Collected::default();
    let written = crate::support::Collected::default();

    let streamed = connection
        .stream_read(
            &ReadStatement::Generated(statement("SELECT a FROM t ORDER BY a")),
            generated.sink(),
            call(),
        )
        .await
        .unwrap();
    let refused = connection
        .stream_read(
            &ReadStatement::User(UserSql::new("SELECT 1; INSERT INTO t VALUES (11)")),
            written.sink(),
            call(),
        )
        .await;

    assert_eq!(streamed.rows, 10);
    assert_eq!(generated.rows().len(), 10);
    assert!(matches!(
        generated.events().first(),
        Some(ResultEvent::ResultSetStarted { .. })
    ));
    assert!(matches!(
        generated.events().last(),
        Some(ResultEvent::ResultSetFinished {
            retained: 10,
            truncation: Truncation::Complete,
            ..
        })
    ));
    assert!(
        matches!(&refused, Err(error) if error.category() == ErrorCategory::ReadOnly),
        "{refused:?}"
    );
    let rows = query(connection.as_ref(), "SELECT count(*) FROM t").await;
    assert_eq!(rows.rows[0][0], Value::Int(10));
    connection.close().await.unwrap();
}
