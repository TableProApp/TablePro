//! A database file another program holds locked. Every path that needs
//! the lock fails as `Busy(FileLocked)` once the lock timeout runs out,
//! and a save leaves the file as it was.

use std::sync::Arc;
use std::time::Duration;

use sqlx::sqlite::{SqliteConnectOptions, SqliteConnection};
use sqlx::{Connection as _, Executor as _};
use tablepro_core::import::CsvImportOptions;
use tablepro_core::meta::TableRef;
use tablepro_core::statement::GuardedStatement;
use tablepro_core::{
    BusyReason, Connection, DriverError, EditorSessionOptions, EditorSessionState, ForeignKeyMode, RowLimit, RunEnd,
    Value, WorkspaceSettings, WriteBatch, WriteKind,
};
use tablepro_test_support::{CsvImportFailure, import_csv};
use tokio::time::Instant;
use tokio_util::sync::CancellationToken;

use crate::support::{TestFile, apply, batch, call, connect, query, run, statement};

const LOCK_TIMEOUT: Duration = Duration::from_millis(300);

fn locked() -> DriverError {
    DriverError::Busy(BusyReason::FileLocked)
}

fn settings() -> WorkspaceSettings {
    WorkspaceSettings {
        lock_timeout: LOCK_TIMEOUT,
        ..WorkspaceSettings::workspace(false)
    }
}

async fn open(file: &TestFile) -> Arc<dyn Connection> {
    connect(file.endpoint(), settings()).await.unwrap()
}

