//! Saves: one transaction, bounded, with the outcome of an interrupted
//! one taken from what was really sent.

use std::sync::Arc;
use std::time::Duration;

use tablepro_core::{
    CommitResolution, CommitToken, DriverError, LivenessPolicy, NetworkEndpoint, TimeoutPhase, TlsConfig, Value,
    WorkspaceSettings, WriteKind,
};
use tablepro_test_support::FaultTransport;
use tablepro_test_support::conformance::test_liveness;
use tokio::time::Instant;

use crate::support::{
    CALL, apply, batch, connect, connect_with, fixture_options, options_over, password, run_ok, scalar, session, setup,
    start, within,
};

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
#[ignore = "requires docker"]
async fn lock_timeout_lock_wait() {
    let fixture = start().await;
    let settings = WorkspaceSettings {
        lock_timeout: Duration::from_secs(1),
        ..WorkspaceSettings::workspace(false)
    };
    let writer = connect_with(fixture_options(&fixture, settings)).await;
    setup(
        writer.as_ref(),
        &[
            "CREATE TABLE t (id int PRIMARY KEY, v text)",
            "INSERT INTO t VALUES (1, 'a')",
        ],
    )
    .await;
    let holder = session(writer.as_ref()).await;
    run_ok(holder.as_ref(), "BEGIN; UPDATE t SET v = 'held' WHERE id = 1").await;

    let outcome = apply(
        writer.as_ref(),
        WriteKind::RowChanges,
        &["UPDATE t SET v = 'b' WHERE id = 1"],
    )
    .await;
    run_ok(holder.as_ref(), "ROLLBACK").await;

    let Err(DriverError::RolledBack { source, .. }) = &outcome else {
        panic!("a blocked update gave {outcome:?}");
    };
    assert!(
        matches!(
            **source,
            DriverError::Timeout {
                phase: TimeoutPhase::LockWait,
                ..
            }
        ),
        "{source:?}"
    );
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
#[ignore = "requires docker"]
async fn statement_deadline_before_commit_rolls_back() {
    let fixture = start().await;
    let connection = connect(&fixture, false).await;
    setup(connection.as_ref(), &["CREATE TABLE t (id int)"]).await;
    let started = Instant::now();

    let outcome = connection
        .write_batch(
            &batch(&["INSERT INTO t VALUES (5)", "SELECT pg_sleep(30)"]),
            within(Duration::from_secs(1)),
        )
        .await;

    assert!(
        matches!(outcome, Err(DriverError::RolledBack { statement_index: 1, .. })),
        "{outcome:?}"
    );
    assert!(started.elapsed() < Duration::from_secs(3), "{:?}", started.elapsed());
    assert_eq!(
        scalar(connection.as_ref(), "SELECT count(*) FROM t").await,
        Value::Int(0)
    );
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
#[ignore = "requires docker"]
async fn commit_stall_deadline_commit_outcome_unknown_then_applied() {
    let fixture = start().await;
    let liveness: LivenessPolicy = test_liveness();
    let endpoint = NetworkEndpoint::new(fixture.host(), fixture.port()).expect("an endpoint");
    let fault = Arc::new(FaultTransport::direct(endpoint, &liveness).expect("a fault transport"));
    let options = options_over(
        fault.clone(),
        password(&fixture.password_credentials()),
        fixture.database(),
        TlsConfig::disabled(),
        WorkspaceSettings::workspace(false),
        liveness,
    );
    let connection = connect_with(options).await;
    setup(connection.as_ref(), &["CREATE TABLE t (id int)"]).await;
    fault.stall_reads_after_write_containing("COMMIT");

    let outcome = connection
        .write_batch(&batch(&["INSERT INTO t VALUES (9)"]), within(Duration::from_secs(1)))
        .await;
    let outcome = match outcome {
        Ok(_) => panic!("a commit whose answer never came was reported as done"),
        Err(error) => error,
    };
    let DriverError::CommitOutcomeUnknown {
        token: Some(token @ CommitToken::PostgresXid { .. }),
        ..
    } = &outcome
    else {
        panic!("a stalled commit gave {outcome:?}");
    };
    let resolution = connection.resolve_commit(token, within(CALL)).await;

    assert_eq!(fault.stalls_triggered(), 1);
    assert_eq!(resolution, Ok(CommitResolution::Applied));
    assert_eq!(
        scalar(connection.as_ref(), "SELECT count(*) FROM t").await,
        Value::Int(1)
    );
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
#[ignore = "requires docker"]
async fn deferred_constraint_commit_error_is_rolled_back() {
    let fixture = start().await;
    let connection = connect(&fixture, false).await;
    setup(
        connection.as_ref(),
        &[
            "CREATE TABLE parent (id int PRIMARY KEY)",
            "CREATE TABLE child (parent_id int REFERENCES parent DEFERRABLE INITIALLY DEFERRED)",
        ],
    )
    .await;

    let outcome = apply(
        connection.as_ref(),
        WriteKind::RowChanges,
        &["INSERT INTO child VALUES (99)"],
    )
    .await;

    let Err(DriverError::RolledBack {
        statement_index: 1,
        source,
    }) = &outcome
    else {
        panic!("a failed deferred check gave {outcome:?}");
    };
    assert!(
        matches!(&**source, DriverError::Server(diagnostics) if diagnostics.sqlstate() == Some("23503")),
        "{source:?}"
    );
    assert_eq!(
        scalar(connection.as_ref(), "SELECT count(*) FROM child").await,
        Value::Int(0)
    );
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
#[ignore = "requires docker"]
async fn abandoned_write_connection_is_taken_not_recycled() {
    let fixture = start().await;
    let liveness = test_liveness();
    let endpoint = NetworkEndpoint::new(fixture.host(), fixture.port()).expect("an endpoint");
    let fault = Arc::new(FaultTransport::direct(endpoint, &liveness).expect("a fault transport"));
    let options = options_over(
        fault.clone(),
        password(&fixture.password_credentials()),
        fixture.database(),
        TlsConfig::disabled(),
        WorkspaceSettings::workspace(false),
        liveness,
    );
    let connection = connect_with(options).await;
    setup(connection.as_ref(), &["CREATE TABLE t (id int, v text)"]).await;
    let monitor = connect(&fixture, false).await;
    fault.stall_reads_after_write_containing("tp_abandoned");

    let outcome = connection
        .write_batch(
            &batch(&["INSERT INTO t VALUES (7, 'tp_abandoned')"]),
            within(Duration::from_secs(1)),
        )
        .await;

    assert!(matches!(outcome, Err(DriverError::RolledBack { .. })), "{outcome:?}");
    // The backend that ran the insert is idle in its transaction until
    // its socket closes, which only taking the connection does.
    let give_up = Instant::now() + Duration::from_secs(5);
    loop {
        let open = scalar(
            monitor.as_ref(),
            "SELECT count(*) FROM pg_stat_activity WHERE state = 'idle in transaction'",
        )
        .await;
        if open == Value::Int(0) {
            break;
        }
        assert!(
            Instant::now() < give_up,
            "the abandoned transaction stayed open: {open:?}"
        );
        tokio::time::sleep(Duration::from_millis(100)).await;
    }
    assert_eq!(scalar(monitor.as_ref(), "SELECT count(*) FROM t").await, Value::Int(0));
    assert_eq!(scalar(connection.as_ref(), "SELECT 1").await, Value::Int(1));
}
