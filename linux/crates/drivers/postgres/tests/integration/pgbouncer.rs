//! Through PgBouncer with `max_prepared_statements = 0`: nothing is
//! prepared under a name, and nothing a session sets outlives its
//! transaction on a server connection other clients share.

use std::num::NonZeroU32;
use std::sync::Arc;
use std::time::Duration;

use tablepro_core::meta::ObjectScope;
use tablepro_core::{
    Connection, DriverError, ReadOnlyRefusal, RowLimit, RunEnd, RunOptions, TlsConfig, Value, WorkspaceSettings,
    WriteKind,
};
use tablepro_test_fixtures::{PgBouncerFixture, PoolMode};
use tablepro_test_support::conformance::test_liveness;
use tokio_util::sync::CancellationToken;

use crate::support::{
    CALL, apply, connect_with, direct, options_over, password, rows, run, run_ok, run_with, scalar, session, setup,
    statement, text, within,
};

async fn through(bouncer: &PgBouncerFixture, read_only: bool) -> Arc<dyn Connection> {
    let liveness = test_liveness();
    let upstream = bouncer.upstream();
    connect_with(options_over(
        direct(bouncer.host(), bouncer.port(), &liveness),
        password(&upstream.password_credentials()),
        upstream.database(),
        TlsConfig::disabled(),
        WorkspaceSettings::workspace(read_only),
        liveness,
    ))
    .await
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
#[ignore = "requires docker"]
async fn transaction_pool_round_trip() {
    let bouncer = PgBouncerFixture::start(PoolMode::Transaction).await.expect("PgBouncer");
    let connection = through(&bouncer, false).await;
    setup(
        connection.as_ref(),
        &["CREATE TABLE t (id int PRIMARY KEY, label text)"],
    )
    .await;

    let written = apply(
        connection.as_ref(),
        WriteKind::RowChanges,
        &["INSERT INTO t VALUES (1, 'a')", "INSERT INTO t VALUES (2, 'b')"],
    )
    .await;
    let objects = connection
        .list_objects(&ObjectScope::DefaultSchema, within(CALL))
        .await
        .expect("the objects");
    let counted = connection
        .count_rows(&statement("SELECT count(*) FROM t"), within(CALL))
        .await;
    let read = rows(connection.as_ref(), "SELECT label FROM t ORDER BY id").await;
    let editor = session(connection.as_ref()).await;
    let cancel = CancellationToken::new();
    let stopper = cancel.clone();
    tokio::spawn(async move {
        tokio::time::sleep(Duration::from_millis(500)).await;
        stopper.cancel();
    });
    let (cancelled, _) = run_with(editor.as_ref(), "SELECT pg_sleep(30)", RunOptions::new(cancel)).await;

    assert_eq!(written.map(|report| report.total_rows()), Ok(Some(2)));
    assert!(objects.iter().any(|object| object.name == "t"));
    assert_eq!(counted, Ok(2));
    assert_eq!(read.iter().map(|row| text(&row[0])).collect::<Vec<_>>(), ["a", "b"]);
    assert_eq!(cancelled.end, RunEnd::Cancelled);
    run_ok(editor.as_ref(), "SELECT 1").await;
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
#[ignore = "requires docker"]
async fn transaction_pool_read_only_editor_delete_fails() {
    let bouncer = PgBouncerFixture::start(PoolMode::Transaction).await.expect("PgBouncer");
    let owner = through(&bouncer, false).await;
    setup(owner.as_ref(), &["CREATE TABLE t (id int)", "INSERT INTO t VALUES (1)"]).await;
    let reader = through(&bouncer, true).await;
    let editor = session(reader.as_ref()).await;

    let (summary, _) = run(editor.as_ref(), "DELETE FROM t").await;

    assert!(
        matches!(
            summary.end,
            RunEnd::Failed(DriverError::ReadOnly(ReadOnlyRefusal::ServerRejected(_)))
        ),
        "{:?}",
        summary.end
    );
    assert_eq!(scalar(owner.as_ref(), "SELECT count(*) FROM t").await, Value::Int(1));
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
#[ignore = "requires docker"]
async fn transaction_pool_editor_leaves_no_session_state() {
    let bouncer = PgBouncerFixture::start_with_pool_size(PoolMode::Transaction, NonZeroU32::MIN)
        .await
        .expect("PgBouncer");
    let reader = through(&bouncer, true).await;
    let editor = session(reader.as_ref()).await;
    let bounded = RunOptions::new(CancellationToken::new()).with_deadline(Some(Duration::from_secs(5)));
    for sql in ["SELECT 1", "SHOW search_path", "SELECT count(*) FROM pg_class"] {
        let (summary, _) = run_with(editor.as_ref(), sql, bounded.clone()).await;
        assert_eq!(summary.end, RunEnd::Completed, "{sql}");
    }
    let plain = through(&bouncer, false).await;
    let other = session(plain.as_ref()).await;

    let read_only = run_ok(other.as_ref(), "SHOW default_transaction_read_only").await;
    let timeout = run_ok(other.as_ref(), "SHOW statement_timeout").await;

    assert_eq!(text(&read_only.rows()[0][0]), "off");
    assert_eq!(text(&timeout.rows()[0][0]), "0");
}

/// A non-built-in column type in a result would make tokio-postgres
/// prepare its type lookup under a name, which a transaction pooler
/// hands to whichever server connection comes next. The page projects
/// such columns as text, so every read here goes through.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
#[ignore = "requires docker"]
async fn enum_citext_10000_row_flight_never_prepares() {
    let bouncer = PgBouncerFixture::start(PoolMode::Transaction).await.expect("PgBouncer");
    let connection = through(&bouncer, false).await;
    setup(
        connection.as_ref(),
        &[
            "CREATE EXTENSION IF NOT EXISTS citext",
            "CREATE TYPE mood AS ENUM ('sad', 'happy')",
            "CREATE TABLE t (id int PRIMARY KEY, feeling mood, name citext)",
            "INSERT INTO t SELECT n, 'happy', 'Name ' || n FROM generate_series(1, 10000) n",
        ],
    )
    .await;
    let table = tablepro_core::TableRef::new(Some("public".to_owned()), "t");
    let columns = connection
        .fetch_columns(&table, within(CALL))
        .await
        .expect("the columns");
    let dialect = connection.dialect();
    let projection: Vec<String> = columns.iter().map(|column| dialect.projection(column)).collect();
    let sql = format!(
        "SELECT {} FROM {} ORDER BY id",
        projection.join(", "),
        dialect.qualify(&table)
    );

    for _ in 0..3 {
        let result = connection
            .query_bound(&statement(&sql), RowLimit::new(10_000).expect("a limit"), within(CALL))
            .await
            .expect("a read through the pooler");
        assert_eq!(result.rows.len(), 10_000);
        assert!(!result.truncated);
        assert_eq!(result.rows[0][1], Value::Text("happy".to_owned()));
        assert_eq!(result.rows[0][2], Value::Text("Name 1".to_owned()));
    }
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
#[ignore = "requires docker"]
async fn session_pool_editor_state_persists() {
    let bouncer = PgBouncerFixture::start(PoolMode::Session).await.expect("PgBouncer");
    let connection = through(&bouncer, false).await;
    let editor = session(connection.as_ref()).await;

    run_ok(editor.as_ref(), "CREATE TEMP TABLE scratch AS SELECT 3 AS n").await;
    run_ok(editor.as_ref(), "BEGIN").await;
    let read = run_ok(editor.as_ref(), "SELECT n FROM scratch").await;
    run_ok(editor.as_ref(), "COMMIT").await;

    assert_eq!(text(&read.rows()[0][0]), "3");
}

/// SET LOCAL lives as long as the transaction, which a transaction
/// pooler keeps on one server connection, so the bound still applies.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
#[ignore = "requires docker"]
async fn transaction_pool_set_local_timeout_applies() {
    let bouncer = PgBouncerFixture::start(PoolMode::Transaction).await.expect("PgBouncer");
    let connection = through(&bouncer, false).await;
    let started = tokio::time::Instant::now();

    let outcome = connection
        .query_bound(
            &statement("SELECT pg_sleep(30)"),
            RowLimit::EDITOR_DEFAULT,
            within(Duration::from_secs(1)),
        )
        .await;

    assert!(
        matches!(
            outcome,
            Err(DriverError::Timeout {
                server_cancelled: true,
                ..
            })
        ),
        "{outcome:?}"
    );
    assert!(started.elapsed() < Duration::from_secs(3), "{:?}", started.elapsed());
}

/// Statement pooling refuses transaction blocks, so a save cannot run
/// there; it fails with the pooler's own words rather than hanging.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
#[ignore = "requires docker"]
async fn statement_pool_write_batch_returns_diagnostics() {
    let bouncer = PgBouncerFixture::start(PoolMode::Statement).await.expect("PgBouncer");
    let liveness = test_liveness();
    let upstream = bouncer.upstream();
    let options = options_over(
        direct(bouncer.host(), bouncer.port(), &liveness),
        password(&upstream.password_credentials()),
        upstream.database(),
        TlsConfig::disabled(),
        WorkspaceSettings::workspace(false),
        liveness,
    );
    let connection = connect_with(options).await;

    let outcome = tokio::time::timeout(
        Duration::from_secs(10),
        apply(connection.as_ref(), WriteKind::RowChanges, &["CREATE TABLE t (id int)"]),
    )
    .await
    .expect("the save answered");

    let Err(error) = outcome else {
        panic!("a save ran a transaction block under statement pooling");
    };
    assert!(
        format!("{error:?}").contains("statement pooling"),
        "the pooler's reason was lost: {error:?}"
    );
}
