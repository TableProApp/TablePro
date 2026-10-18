//! A batch that runs with foreign keys suspended, the way a table
//! rebuild has to, and the write lock every batch takes first.

use std::time::Duration;

use sqlx::sqlite::{SqliteConnectOptions, SqliteConnection};
use sqlx::{Connection as _, Executor as _};
use tablepro_core::meta::TableRef;
use tablepro_core::statement::GuardedStatement;
use tablepro_core::{
    Connection, DriverError, ForeignKeyCheck, ForeignKeyMode, ServerCode, Value, WorkspaceSettings, WriteBatch,
    WriteKind,
};
use tokio::time::Instant;

use crate::support::{TestFile, apply, call, connect, query, statement};

const PARENTS_AND_CHILDREN: [&str; 4] = [
    "CREATE TABLE parents (id INTEGER PRIMARY KEY)",
    "CREATE TABLE children (id INTEGER PRIMARY KEY, parent INTEGER REFERENCES parents (id))",
    "CREATE TABLE others (id INTEGER PRIMARY KEY, parent INTEGER REFERENCES parents (id))",
    "INSERT INTO parents VALUES (1)",
];

fn suspended(statements: &[&str], checks: Vec<ForeignKeyCheck>) -> WriteBatch {
    WriteBatch::new(
        WriteKind::SchemaChanges,
        TableRef::unqualified("children"),
        statements
            .iter()
            .map(|sql| GuardedStatement::unguarded(statement(sql)))
            .collect(),
        ForeignKeyMode::SuspendedThenVerified { checks },
    )
}

/// Rows written while foreign keys are off are never checked, which is
/// how a file comes to hold violations already.
async fn with_existing_violations(connection: &dyn Connection) {
    apply(connection, &PARENTS_AND_CHILDREN).await.unwrap();
    connection
        .write_batch(
            &suspended(
                &[
                    "INSERT INTO children VALUES (1, 1), (2, 99)",
                    "INSERT INTO others VALUES (1, 98)",
                ],
                Vec::new(),
            ),
            call(),
        )
        .await
        .unwrap();
}

async fn foreign_keys_on(connection: &dyn Connection) -> bool {
    query(connection, "PRAGMA foreign_keys").await.rows[0][0] == Value::Int(1)
}

#[tokio::test]
async fn suspended_batch_commits_with_preexisting_unrelated_violation() {
    let file = TestFile::new().await;
    let connection = file.open().await;
    with_existing_violations(connection.as_ref()).await;

    // The rebuild a structure change runs: copy, drop, rename.
    let rebuild = suspended(
        &[
            "CREATE TABLE children_new (id INTEGER PRIMARY KEY, parent INTEGER REFERENCES parents (id), note TEXT)",
            "INSERT INTO children_new (id, parent) SELECT id, parent FROM children",
            "DROP TABLE children",
            "ALTER TABLE children_new RENAME TO children",
        ],
        vec![ForeignKeyCheck::same_table(TableRef::unqualified("children"))],
    );

    let report = connection.write_batch(&rebuild, call()).await;

    assert!(report.is_ok(), "{report:?}");
    let rows = query(connection.as_ref(), "SELECT count(*) FROM children").await;
    assert_eq!(rows.rows[0][0], Value::Int(2));
    connection.close().await.unwrap();
}

#[tokio::test]
async fn suspended_batch_rolls_back_introduced_violation_with_diagnostics() {
    let file = TestFile::new().await;
    let connection = file.open().await;
    with_existing_violations(connection.as_ref()).await;

    let introducing = suspended(
        &["INSERT INTO children VALUES (3, 77)"],
        vec![ForeignKeyCheck::same_table(TableRef::unqualified("children"))],
    );

    let outcome = connection.write_batch(&introducing, call()).await;

    let Err(DriverError::RolledBack {
        statement_index,
        source,
    }) = &outcome
    else {
        panic!("{outcome:?}");
    };
    assert_eq!(*statement_index, 1);
    let DriverError::Server(diagnostics) = source.as_ref() else {
        panic!("{source:?}");
    };
    assert_eq!(
        diagnostics.code,
        Some(ServerCode::Sqlite {
            primary: 19,
            extended: 787
        })
    );
    assert!(
        diagnostics.message.contains("1 rows of children") && diagnostics.message.contains("parents"),
        "{}",
        diagnostics.message
    );
    let rows = query(connection.as_ref(), "SELECT count(*) FROM children WHERE id = 3").await;
    assert_eq!(rows.rows[0][0], Value::Int(0), "the row that broke the key was kept");
    connection.close().await.unwrap();
}

#[tokio::test]
async fn foreign_keys_pragma_is_on_after_commit_and_after_rollback() {
    let file = TestFile::new().await;
    let connection = file.open().await;
    apply(connection.as_ref(), &PARENTS_AND_CHILDREN).await.unwrap();
    assert!(foreign_keys_on(connection.as_ref()).await);

    let committed = connection
        .write_batch(&suspended(&["INSERT INTO children VALUES (1, 1)"], Vec::new()), call())
        .await;
    let after_commit = foreign_keys_on(connection.as_ref()).await;
    let failed = connection
        .write_batch(&suspended(&["INSERT INTO nowhere VALUES (1)"], Vec::new()), call())
        .await;
    let after_rollback = foreign_keys_on(connection.as_ref()).await;

    assert!(committed.is_ok(), "{committed:?}");
    assert!(after_commit, "foreign keys stayed off after a commit");
    assert!(matches!(failed, Err(DriverError::RolledBack { .. })), "{failed:?}");
    assert!(after_rollback, "foreign keys stayed off after a rollback");
    let enforced = apply(connection.as_ref(), &["INSERT INTO children VALUES (2, 404)"]).await;
    assert!(enforced.is_err(), "a violating insert went through: {enforced:?}");
    connection.close().await.unwrap();
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn write_batch_takes_write_lock_before_probe() {
    let file = TestFile::new().await;
    let settings = WorkspaceSettings {
        lock_timeout: Duration::from_millis(300),
        ..WorkspaceSettings::workspace(false)
    };
    let connection = connect(file.endpoint(), settings).await.unwrap();
    apply(
        connection.as_ref(),
        &[
            "CREATE TABLE t (id INTEGER PRIMARY KEY, a TEXT)",
            "INSERT INTO t VALUES (1, 'x')",
        ],
    )
    .await
    .unwrap();
    let mut holder = SqliteConnection::connect_with(&SqliteConnectOptions::new().filename(&file.path))
        .await
        .unwrap();
    holder.execute("BEGIN IMMEDIATE").await.unwrap();

    let started = Instant::now();
    let outcome = apply(
        connection.as_ref(),
        &["UPDATE t SET a = 'y' WHERE id = 1", "INSERT INTO t VALUES (2, 'z')"],
    )
    .await;
    let waited = started.elapsed();
    holder.execute("ROLLBACK").await.unwrap();
    holder.close().await.unwrap();

    assert!(matches!(outcome, Err(DriverError::Busy)), "{outcome:?}");
    assert!(waited >= Duration::from_millis(250), "busy after only {waited:?}");
    let rows = query(connection.as_ref(), "SELECT a FROM t ORDER BY id").await;
    assert_eq!(
        rows.rows,
        vec![vec![Value::Text("x".to_owned())]],
        "a write landed in part"
    );
    connection.close().await.unwrap();
}
