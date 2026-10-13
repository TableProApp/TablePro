//! A stop that lands while a statement waits for another connection's
//! lock, which is longer than the cancel grace.

use std::time::Duration;

use sqlx::sqlite::{SqliteConnectOptions, SqliteConnection};
use sqlx::{Connection as _, Executor as _};
use tablepro_core::{
    CallOptions, DriverError, EditorSessionOptions, EditorSessionState, RunEnd, RunOptions, Value, WriteKind,
};
use tokio::time::Instant;
use tokio_util::sync::CancellationToken;

use crate::support::{TestFile, apply, batch, query, run, run_with};

/// Well inside the ten-second lock timeout, and short of the second of
/// cancel grace a stop that never lands would use up.
const PROMPT: Duration = Duration::from_millis(900);

async fn hold_write_lock(file: &TestFile) -> SqliteConnection {
    let mut holder = SqliteConnection::connect_with(&SqliteConnectOptions::new().filename(&file.path))
        .await
        .unwrap();
    holder.execute("BEGIN IMMEDIATE").await.unwrap();
    holder
}

fn cancel_after(delay: Duration) -> CancellationToken {
    let cancel = CancellationToken::new();
    let stopper = cancel.clone();
    tokio::spawn(async move {
        tokio::time::sleep(delay).await;
        stopper.cancel();
    });
    cancel
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_save_waiting_for_a_lock_stops_and_keeps_its_connection() {
    let file = TestFile::new().await;
    let connection = file.open().await;
    apply(
        connection.as_ref(),
        &["CREATE TABLE t (a)", "CREATE TEMP TABLE kept (a)"],
    )
    .await
    .unwrap();
    let mut holder = hold_write_lock(&file).await;

    let started = Instant::now();
    let written = connection
        .write_batch(
            &batch(WriteKind::RowChanges, &["INSERT INTO t VALUES (1)"]),
            CallOptions::new(None, cancel_after(Duration::from_millis(200))),
        )
        .await;
    let elapsed = started.elapsed();
    holder.execute("ROLLBACK").await.unwrap();
    holder.close().await.unwrap();

    assert_eq!(
        written,
        Err(DriverError::RolledBack {
            statement_index: 0,
            source: Box::new(DriverError::Cancelled),
        })
    );
    assert!(elapsed < PROMPT, "the stop took {elapsed:?}");
    let kept = query(connection.as_ref(), "SELECT count(*) FROM temp.kept").await;
    assert_eq!(kept.rows[0][0], Value::Int(0), "the workspace connection was replaced");
    connection.close().await.unwrap();
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn an_editor_run_waiting_for_a_lock_stops_and_the_next_run_starts() {
    let file = TestFile::new().await;
    let connection = file.open().await;
    apply(connection.as_ref(), &["CREATE TABLE t (a)"]).await.unwrap();
    let session = connection
        .open_editor_session(EditorSessionOptions::default(), CancellationToken::new())
        .await
        .unwrap();
    let mut holder = hold_write_lock(&file).await;

    let started = Instant::now();
    let (stopped, _) = run_with(
        session.as_ref(),
        "INSERT INTO t VALUES (1)",
        RunOptions::new(cancel_after(Duration::from_millis(200))),
    )
    .await;
    let (next, collected) = run(session.as_ref(), "SELECT 1").await;
    let elapsed = started.elapsed();
    holder.execute("ROLLBACK").await.unwrap();
    holder.close().await.unwrap();

    assert_eq!(stopped.end, RunEnd::Cancelled);
    assert_eq!(next.end, RunEnd::Completed);
    assert_eq!(collected.rows(), vec![vec![Value::Int(1)]]);
    assert!(elapsed < PROMPT, "the stop and the next run took {elapsed:?}");
    assert_eq!(session.state(), EditorSessionState::Ready);
    session.close().await;
    connection.close().await.unwrap();
}
