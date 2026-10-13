//! Read-only is held per transaction, so no statement escapes it and no
//! setting outlives it.

use tablepro_core::{
    Connection, DriverError, ReadOnlyRefusal, ReadStatement, RowLimit, RunEnd, StreamSummary, TransactionState,
    UserSql, Value, WriteKind,
};

use crate::support::{
    CALL, EventSink, Events, apply, connect, run, run_ok, scalar, session, setup, start, statement, within,
};

fn refused_by_server(end: &RunEnd) -> bool {
    matches!(
        end,
        RunEnd::Failed(DriverError::ReadOnly(ReadOnlyRefusal::ServerRejected(_)))
    )
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
#[ignore = "requires docker"]
async fn editor_idle_delete_fails_25006() {
    let fixture = start().await;
    let owner = connect(&fixture, false).await;
    setup(owner.as_ref(), &["CREATE TABLE t (id int)", "INSERT INTO t VALUES (1)"]).await;
    let reader = connect(&fixture, true).await;
    let session = session(reader.as_ref()).await;

    let (summary, _) = run(session.as_ref(), "DELETE FROM t").await;

    assert!(refused_by_server(&summary.end), "{:?}", summary.end);
    assert_eq!(summary.transaction_state, TransactionState::Idle);
    assert_eq!(scalar(owner.as_ref(), "SELECT count(*) FROM t").await, Value::Int(1));
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
#[ignore = "requires docker"]
async fn editor_begin_then_delete_fails_25006() {
    let fixture = start().await;
    let owner = connect(&fixture, false).await;
    setup(owner.as_ref(), &["CREATE TABLE t (id int)", "INSERT INTO t VALUES (1)"]).await;
    let reader = connect(&fixture, true).await;
    let session = session(reader.as_ref()).await;

    let (begun, _) = run(session.as_ref(), "BEGIN").await;
    let (deleted, _) = run(session.as_ref(), "DELETE FROM t").await;
    run_ok(session.as_ref(), "ROLLBACK").await;

    assert_eq!(begun.transaction_state, TransactionState::InTransaction);
    assert!(refused_by_server(&deleted.end), "{:?}", deleted.end);
    assert_eq!(deleted.transaction_state, TransactionState::Failed);
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
#[ignore = "requires docker"]
async fn editor_set_default_transaction_read_only_off_does_not_escape() {
    let fixture = start().await;
    let owner = connect(&fixture, false).await;
    setup(owner.as_ref(), &["CREATE TABLE t (id int)", "INSERT INTO t VALUES (1)"]).await;
    let reader = connect(&fixture, true).await;
    let session = session(reader.as_ref()).await;

    run_ok(session.as_ref(), "SET default_transaction_read_only = off").await;
    let (summary, _) = run(session.as_ref(), "DELETE FROM t").await;

    assert!(refused_by_server(&summary.end), "{:?}", summary.end);
    assert_eq!(scalar(owner.as_ref(), "SELECT count(*) FROM t").await, Value::Int(1));
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
#[ignore = "requires docker"]
async fn editor_vacuum_refused_as_read_only() {
    let fixture = start().await;
    let owner = connect(&fixture, false).await;
    setup(owner.as_ref(), &["CREATE TABLE t (id int)"]).await;
    let reader = connect(&fixture, true).await;
    let session = session(reader.as_ref()).await;

    let (summary, _) = run(session.as_ref(), "VACUUM t").await;

    assert!(refused_by_server(&summary.end), "{:?}", summary.end);
    assert_eq!(summary.transaction_state, TransactionState::Idle);
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
#[ignore = "requires docker"]
async fn editor_commit_prepared_refused_client_guard() {
    let fixture = start().await;
    let reader = connect(&fixture, true).await;
    let session = session(reader.as_ref()).await;

    let (summary, _) = run(session.as_ref(), "COMMIT PREPARED 'anything'").await;

    assert_eq!(
        summary.end,
        RunEnd::Failed(DriverError::ReadOnly(ReadOnlyRefusal::ClientGuard))
    );
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
#[ignore = "requires docker"]
async fn write_batch_client_guard() {
    let fixture = start().await;
    let reader = connect(&fixture, true).await;

    let outcome = apply(reader.as_ref(), WriteKind::RowChanges, &["CREATE TABLE t (id int)"]).await;

    assert!(
        matches!(outcome, Err(DriverError::ReadOnly(ReadOnlyRefusal::ClientGuard))),
        "{outcome:?}"
    );
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
#[ignore = "requires docker"]
async fn query_bound_nextval_is_25006() {
    let fixture = start().await;
    let owner = connect(&fixture, false).await;
    setup(owner.as_ref(), &["CREATE SEQUENCE s"]).await;

    let outcome = owner
        .query_bound(
            &statement("SELECT nextval('s')"),
            RowLimit::EDITOR_DEFAULT,
            within(CALL),
        )
        .await;

    assert!(
        matches!(outcome, Err(DriverError::ReadOnly(ReadOnlyRefusal::ServerRejected(_)))),
        "a generated read wrote: {:?}",
        outcome.map(|result| result.rows)
    );
}

async fn stream_user_sql(connection: &dyn Connection, sql: &str) -> Result<StreamSummary, DriverError> {
    connection
        .stream_read(
            &ReadStatement::User(UserSql::new(sql)),
            Box::new(EventSink::new(&Events::default())),
            within(CALL),
        )
        .await
}

/// The read's own transaction has taken its snapshot before user SQL
/// runs, so none of these can make it writable.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
#[ignore = "requires docker"]
async fn stream_read_user_sql_cannot_turn_the_transaction_writable() {
    let fixture = start().await;
    let owner = connect(&fixture, false).await;
    setup(owner.as_ref(), &["CREATE TABLE t (id int)", "INSERT INTO t VALUES (1)"]).await;

    for sql in [
        "SET TRANSACTION READ WRITE; DELETE FROM t",
        "SET transaction_read_only = off; DELETE FROM t",
        "SET LOCAL transaction_read_only TO false; DELETE FROM t",
        "SELECT set_config('transaction_read_only', 'off', true); DELETE FROM t",
        "SET SESSION CHARACTERISTICS AS TRANSACTION READ WRITE; DELETE FROM t",
    ] {
        let outcome = stream_user_sql(owner.as_ref(), sql).await;

        assert!(
            matches!(outcome, Err(DriverError::ReadOnly(ReadOnlyRefusal::ServerRejected(_)))),
            "{sql}: {outcome:?}"
        );
    }
    assert_eq!(scalar(owner.as_ref(), "SELECT count(*) FROM t").await, Value::Int(1));
}

/// With `standard_conforming_strings` off the server reads `\'` as an
/// escaped quote, so the COMMIT is a statement of its own and the guard
/// has to see it that way too.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
#[ignore = "requires docker"]
async fn stream_read_guard_splits_as_a_non_conforming_session_does() {
    let fixture = start().await;
    let owner = connect(&fixture, false).await;
    setup(
        owner.as_ref(),
        &[
            "CREATE TABLE t (id int)",
            "INSERT INTO t VALUES (1)",
            "ALTER ROLE CURRENT_USER SET standard_conforming_strings = off",
        ],
    )
    .await;

    let outcome = stream_user_sql(owner.as_ref(), "SELECT 'a\\', '; COMMIT; DELETE FROM t; SELECT '1'").await;

    assert!(
        matches!(outcome, Err(DriverError::ReadOnly(ReadOnlyRefusal::ClientGuard))),
        "{outcome:?}"
    );
    assert_eq!(scalar(owner.as_ref(), "SELECT count(*) FROM t").await, Value::Int(1));
}
