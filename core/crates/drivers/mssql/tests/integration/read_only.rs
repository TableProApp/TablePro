//! Read-only connections: SQL Server cannot hold a session read-only, so
//! the guard rolls a stacked write back and a save is refused outright.

use tablepro_core::{DriverError, ReadOnlyRefusal, RowLimit, Value, WriteKind};

use crate::support::{CALL, apply, connect, scalar, setup, start, statement, within};

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
#[ignore = "requires docker"]
async fn stacked_fragment_leaves_rows_unchanged() {
    let fixture = start().await;
    let owner = connect(&fixture, false).await;
    setup(
        owner.as_ref(),
        &[
            "CREATE TABLE dbo.t (id int PRIMARY KEY)",
            "INSERT INTO dbo.t VALUES (1), (2), (3)",
        ],
    )
    .await;
    let reader = connect(&fixture, true).await;

    let read = reader
        .query_bound(
            &statement("SELECT * FROM dbo.t WHERE (1=1); DELETE FROM dbo.t; SELECT (1)"),
            RowLimit::EDITOR_DEFAULT,
            within(CALL),
        )
        .await;

    assert!(read.is_ok(), "{read:?}");
    assert_eq!(
        scalar(owner.as_ref(), "SELECT COUNT_BIG(*) FROM dbo.t").await,
        Value::Int(3)
    );
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
#[ignore = "requires docker"]
async fn write_batch_client_guard() {
    let fixture = start().await;
    let owner = connect(&fixture, false).await;
    setup(owner.as_ref(), &["CREATE TABLE dbo.t (id int PRIMARY KEY)"]).await;
    let reader = connect(&fixture, true).await;

    let saved = apply(
        reader.as_ref(),
        WriteKind::RowChanges,
        &["INSERT INTO dbo.t VALUES (1)"],
    )
    .await;

    assert_eq!(saved, Err(DriverError::ReadOnly(ReadOnlyRefusal::ClientGuard)));
    assert_eq!(
        scalar(owner.as_ref(), "SELECT COUNT_BIG(*) FROM dbo.t").await,
        Value::Int(0)
    );
}

/// A fragment that commits the guard's transaction itself is reported as
/// escaping the guard, never as a plain success.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
#[ignore = "requires docker"]
async fn a_fragment_that_ends_the_guard_is_refused() {
    let fixture = start().await;
    let owner = connect(&fixture, false).await;
    setup(owner.as_ref(), &["CREATE TABLE dbo.t (id int PRIMARY KEY)"]).await;
    let reader = connect(&fixture, true).await;

    let read = reader
        .query_bound(
            &statement("SELECT 1; COMMIT TRANSACTION; SELECT 2"),
            RowLimit::EDITOR_DEFAULT,
            within(CALL),
        )
        .await;

    assert_eq!(read.err(), Some(DriverError::ReadOnly(ReadOnlyRefusal::ClientGuard)));
}
