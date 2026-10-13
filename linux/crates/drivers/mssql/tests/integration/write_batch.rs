//! Saves: one transaction, a probe that proves the row is the one that
//! was read, and a stop that rolls everything back.

use std::time::Duration;

use tablepro_core::edit::parse_literal_text;
use tablepro_core::meta::TableRef;
use tablepro_core::save::{ChangeSet, RowUpdate, plan_save};
use tablepro_core::{CallOptions, DriverError, ErrorCategory, Value, WriteBatch};
use tokio::time::Instant;
use tokio_util::sync::CancellationToken;

use crate::support::{CALL, batch, browse, columns, connect, dbo, run_ok, scalar, session, setup, start, within};

async fn update_label(connection: &dyn tablepro_core::Connection, table: &TableRef, key: Value) -> WriteBatch {
    let columns = columns(connection, table).await;
    let identity = connection.row_identity(table, within(CALL)).await.expect("an identity");
    let label = columns
        .iter()
        .position(|column| column.name == "label")
        .expect("a label column");
    let changes = ChangeSet {
        updates: vec![RowUpdate {
            key: vec![key],
            assignments: vec![(label, Value::Text("changed".to_owned()))],
        }],
        ..ChangeSet::default()
    };
    plan_save(connection.dialect().as_ref(), table, &columns, &identity, &changes)
        .expect("a save plan")
        .batch
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
#[ignore = "requires docker"]
async fn edited_xml_cell_saves() {
    let fixture = start().await;
    let connection = connect(&fixture, false).await;
    setup(
        connection.as_ref(),
        &[
            "CREATE TABLE dbo.docs (id int PRIMARY KEY, body xml NOT NULL)",
            "INSERT INTO dbo.docs VALUES (1, N'<a/>')",
        ],
    )
    .await;
    let table = dbo("docs");
    let columns = columns(connection.as_ref(), &table).await;
    let identity = connection
        .row_identity(&table, within(CALL))
        .await
        .expect("an identity");
    let edited = parse_literal_text("<b>edited</b>", &columns[1].column_type).expect("an XML edit");
    let changes = ChangeSet {
        updates: vec![RowUpdate {
            key: vec![Value::Int(1)],
            assignments: vec![(1, edited)],
        }],
        ..ChangeSet::default()
    };
    let save = plan_save(connection.dialect().as_ref(), &table, &columns, &identity, &changes)
        .expect("a save plan")
        .batch;

    connection.write_batch(&save, within(CALL)).await.expect("the save");

    assert_eq!(
        scalar(connection.as_ref(), "SELECT CAST(body AS nvarchar(max)) FROM dbo.docs").await,
        Value::Text("<b>edited</b>".to_owned())
    );
}

/// A datetime keeps 1/300 s and the grid shows it to the millisecond, as
/// SQL Server does; the key read back has to find its row again.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
#[ignore = "requires docker"]
async fn datetime_key_with_a_third_of_a_millisecond_saves() {
    let fixture = start().await;
    let connection = connect(&fixture, false).await;
    setup(
        connection.as_ref(),
        &[
            "CREATE TABLE dbo.stamped (at datetime PRIMARY KEY, label nvarchar(50) NOT NULL)",
            "INSERT INTO dbo.stamped VALUES ('2024-06-15T10:00:00.003', N'kept')",
        ],
    )
    .await;
    let table = dbo("stamped");
    let columns = columns(connection.as_ref(), &table).await;
    let identity = connection
        .row_identity(&table, within(CALL))
        .await
        .expect("an identity");
    let key = browse(connection.as_ref(), &table).await.remove(0).remove(0);
    let changes = ChangeSet {
        updates: vec![RowUpdate {
            key: vec![key],
            assignments: vec![(1, Value::Text("changed".to_owned()))],
        }],
        ..ChangeSet::default()
    };
    let save = plan_save(connection.dialect().as_ref(), &table, &columns, &identity, &changes)
        .expect("a save plan")
        .batch;

    connection.write_batch(&save, within(CALL)).await.expect("the save");

    assert_eq!(
        scalar(connection.as_ref(), "SELECT label FROM dbo.stamped").await,
        Value::Text("changed".to_owned())
    );
}

/// Under a SQL_* collation an nvarchar parameter cannot seek a varchar
/// key, so the probe's UPDLOCK, HOLDLOCK would scan into a row another
/// transaction holds and wait for it.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
#[ignore = "requires docker"]
async fn varchar_key_save_locks_only_its_own_row() {
    let fixture = start().await;
    let connection = connect(&fixture, false).await;
    setup(
        connection.as_ref(),
        &[
            "CREATE TABLE dbo.codes (code varchar(10) COLLATE SQL_Latin1_General_CP1_CI_AS PRIMARY KEY, \
             label nvarchar(50) NOT NULL)",
            "INSERT INTO dbo.codes VALUES ('k1', N'one'), ('k2', N'two'), ('k3', N'three'), ('k4', N'four'), \
             ('k5', N'five')",
        ],
    )
    .await;
    let holder = session(connection.as_ref()).await;
    run_ok(
        holder.as_ref(),
        "BEGIN TRANSACTION; UPDATE dbo.codes SET label = N'held' WHERE code = 'k5'",
    )
    .await;
    let save = update_label(connection.as_ref(), &dbo("codes"), Value::Text("k1".to_owned())).await;

    let saved = connection.write_batch(&save, within(Duration::from_secs(5))).await;
    run_ok(holder.as_ref(), "ROLLBACK").await;

    assert!(saved.is_ok(), "{saved:?}");
    assert_eq!(
        scalar(connection.as_ref(), "SELECT label FROM dbo.codes WHERE code = 'k1'").await,
        Value::Text("changed".to_owned())
    );
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
#[ignore = "requires docker"]
async fn after_update_trigger_saves_without_false_conflict() {
    let fixture = start().await;
    let connection = connect(&fixture, false).await;
    setup(
        connection.as_ref(),
        &[
            "CREATE TABLE dbo.items (id int PRIMARY KEY, label nvarchar(50) NOT NULL)",
            "CREATE TABLE dbo.audit (id int IDENTITY PRIMARY KEY, item int)",
            "CREATE TRIGGER dbo.items_audit ON dbo.items AFTER UPDATE AS \
             INSERT INTO dbo.audit (item) SELECT id FROM inserted; INSERT INTO dbo.audit (item) SELECT id FROM inserted",
            "INSERT INTO dbo.items VALUES (1, N'kept')",
        ],
    )
    .await;
    let table = dbo("items");

    let save = update_label(connection.as_ref(), &table, Value::Int(1)).await;
    connection.write_batch(&save, within(CALL)).await.expect("the save");

    assert_eq!(
        scalar(connection.as_ref(), "SELECT label FROM dbo.items WHERE id = 1").await,
        Value::Text("changed".to_owned())
    );
    assert_eq!(
        scalar(connection.as_ref(), "SELECT COUNT_BIG(*) FROM dbo.audit").await,
        Value::Int(2)
    );
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
#[ignore = "requires docker"]
async fn probe_mismatch_rolls_back() {
    let fixture = start().await;
    let connection = connect(&fixture, false).await;
    setup(
        connection.as_ref(),
        &[
            "CREATE TABLE dbo.items (id int PRIMARY KEY, label nvarchar(50) NOT NULL)",
            "INSERT INTO dbo.items VALUES (1, N'kept')",
        ],
    )
    .await;
    let table = dbo("items");
    let mut save = update_label(connection.as_ref(), &table, Value::Int(999)).await;
    let first = crate::support::statement("INSERT INTO dbo.items VALUES (2, N'new')");
    save.steps
        .insert(0, tablepro_core::statement::GuardedStatement::unguarded(first));

    let outcome = connection.write_batch(&save, within(CALL)).await;

    assert!(
        matches!(outcome, Err(DriverError::RowGuardFailed { actual: 0, .. })),
        "{outcome:?}"
    );
    assert_eq!(
        scalar(connection.as_ref(), "SELECT COUNT_BIG(*) FROM dbo.items").await,
        Value::Int(1)
    );
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
#[ignore = "requires docker"]
async fn statement_deadline_before_commit_rolls_back_trancount_zero() {
    let fixture = start().await;
    let connection = connect(&fixture, false).await;
    setup(connection.as_ref(), &["CREATE TABLE dbo.t (id int PRIMARY KEY)"]).await;
    let slow = batch(&["INSERT INTO dbo.t VALUES (1)", "WAITFOR DELAY '00:00:30'"]);
    let deadline = Duration::from_secs(1);

    let started = Instant::now();
    let outcome = connection
        .write_batch(
            &slow,
            CallOptions::new(Some(Instant::now() + deadline), CancellationToken::new()),
        )
        .await;

    match &outcome {
        Err(DriverError::RolledBack {
            statement_index,
            source,
        }) => {
            assert_eq!(*statement_index, 1);
            assert_eq!(source.category(), ErrorCategory::Timeout);
        }
        other => panic!("expected a rollback, got {other:?}"),
    }
    assert!(started.elapsed() < Duration::from_secs(5), "{:?}", started.elapsed());
    assert_eq!(
        scalar(connection.as_ref(), "SELECT COUNT_BIG(*) FROM dbo.t").await,
        Value::Int(0)
    );
    assert_eq!(scalar(connection.as_ref(), "SELECT @@TRANCOUNT").await, Value::Int(0));
}