/// A connection of another program's, outside the driver, that has run
/// `statements` and keeps the lock they took.
async fn other_program(file: &TestFile, statements: &[&'static str]) -> SqliteConnection {
    let mut holder = SqliteConnection::connect_with(&SqliteConnectOptions::new().filename(&file.path))
        .await
        .unwrap();
    for sql in statements {
        holder.execute(*sql).await.unwrap();
    }
    holder
}

async fn release(mut holder: SqliteConnection) {
    holder.execute("ROLLBACK").await.unwrap();
    holder.close().await.unwrap();
}

async fn count(connection: &dyn Connection, sql: &str) -> Value {
    query(connection, sql).await.rows[0][0].clone()
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_structure_change_into_a_locked_file_creates_nothing() {
    let file = TestFile::new().await;
    let connection = open(&file).await;
    apply(connection.as_ref(), &["CREATE TABLE t (a)"]).await.unwrap();
    let holder = other_program(&file, &["BEGIN IMMEDIATE"]).await;
    let rebuild = WriteBatch::new(
        WriteKind::SchemaChanges,
        TableRef::unqualified("u"),
        ["CREATE TABLE u (a)", "INSERT INTO u SELECT a FROM t"]
            .iter()
            .map(|sql| GuardedStatement::unguarded(statement(sql)))
            .collect(),
        ForeignKeyMode::SuspendedThenVerified { checks: Vec::new() },
    );

    let started = Instant::now();
    let changed = connection.write_batch(&rebuild, call()).await;
    let waited = started.elapsed();
    release(holder).await;

    assert_eq!(changed.err(), Some(locked()));
    assert!(waited >= LOCK_TIMEOUT, "locked after only {waited:?}");
    assert_eq!(
        count(
            connection.as_ref(),
            "SELECT count(*) FROM sqlite_schema WHERE name = 'u'"
        )
        .await,
        Value::Int(0),
        "the table was created"
    );
    assert_eq!(
        count(connection.as_ref(), "PRAGMA foreign_keys").await,
        Value::Int(1),
        "foreign keys stayed off"
    );
    connection.close().await.unwrap();
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_reader_elsewhere_holds_up_the_commit_of_a_rollback_journal_file() {
    let file = TestFile::new().await;
    let connection = open(&file).await;
    apply(connection.as_ref(), &["CREATE TABLE t (a)", "INSERT INTO t VALUES (1)"])
        .await
        .unwrap();
    let journal = query(connection.as_ref(), "PRAGMA journal_mode").await;
    assert_eq!(journal.rows[0][0], Value::Text("delete".to_owned()));
    let holder = other_program(&file, &["BEGIN", "SELECT count(*) FROM t"]).await;

    let saved = connection
        .write_batch(
            &batch(
                WriteKind::RowChanges,
                &["INSERT INTO t VALUES (2)", "UPDATE t SET a = 3"],
            ),
            call(),
        )
        .await;
    release(holder).await;

    assert_eq!(
        saved.err(),
        Some(DriverError::RolledBack {
            statement_index: 2,
            source: Box::new(locked()),
        })
    );
    let rows = query(connection.as_ref(), "SELECT a FROM t").await;
    assert_eq!(rows.rows, vec![vec![Value::Int(1)]], "a write landed in part");
    let next = connection
        .write_batch(&batch(WriteKind::RowChanges, &["INSERT INTO t VALUES (4)"]), call())
        .await;
    assert!(next.is_ok(), "the next save failed: {next:?}");
    connection.close().await.unwrap();
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn in_wal_mode_a_reader_elsewhere_does_not_hold_up_a_save() {
    let file = TestFile::new().await;
    let setup = other_program(&file, &["PRAGMA journal_mode = WAL"]).await;
    setup.close().await.unwrap();
    let connection = open(&file).await;
    apply(connection.as_ref(), &["CREATE TABLE t (a)", "INSERT INTO t VALUES (1)"])
        .await
        .unwrap();
    let holder = other_program(&file, &["BEGIN", "SELECT count(*) FROM t"]).await;

    let saved = connection
        .write_batch(&batch(WriteKind::RowChanges, &["INSERT INTO t VALUES (2)"]), call())
        .await;
    release(holder).await;

    assert!(saved.is_ok(), "{saved:?}");
    assert_eq!(
        count(connection.as_ref(), "SELECT count(*) FROM t").await,
        Value::Int(2)
    );
    connection.close().await.unwrap();
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn an_import_into_a_locked_file_adds_no_rows() {
    let file = TestFile::new().await;
    let connection = open(&file).await;
    apply(
        connection.as_ref(),
        &["CREATE TABLE people (id INTEGER PRIMARY KEY, name TEXT)"],
    )
    .await
    .unwrap();
    let holder = other_program(&file, &["BEGIN IMMEDIATE"]).await;

    let imported = import_csv(
        connection.as_ref(),
        &TableRef::unqualified("people"),
        b"id,name\n1,ada\n2,grace\n",
        &CsvImportOptions::default(),
        call(),
    )
    .await;
    release(holder).await;

    assert!(
        matches!(&imported, Err(CsvImportFailure::Driver(error)) if *error == locked()),
        "{imported:?}"
    );
    assert_eq!(
        count(connection.as_ref(), "SELECT count(*) FROM people").await,
        Value::Int(0)
    );
    connection.close().await.unwrap();
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn an_editor_run_against_a_locked_file_fails_and_the_next_run_works() {
    let file = TestFile::new().await;
    let connection = open(&file).await;
    apply(connection.as_ref(), &["CREATE TABLE t (a)"]).await.unwrap();
    let session = connection
        .open_editor_session(EditorSessionOptions::default(), CancellationToken::new())
        .await
        .unwrap();
    let holder = other_program(&file, &["BEGIN IMMEDIATE"]).await;

    let (refused, _) = run(session.as_ref(), "INSERT INTO t VALUES (1)").await;
    release(holder).await;
    let (next, _) = run(session.as_ref(), "INSERT INTO t VALUES (2)").await;

    assert_eq!(refused.end, RunEnd::Failed(locked()));
    assert_eq!(next.end, RunEnd::Completed);
    assert_eq!(session.state(), EditorSessionState::Ready);
    let rows = query(connection.as_ref(), "SELECT a FROM t").await;
    assert_eq!(rows.rows, vec![vec![Value::Int(2)]]);
    session.close().await;
    connection.close().await.unwrap();
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn reads_of_an_exclusively_locked_file_fail_as_locked() {
    let file = TestFile::new().await;
    let connection = open(&file).await;
    apply(connection.as_ref(), &["CREATE TABLE t (a)"]).await.unwrap();
    let holder = other_program(&file, &["BEGIN EXCLUSIVE"]).await;

    let columns = connection.fetch_columns(&TableRef::unqualified("t"), call()).await;
    let page = connection
        .query_bound(&statement("SELECT a FROM t"), RowLimit::EDITOR_DEFAULT, call())
        .await;
    release(holder).await;

    assert_eq!(columns.err(), Some(locked()));
    assert_eq!(page.err(), Some(locked()));
    assert_eq!(
        count(connection.as_ref(), "SELECT count(*) FROM t").await,
        Value::Int(0)
    );
    connection.close().await.unwrap();
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn opening_an_exclusively_locked_file_fails_as_locked() {
    let file = TestFile::new().await;
    let holder = other_program(&file, &["BEGIN EXCLUSIVE"]).await;

    let opened = connect(file.endpoint(), settings()).await;
    release(holder).await;

    assert_eq!(opened.err(), Some(locked()));
    let reopened = connect(file.endpoint(), settings()).await.unwrap();
    reopened.close().await.unwrap();
}
