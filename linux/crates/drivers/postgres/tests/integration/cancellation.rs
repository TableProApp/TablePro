//! A stop reaches the server: the backend goes idle rather than finishing
//! work nobody waits for.

use std::sync::Arc;
use std::time::Duration;

use tablepro_core::{
    CallOptions, Connection, DriverError, RowLimit, RunEnd, RunOptions, TimeoutPhase, TlsConfig, Value,
    WorkspaceSettings,
};
use tablepro_test_fixtures::PostgresFixture;
use tablepro_test_support::conformance::test_liveness;
use tokio::time::Instant;
use tokio_util::sync::CancellationToken;

use crate::slow_route::{CANCEL_REQUEST, Hold, SlowRoute};
use crate::support::{
    CALL, connect, connect_with, direct, options_over, password, run, run_with, scalar, session, start, statement,
    within,
};

/// How long a cancel request takes to reach the server on a slow route.
/// It is inside the test cancel grace, so a driver that waits for the
/// server to take the request has the time to.
const CANCEL_TRANSIT: Duration = Duration::from_millis(700);

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

async fn connect_over(fixture: &PostgresFixture, holds: Vec<Hold>) -> Arc<dyn Connection> {
    let liveness = test_liveness();
    let route = SlowRoute::new(direct(fixture.host(), fixture.port(), &liveness), holds);
    connect_with(options_over(
        Arc::new(route),
        password(&fixture.password_credentials()),
        fixture.database(),
        TlsConfig::disabled(),
        WorkspaceSettings::workspace(false),
        liveness,
    ))
    .await
}

/// The read's own statement timeout ends it while its cancel request is
/// still on the way, and the server acts on that request whenever it
/// arrives, on whatever the backend runs then.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
#[ignore = "requires docker"]
async fn a_late_cancel_after_a_timeout_never_stops_the_next_read() {
    let fixture = start().await;
    // The statement reaches the server a little after the call started,
    // so the server's timeout fires just after the deadline sent the
    // cancel request.
    let connection = connect_over(
        &fixture,
        vec![
            Hold::new(b"pg_sleep(60)", Duration::from_millis(50)),
            Hold::new(&CANCEL_REQUEST, CANCEL_TRANSIT),
        ],
    )
    .await;

    let timed_out = connection
        .query_bound(
            &statement("SELECT pg_sleep(60)"),
            RowLimit::EDITOR_DEFAULT,
            within(Duration::from_secs(1)),
        )
        .await;
    let next = connection
        .query_bound(
            &statement("SELECT 1 FROM pg_sleep(1)"),
            RowLimit::EDITOR_DEFAULT,
            within(CALL),
        )
        .await;

    assert!(
        matches!(
            timed_out,
            Err(DriverError::Timeout {
                phase: TimeoutPhase::Statement,
                server_cancelled: true
            })
        ),
        "{timed_out:?}"
    );
    assert!(next.is_ok(), "the read after the timeout gave {next:?}");
}

/// A statement that ends on its own after Stop leaves the cancel request
/// on its way to the backend the session keeps.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
#[ignore = "requires docker"]
async fn a_late_cancel_after_stop_never_stops_the_next_editor_run() {
    let fixture = start().await;
    let connection = connect_over(&fixture, vec![Hold::new(&CANCEL_REQUEST, CANCEL_TRANSIT)]).await;
    let editor = session(connection.as_ref()).await;
    let cancel = CancellationToken::new();
    let stopper = cancel.clone();
    tokio::spawn(async move {
        tokio::time::sleep(Duration::from_millis(500)).await;
        stopper.cancel();
    });

    let (stopped, _) = run_with(editor.as_ref(), "SELECT pg_sleep(0.8)", RunOptions::new(cancel)).await;
    let (next, _) = run(editor.as_ref(), "SELECT 1 FROM pg_sleep(1)").await;

    assert_eq!(stopped.end, RunEnd::Cancelled);
    assert_eq!(
        next.end,
        RunEnd::Completed,
        "the run after the stop ended {:?}",
        next.end
    );
}
