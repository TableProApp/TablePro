//! A stop reaches the server: the backend goes idle rather than finishing
//! work nobody waits for.

use std::time::Duration;

use tablepro_core::{CallOptions, Connection, DriverError, RowLimit, TimeoutPhase, Value};
use tokio::time::Instant;
use tokio_util::sync::CancellationToken;

use crate::support::{connect, scalar, start, statement, within};

const SLEEPERS: &str = "SELECT count(*) FROM pg_stat_activity \
     WHERE state = 'active' AND query LIKE '%pg_sleep(60)%' AND pid <> pg_backend_pid()";

async fn backends_sleeping(connection: &dyn Connection) -> Value {
    scalar(connection, SLEEPERS).await
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
#[ignore = "requires docker"]
async fn pg_sleep_cancel_returns_cancelled_within_2s_backend_idle() {
    let fixture = start().await;
    let connection = connect(&fixture, false).await;
    let cancel = CancellationToken::new();
    let stopper = cancel.clone();
    tokio::spawn(async move {
        tokio::time::sleep(Duration::from_millis(500)).await;
        stopper.cancel();
    });
    let started = Instant::now();

    let outcome = connection
        .query_bound(
            &statement("SELECT pg_sleep(60)"),
            RowLimit::EDITOR_DEFAULT,
            CallOptions::new(None, cancel),
        )
        .await;

    assert!(matches!(outcome, Err(DriverError::Cancelled)), "{outcome:?}");
    assert!(started.elapsed() < Duration::from_secs(2), "{:?}", started.elapsed());
    assert_eq!(backends_sleeping(connection.as_ref()).await, Value::Int(0));
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
#[ignore = "requires docker"]
async fn deadline_1s_timeout_server_cancelled() {
    let fixture = start().await;
    let connection = connect(&fixture, false).await;

    let outcome = connection
        .query_bound(
            &statement("SELECT pg_sleep(60)"),
            RowLimit::EDITOR_DEFAULT,
            within(Duration::from_secs(1)),
        )
        .await;

    assert!(
        matches!(
            outcome,
            Err(DriverError::Timeout {
                phase: TimeoutPhase::Statement,
                server_cancelled: true
            })
        ),
        "{outcome:?}"
    );
    assert_eq!(backends_sleeping(connection.as_ref()).await, Value::Int(0));
}
