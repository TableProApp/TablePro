//! Editor sessions: one connection per tab, batches as SQL batches, so
//! USE, SET and an open transaction last from one run to the next.

use tablepro_core::column::ColumnOrigin;
use tablepro_core::{ResultEvent, RowLimit, RunEnd, RunOptions, TableRef, TransactionState, Truncation, Value};
use tokio_util::sync::CancellationToken;

use crate::support::{Events, connect, run, run_ok, run_with, scalar, session, setup, start};

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
#[ignore = "requires docker"]
async fn use_database_persists_across_runs() {
    let fixture = start().await;
    let connection = connect(&fixture, false).await;
    let session = session(connection.as_ref()).await;

    run_ok(session.as_ref(), "USE tempdb").await;
    let database = run_ok(session.as_ref(), "SELECT DB_NAME()").await.rows();

    assert_eq!(database, vec![vec![Value::Text("tempdb".to_owned())]]);
    assert_eq!(
        session.database().as_deref(),
        Some("tempdb"),
        "where the session says it is"
    );
}

/// The editor bar's move: a bracketed name carries a `]`, and a database
/// the server refuses leaves the session where it was.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
#[ignore = "requires docker"]
async fn a_session_moves_to_a_database_by_its_name() {
    let fixture = start().await;
    let connection = connect(&fixture, false).await;
    let session = session(connection.as_ref()).await;
    // CREATE DATABASE runs outside a transaction, as the editor runs it.
    run_ok(
        session.as_ref(),
        "IF DB_ID(N'odd]name') IS NULL CREATE DATABASE [odd]]name]",
    )
    .await;
    let options = || tablepro_core::CallOptions::new(None, CancellationToken::new());

    session.use_database("odd]name", options()).await.expect("a move");
    let database = run_ok(session.as_ref(), "SELECT DB_NAME()").await.rows();
    assert_eq!(database, vec![vec![Value::Text("odd]name".to_owned())]]);
    assert_eq!(session.database().as_deref(), Some("odd]name"));

    let refused = session.use_database("no_such_database", options()).await;
    assert!(refused.is_err(), "{refused:?}");
    let database = run_ok(session.as_ref(), "SELECT DB_NAME()").await.rows();
    assert_eq!(database, vec![vec![Value::Text("odd]name".to_owned())]]);
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
#[ignore = "requires docker"]
async fn begin_tran_insert_big_select_commit_persists() {
    let fixture = start().await;
    let connection = connect(&fixture, false).await;
    setup(connection.as_ref(), &["CREATE TABLE dbo.t (id int PRIMARY KEY)"]).await;
    let session = session(connection.as_ref()).await;

    run_ok(session.as_ref(), "BEGIN TRANSACTION").await;
    run_ok(session.as_ref(), "INSERT INTO dbo.t VALUES (1)").await;
    let limited = RunOptions::new(CancellationToken::new()).with_row_limit(RowLimit::new(10).expect("a limit"));
    let (big, _) = run_with(
        session.as_ref(),
        "SELECT TOP (50000) a.object_id FROM sys.all_objects a CROSS JOIN sys.all_objects b",
        limited,
    )
    .await;
    assert_eq!(big.transaction_state, TransactionState::InTransaction);
    run_ok(session.as_ref(), "COMMIT TRANSACTION").await;

    assert_eq!(
        scalar(connection.as_ref(), "SELECT COUNT_BIG(*) FROM dbo.t").await,
        Value::Int(1)
    );
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
#[ignore = "requires docker"]
async fn limit_100_over_200k_rows_read_past_limit_total() {
    let fixture = start().await;
    let connection = connect(&fixture, false).await;
    let session = session(connection.as_ref()).await;
    let limited = RunOptions::new(CancellationToken::new()).with_row_limit(RowLimit::new(100).expect("a limit"));

    let (_, events) = run_with(
        session.as_ref(),
        "SELECT TOP (200000) a.object_id FROM sys.all_objects a CROSS JOIN sys.all_objects b",
        limited,
    )
    .await;

    assert_eq!(events.rows().len(), 100);
    assert_eq!(
        events.finished(),
        vec![ResultEvent::ResultSetFinished {
            retained: 100,
            total_rows: Some(200_000),
            truncation: Truncation::ReadPastLimit,
        }]
    );
}

/// A transaction an error dooms is rolled back when its batch ends, so
/// `Failed` is only ever seen inside a batch; across runs the session
/// reports the open transaction and its end.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
#[ignore = "requires docker"]
async fn transaction_state_in_transaction_and_failed() {
    let fixture = start().await;
    let connection = connect(&fixture, false).await;
    let session = session(connection.as_ref()).await;

    let (opened, _) = run(session.as_ref(), "BEGIN TRANSACTION").await;
    let (failed, _) = run(session.as_ref(), "SELECT 1/0").await;
    let (closed, _) = run(session.as_ref(), "ROLLBACK TRANSACTION").await;

    assert_eq!(opened.transaction_state, TransactionState::InTransaction);
    assert!(!failed.succeeded());
    assert_eq!(failed.transaction_state, TransactionState::InTransaction);
    assert_eq!(closed.transaction_state, TransactionState::Idle);
}

/// GO splits a script into batches, and a failed batch does not stop the
/// next one, as in sqlcmd.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
#[ignore = "requires docker"]
async fn go_batches_run_in_order_and_continue_after_an_error() {
    let fixture = start().await;
    let connection = connect(&fixture, false).await;
    let session = session(connection.as_ref()).await;

    let (summary, events) = run(
        session.as_ref(),
        "SELECT 1\nGO\nSELECT * FROM no_such_table\nGO\nSELECT 3",
    )
    .await;

    assert!(!summary.succeeded());
    assert_eq!(events.rows(), vec![vec![Value::Int(1)], vec![Value::Int(3)]]);
}

const TRACED_SCHEMA: &str = "CREATE TABLE dbo.t (id int PRIMARY KEY, a nvarchar(20), b int)
GO
INSERT INTO dbo.t VALUES (1, N'one', 10)
GO
CREATE SCHEMA [Sales Data]
GO
CREATE TABLE [Sales Data].[Orders] (order_id int PRIMARY KEY, total int)
GO
CREATE VIEW dbo.v_t AS SELECT id, a FROM dbo.t
GO
CREATE SYNONYM dbo.syn_t FOR dbo.t";

fn origins(events: &Events) -> Vec<Option<ColumnOrigin>> {
    let sets: Vec<Vec<Option<ColumnOrigin>>> = events
        .all()
        .into_iter()
        .filter_map(|event| match event {
            ResultEvent::ResultSetStarted { columns } => {
                Some(columns.iter().map(|column| column.origin.clone()).collect())
            }
            _ => None,
        })
        .collect();
    assert_eq!(sets.len(), 1, "one result set, and nothing from the describe");
    sets.into_iter().next().unwrap_or_default()
}

fn from(schema: &str, table: &str, column: &str) -> Option<ColumnOrigin> {
    Some(ColumnOrigin::new(TableRef::new(Some(schema.to_owned()), table), column))
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
#[ignore = "requires docker"]
async fn editor_results_carry_the_base_table_column_each_column_reads() {
    let fixture = start().await;
    let connection = connect(&fixture, false).await;
    let session = session(connection.as_ref()).await;
    run_ok(session.as_ref(), TRACED_SCHEMA).await;

    let every = run_ok(session.as_ref(), "SELECT * FROM t").await;
    assert_eq!(
        origins(&every),
        vec![from("dbo", "t", "id"), from("dbo", "t", "a"), from("dbo", "t", "b")]
    );
    assert_eq!(
        every.rows(),
        vec![vec![Value::Int(1), Value::Text("one".to_owned()), Value::Int(10)]]
    );

    let renamed = run_ok(session.as_ref(), "SELECT a AS x, id FROM t").await;
    assert_eq!(origins(&renamed), vec![from("dbo", "t", "a"), from("dbo", "t", "id")]);

    let expression = run_ok(session.as_ref(), "SELECT id, a + N'!' AS e FROM t").await;
    assert_eq!(origins(&expression), vec![from("dbo", "t", "id"), None]);

    // The describe adds the key the select list leaves out as a hidden row; the host finds the key missing.
    let keyless = run_ok(session.as_ref(), "SELECT a FROM t").await;
    assert_eq!(origins(&keyless), vec![from("dbo", "t", "a")]);

    let other_schema = run_ok(session.as_ref(), "SELECT * FROM [Sales Data].[Orders]").await;
    assert_eq!(
        origins(&other_schema),
        vec![
            from("Sales Data", "Orders", "order_id"),
            from("Sales Data", "Orders", "total")
        ]
    );

    run_ok(
        session.as_ref(),
        "CREATE DATABASE other\nGO\nCREATE TABLE other.dbo.t2 (id int PRIMARY KEY, b int)",
    )
    .await;
    // TableRef has no database part, so a table named through another database stays untraced.
    let three_part = run_ok(session.as_ref(), "SELECT * FROM other.dbo.t2").await;
    assert_eq!(origins(&three_part), vec![None, None]);
    // After a USE the origin is the session's own database's table; the host refuses a session in another database than the tab's.
    run_ok(session.as_ref(), "USE other").await;
    let moved = run_ok(session.as_ref(), "SELECT * FROM t2").await;
    assert_eq!(origins(&moved), vec![from("dbo", "t2", "id"), from("dbo", "t2", "b")]);
    assert_eq!(session.database().as_deref(), Some("other"));
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
#[ignore = "requires docker"]
async fn editor_results_of_a_view_synonym_temp_table_or_open_transaction_carry_no_origin() {
    let fixture = start().await;
    let connection = connect(&fixture, false).await;
    let session = session(connection.as_ref()).await;
    run_ok(session.as_ref(), TRACED_SCHEMA).await;

    // Browse mode traces both to dbo.t; the statement names another object, so the driver reports nothing.
    let view = run_ok(session.as_ref(), "SELECT * FROM v_t").await;
    assert_eq!(origins(&view), vec![None, None]);
    let synonym = run_ok(session.as_ref(), "SELECT * FROM syn_t").await;
    assert_eq!(origins(&synonym), vec![None, None, None]);

    run_ok(
        session.as_ref(),
        "CREATE TABLE #tmp (tid int PRIMARY KEY, tv nvarchar(20))",
    )
    .await;
    let temporary = run_ok(session.as_ref(), "SELECT * FROM #tmp").await;
    assert_eq!(origins(&temporary), vec![None, None]);

    run_ok(session.as_ref(), "BEGIN TRANSACTION").await;
    let (inside, events) = run(session.as_ref(), "SELECT * FROM t").await;
    assert_eq!(inside.end, RunEnd::Completed);
    assert_eq!(inside.transaction_state, TransactionState::InTransaction);
    assert_eq!(origins(&events), vec![None, None, None]);
    run_ok(session.as_ref(), "ROLLBACK TRANSACTION").await;

    run_ok(session.as_ref(), "SET IMPLICIT_TRANSACTIONS ON").await;
    let implicit = run_ok(session.as_ref(), "SELECT * FROM t").await;
    assert_eq!(origins(&implicit), vec![None, None, None]);
    run_ok(
        session.as_ref(),
        "IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION\nGO\nSET IMPLICIT_TRANSACTIONS OFF",
    )
    .await;

    let control = run_ok(session.as_ref(), "SELECT id FROM t").await;
    assert_eq!(origins(&control), vec![from("dbo", "t", "id")]);
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
#[ignore = "requires docker"]
async fn a_stop_while_a_result_is_described_cancels_the_run_and_keeps_the_session() {
    let fixture = start().await;
    let connection = connect(&fixture, false).await;
    let session = session(connection.as_ref()).await;
    run_ok(
        session.as_ref(),
        "CREATE TABLE dbo.t (id int PRIMARY KEY)\nGO\nINSERT INTO dbo.t VALUES (1)",
    )
    .await;
    let cancel = CancellationToken::new();
    cancel.cancel();

    let (stopped, events) = run_with(session.as_ref(), "SELECT * FROM t", RunOptions::new(cancel)).await;

    assert_eq!(stopped.end, RunEnd::Cancelled);
    assert!(events.rows().is_empty(), "{:?}", events.all());
    let after = run_ok(session.as_ref(), "SELECT * FROM t").await;
    assert_eq!(origins(&after), vec![from("dbo", "t", "id")]);
    assert_eq!(after.rows(), vec![vec![Value::Int(1)]]);
}
