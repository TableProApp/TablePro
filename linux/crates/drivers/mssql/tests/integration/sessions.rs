//! Editor sessions: one connection per tab, batches as SQL batches, so
//! USE, SET and an open transaction last from one run to the next.

use tablepro_core::{ResultEvent, RowLimit, RunOptions, TransactionState, Truncation, Value};
use tokio_util::sync::CancellationToken;

use crate::support::{connect, run, run_ok, run_with, scalar, session, setup, start};

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
#[ignore = "requires docker"]
async fn use_database_persists_across_runs() {
    let fixture = start().await;
    let connection = connect(&fixture, false).await;
    let session = session(connection.as_ref()).await;

    run_ok(session.as_ref(), "USE tempdb").await;
    let database = run_ok(session.as_ref(), "SELECT DB_NAME()").await.rows();

    assert_eq!(database, vec![vec![Value::Text("tempdb".to_owned())]]);
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
#[ignore = "requires docker"]
async fn begin_tran_insert_big_select_commit_persists() {
    let fixture = start().await;
    let connection = connect(&fixture, false).await;
    setup(connection.as_ref(), &["CREATE TABLE dbo.t (id int PRIMARY KEY)"]).await;
    let session = session(connection.as_ref()).await;

    run_ok(session.as_ref(), "BEGIN TRANSACTION").await;
    run_ok(session.as_ref(), "INSERT INTO dbo.t VALUES (1)").await;
    let limited = RunOptions::new(CancellationToken::new()).with_row_limit(RowLimit::new(10).expect("a limit"));
    let (big, _) = run_with(
        session.as_ref(),
        "SELECT TOP (50000) a.object_id FROM sys.all_objects a CROSS JOIN sys.all_objects b",
        limited,
    )
    .await;
    assert_eq!(big.transaction_state, TransactionState::InTransaction);
    run_ok(session.as_ref(), "COMMIT TRANSACTION").await;

    assert_eq!(
        scalar(connection.as_ref(), "SELECT COUNT_BIG(*) FROM dbo.t").await,
        Value::Int(1)
    );
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
#[ignore = "requires docker"]
async fn limit_100_over_200k_rows_read_past_limit_total() {
    let fixture = start().await;
    let connection = connect(&fixture, false).await;
    let session = session(connection.as_ref()).await;
    let limited = RunOptions::new(CancellationToken::new()).with_row_limit(RowLimit::new(100).expect("a limit"));

    let (_, events) = run_with(
        session.as_ref(),
        "SELECT TOP (200000) a.object_id FROM sys.all_objects a CROSS JOIN sys.all_objects b",
        limited,
    )
    .await;

    assert_eq!(events.rows().len(), 100);
    assert_eq!(
        events.finished(),
        vec![ResultEvent::ResultSetFinished {
            retained: 100,
            total_rows: Some(200_000),
            truncation: Truncation::ReadPastLimit,
        }]
    );
}

/// A transaction an error dooms is rolled back when its batch ends, so
/// `Failed` is only ever seen inside a batch; across runs the session
/// reports the open transaction and its end.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
#[ignore = "requires docker"]
async fn transaction_state_in_transaction_and_failed() {
    let fixture = start().await;
    let connection = connect(&fixture, false).await;
    let session = session(connection.as_ref()).await;

    let (opened, _) = run(session.as_ref(), "BEGIN TRANSACTION").await;
    let (failed, _) = run(session.as_ref(), "SELECT 1/0").await;
    let (closed, _) = run(session.as_ref(), "ROLLBACK TRANSACTION").await;

    assert_eq!(opened.transaction_state, TransactionState::InTransaction);
    assert!(!failed.succeeded());
    assert_eq!(failed.transaction_state, TransactionState::InTransaction);
    assert_eq!(closed.transaction_state, TransactionState::Idle);
}

/// GO splits a script into batches, and a failed batch does not stop the
/// next one, as in sqlcmd.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
#[ignore = "requires docker"]
async fn go_batches_run_in_order_and_continue_after_an_error() {
    let fixture = start().await;
    let connection = connect(&fixture, false).await;
    let session = session(connection.as_ref()).await;

    let (summary, events) = run(
        session.as_ref(),
        "SELECT 1\nGO\nSELECT * FROM no_such_table\nGO\nSELECT 3",
    )
    .await;

    assert!(!summary.succeeded());
    assert_eq!(events.rows(), vec![vec![Value::Int(1)], vec![Value::Int(3)]]);
}
