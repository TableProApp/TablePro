//! Copy As INSERT and the SQL export write a saved row's number back into
//! an IDENTITY column, which refuses a value unless IDENTITY_INSERT is on
//! and refuses a row without one while it is.

use tablepro_core::edit::CellInput;
use tablepro_core::export::{render_inserts, render_sql_insert};
use tablepro_core::{Connection, RowLimit, RunEnd, Value};

use crate::support::{CALL, columns, connect, dbo, rows, run, run_ok, session, setup, start, statement, within};

const SHAPE: &str = "(id int IDENTITY(1,1) PRIMARY KEY, name nvarchar(20))";
const SOURCE_ROWS: &str = "SELECT id, name FROM dbo.source ORDER BY id DESC";

/// `source` holding the rows numbered 5 and 2, and an empty table of its
/// shape to write them into. Numbers the server would not give a new row
/// show the copy kept them.
async fn tables(connection: &dyn Connection, copy: &str) -> Vec<Vec<Value>> {
    setup(
        connection,
        &[
            &format!("CREATE TABLE dbo.source {SHAPE}"),
            &format!("CREATE TABLE dbo.{copy} {SHAPE}"),
            "INSERT INTO dbo.source (name) VALUES ('a'), ('b'), ('c'), ('d'), ('e')",
            "DELETE FROM dbo.source WHERE id NOT IN (2, 5)",
        ],
    )
    .await;
    rows(connection, SOURCE_ROWS).await
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
#[ignore = "requires docker"]
async fn a_copied_row_keeps_its_number_in_an_identity_column() {
    let fixture = start().await;
    let connection = connect(&fixture, false).await;
    let saved = tables(connection.as_ref(), "copied").await;
    let catalog = columns(connection.as_ref(), &dbo("source")).await;
    assert!(
        catalog
            .iter()
            .any(|column| column.name == "id" && column.is_auto_increment),
        "{catalog:?}"
    );
    let cells = |row: &Vec<Value>| row.iter().cloned().map(CellInput::Value).collect::<Vec<_>>();
    // Between the saved rows, so IDENTITY_INSERT has to be off for it and
    // on again after.
    let draft = vec![CellInput::Default, CellInput::Value(Value::Text("new".to_owned()))];
    let copied = [cells(&saved[0]), draft, cells(&saved[1])];

    let sql = render_inserts(connection.dialect().as_ref(), &dbo("copied"), &catalog, &copied).expect("the copy");
    let session = session(connection.as_ref()).await;
    run_ok(session.as_ref(), &sql).await;

    assert_eq!(
        rows(
            connection.as_ref(),
            "SELECT id, name FROM dbo.copied WHERE name <> 'new' ORDER BY id DESC"
        )
        .await,
        saved
    );
    assert_eq!(
        rows(connection.as_ref(), "SELECT name FROM dbo.copied WHERE name = 'new'").await,
        vec![vec![Value::Text("new".to_owned())]],
        "the draft row took a number from the server"
    );
}

/// Under XACT_ABORT ON the duplicate key ends its batch before the rows
/// after it. The session must still take a row without a number, and
/// IDENTITY_INSERT on another table, which SQL Server refuses while one
/// table of the session has it on.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
#[ignore = "requires docker"]
async fn a_copy_that_fails_partway_still_turns_identity_insert_off() {
    let fixture = start().await;
    let connection = connect(&fixture, false).await;
    let saved = tables(connection.as_ref(), "taken").await;
    setup(
        connection.as_ref(),
        &["SET IDENTITY_INSERT dbo.taken ON; INSERT INTO dbo.taken (id, name) VALUES (5, 'x'); SET IDENTITY_INSERT dbo.taken OFF"],
    )
    .await;
    let catalog = columns(connection.as_ref(), &dbo("source")).await;
    let copied: Vec<Vec<CellInput>> = saved
        .iter()
        .map(|row| row.iter().cloned().map(CellInput::Value).collect())
        .collect();
    let sql = render_inserts(connection.dialect().as_ref(), &dbo("taken"), &catalog, &copied).expect("the copy");
    let session = session(connection.as_ref()).await;

    let (summary, _) = run(session.as_ref(), &format!("SET XACT_ABORT ON;\n{sql}")).await;

    assert!(
        matches!(summary.end, RunEnd::Failed(_)),
        "the duplicate key failed the run"
    );
    run_ok(
        session.as_ref(),
        "INSERT INTO dbo.taken (name) VALUES ('after'); SET IDENTITY_INSERT dbo.source ON; SET IDENTITY_INSERT dbo.source OFF",
    )
    .await;
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
#[ignore = "requires docker"]
async fn an_exported_row_keeps_its_number_in_an_identity_column() {
    let fixture = start().await;
    let connection = connect(&fixture, false).await;
    let saved = tables(connection.as_ref(), "exported").await;
    let read = connection
        .query_bound(&statement(SOURCE_ROWS), RowLimit::EDITOR_DEFAULT, within(CALL))
        .await
        .expect("the read");

    let sql = render_sql_insert(
        connection.dialect().as_ref(),
        &dbo("exported"),
        &read.columns,
        &[],
        &["id".to_owned()],
        &read.rows,
    );
    let session = session(connection.as_ref()).await;
    run_ok(session.as_ref(), &sql).await;

    assert_eq!(
        rows(
            connection.as_ref(),
            "SELECT id, name FROM dbo.exported ORDER BY id DESC"
        )
        .await,
        saved
    );
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
#[ignore = "requires docker"]
async fn a_copied_row_leaves_a_temporal_tables_period_to_the_server() {
    let fixture = start().await;
    let connection = connect(&fixture, false).await;
    let shape = "(id int PRIMARY KEY, name nvarchar(20), \
        valid_from datetime2 GENERATED ALWAYS AS ROW START NOT NULL, \
        valid_to datetime2 GENERATED ALWAYS AS ROW END NOT NULL, \
        PERIOD FOR SYSTEM_TIME (valid_from, valid_to))";
    setup(
        connection.as_ref(),
        &[&format!(
            "CREATE TABLE dbo.versioned {shape} WITH (SYSTEM_VERSIONING = ON)"
        )],
    )
    .await;
    let catalog = columns(connection.as_ref(), &dbo("versioned")).await;
    assert!(
        catalog
            .iter()
            .filter(|column| column.name.starts_with("valid_"))
            .all(|column| column.is_generated),
        "{catalog:?}"
    );
    let row = vec![
        CellInput::Value(Value::Int(1)),
        CellInput::Value(Value::Text("a".to_owned())),
        CellInput::Value(Value::Text("2026-01-01 00:00:00".to_owned())),
        CellInput::Value(Value::Text("9999-12-31 23:59:59.9999999".to_owned())),
    ];

    let sql = render_inserts(connection.dialect().as_ref(), &dbo("versioned"), &catalog, &[row]).expect("the copy");
    let session = session(connection.as_ref()).await;
    run_ok(session.as_ref(), &sql).await;

    assert_eq!(
        rows(connection.as_ref(), "SELECT id, name FROM dbo.versioned").await,
        vec![vec![Value::Int(1), Value::Text("a".to_owned())]]
    );
}
