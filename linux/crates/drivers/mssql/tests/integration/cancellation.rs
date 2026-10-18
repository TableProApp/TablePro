//! Stops sent as TDS attention, and what happens to the connection that
//! carried them.

use std::time::Duration;

use tablepro_core::{DriverError, EditorSessionState, RowLimit, RunEnd, RunOptions, TimeoutPhase};
use tablepro_test_support::conformance::test_liveness;
use tokio::time::Instant;
use tokio_util::sync::CancellationToken;

use crate::support::{CALL, connect, rows, run_ok, run_with, scalar, session, start, statement, within};

const SLACK: Duration = Duration::from_millis(250);

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
#[ignore = "requires docker"]
async fn pooled_query_bound_waitfor_deadline_server_cancelled_client_reused() {
    let fixture = start().await;
    let connection = connect(&fixture, false).await;
    let before = scalar(connection.as_ref(), "SELECT @@SPID").await;
    let deadline = Duration::from_secs(1);

    let started = Instant::now();
    let outcome = connection
        .query_bound(
            &statement("/* tp_waitfor */ WAITFOR DELAY '00:00:30'"),
            RowLimit::EDITOR_DEFAULT,
            within(deadline),
        )
        .await;
    let elapsed = started.elapsed();

    assert_eq!(
        outcome.err(),
        Some(DriverError::Timeout {
            phase: TimeoutPhase::Statement,
            server_cancelled: true
        })
    );
    assert!(
        elapsed <= deadline + test_liveness().cancel_grace + SLACK,
        "{elapsed:?}"
    );
    let after = scalar(connection.as_ref(), "SELECT @@SPID").await;
    assert_eq!(before, after, "the attention left the connection reusable");
    let waiting = rows(
        connection.as_ref(),
        "SELECT COUNT(*) FROM sys.dm_exec_requests r CROSS APPLY sys.dm_exec_sql_text(r.sql_handle) t \
         WHERE t.text LIKE N'%tp_waitfor%' AND r.session_id <> @@SPID",
    )
    .await;
    assert_eq!(waiting, vec![vec![tablepro_core::Value::Int(0)]]);
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
#[ignore = "requires docker"]
async fn editor_waitfor_cancel_then_select1_same_client() {
    let fixture = start().await;
    let connection = connect(&fixture, false).await;
    let session = session(connection.as_ref()).await;
    let spid = run_ok(session.as_ref(), "SELECT @@SPID").await.rows();
    let cancel = CancellationToken::new();
    let stopping = cancel.clone();
    tokio::spawn(async move {
        tokio::time::sleep(Duration::from_millis(500)).await;
        stopping.cancel();
    });

    let (summary, _) = run_with(session.as_ref(), "WAITFOR DELAY '00:01:00'", RunOptions::new(cancel)).await;

    assert_eq!(summary.end, RunEnd::Cancelled);
    assert_eq!(session.state(), EditorSessionState::Ready);
    assert_eq!(run_ok(session.as_ref(), "SELECT @@SPID").await.rows(), spid);
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
#[ignore = "requires docker"]
async fn waitfor_3s_does_not_delay_probe() {
    let fixture = start().await;
    let connection = connect(&fixture, false).await;
    let holder = connection.clone();
    let holding = tokio::spawn(async move {
        holder
            .query_bound(
                &statement("WAITFOR DELAY '00:00:03'; SELECT 1"),
                RowLimit::EDITOR_DEFAULT,
                within(CALL),
            )
            .await
    });
    tokio::time::sleep(Duration::from_millis(300)).await;

    let started = Instant::now();
    connection
        .probe(within(test_liveness().probe_timeout))
        .await
        .expect("a probe");

    assert!(started.elapsed() < Duration::from_secs(2), "{:?}", started.elapsed());
    holding.await.expect("the holder ran").expect("the held read");
}

/// tiberius bounds every response by 30 seconds unless told not to, and
/// abandons the connection when one takes longer.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
#[ignore = "requires docker"]
async fn waitfor_40s_completes_without_command_desync() {
    let fixture = start().await;
    let connection = connect(&fixture, false).await;

    let done = connection
        .query_bound(
            &statement("WAITFOR DELAY '00:00:40'; SELECT 1 AS done"),
            RowLimit::EDITOR_DEFAULT,
            within(Duration::from_secs(55)),
        )
        .await
        .expect("a 40 second read");

    assert_eq!(done.rows, vec![vec![tablepro_core::Value::Int(1)]]);
    assert_eq!(
        scalar(connection.as_ref(), "SELECT 2").await,
        tablepro_core::Value::Int(2)
    );
}

/// A cancel that lands while rows are streaming may leave a token half
/// read, so the session either takes the next run or says it is lost;
/// it never hangs and never reads garbage.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
#[ignore = "requires docker"]
async fn cancel_after_dropped_row_stream_discards_client() {
    let fixture = start().await;
    let connection = connect(&fixture, false).await;
    let session = session(connection.as_ref()).await;
    let cancel = CancellationToken::new();
    let stopping = cancel.clone();
    tokio::spawn(async move {
        tokio::time::sleep(Duration::from_millis(200)).await;
        stopping.cancel();
    });

    let started = Instant::now();
    let (summary, _) = run_with(
        session.as_ref(),
        "SELECT a.object_id, b.name FROM sys.all_objects a CROSS JOIN sys.all_objects b",
        RunOptions::new(cancel).with_row_limit(RowLimit::new(5_000_000).expect("a limit")),
    )
    .await;

    assert_eq!(summary.end, RunEnd::Cancelled);
    assert!(started.elapsed() < Duration::from_secs(5), "{:?}", started.elapsed());
    match session.state() {
        EditorSessionState::Ready => {
            run_ok(session.as_ref(), "SELECT 1").await;
        }
        state => assert_eq!(state, EditorSessionState::Lost),
    }
    let fresh = crate::support::session(connection.as_ref()).await;
    run_ok(fresh.as_ref(), "SELECT 1").await;
}
