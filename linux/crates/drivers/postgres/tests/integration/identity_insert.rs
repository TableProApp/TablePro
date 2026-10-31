//! Copy As INSERT and the SQL export write a saved row's number back into
//! a GENERATED ALWAYS identity, which refuses a value without
//! OVERRIDING SYSTEM VALUE.

use tablepro_core::edit::CellInput;
use tablepro_core::export::{render_inserts, render_sql_insert};
use tablepro_core::{Connection, RowLimit, TableRef, Value};

use crate::support::{CALL, connect, rows, run_ok, session, setup, start, statement, within};

const SHAPE: &str = "(id int GENERATED ALWAYS AS IDENTITY PRIMARY KEY, name text)";
const SOURCE_ROWS: &str = "SELECT id, name FROM public.source ORDER BY id DESC";

fn public(name: &str) -> TableRef {
    TableRef::new(Some("public".to_owned()), name)
}

/// `source` holding the rows numbered 5 and 2, and an empty table of its
/// shape to write them into. Numbers the server would not give a new row
/// show the copy kept them.
async fn tables(connection: &dyn Connection, copy: &str) -> Vec<Vec<Value>> {
    setup(
        connection,
        &[
            &format!("CREATE TABLE public.source {SHAPE}"),
            &format!("CREATE TABLE public.{copy} {SHAPE}"),
            "INSERT INTO public.source (name) VALUES ('a'), ('b'), ('c'), ('d'), ('e')",
            "DELETE FROM public.source WHERE id NOT IN (2, 5)",
        ],
    )
    .await;
    rows(connection, SOURCE_ROWS).await
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
#[ignore = "requires docker"]
async fn a_copied_row_keeps_its_number_in_a_generated_always_identity() {
    let fixture = start().await;
    let connection = connect(&fixture, false).await;
    let saved = tables(connection.as_ref(), "copied").await;
    let columns = connection
        .fetch_columns(&public("source"), within(CALL))
        .await
        .expect("the columns");
    assert!(
        columns
            .iter()
            .any(|column| column.name == "id" && column.is_auto_increment),
        "{columns:?}"
    );
    let cells = |row: &Vec<Value>| row.iter().cloned().map(CellInput::Value).collect::<Vec<_>>();
    let draft = vec![CellInput::Default, CellInput::Value(Value::Text("new".to_owned()))];
    let copied = [cells(&saved[0]), draft, cells(&saved[1])];

    let sql = render_inserts(connection.dialect().as_ref(), &public("copied"), &columns, &copied).expect("the copy");
    let session = session(connection.as_ref()).await;
    run_ok(session.as_ref(), &sql).await;

    assert_eq!(
        rows(
            connection.as_ref(),
            "SELECT id, name FROM public.copied WHERE name <> 'new' ORDER BY id DESC"
        )
        .await,
        saved
    );
    assert_eq!(
        rows(connection.as_ref(), "SELECT name FROM public.copied WHERE name = 'new'").await,
        vec![vec![Value::Text("new".to_owned())]],
        "the draft row took a number from the server"
    );
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
#[ignore = "requires docker"]
async fn an_exported_row_keeps_its_number_in_a_generated_always_identity() {
    let fixture = start().await;
    let connection = connect(&fixture, false).await;
    let saved = tables(connection.as_ref(), "exported").await;
    let read = connection
        .query_bound(&statement(SOURCE_ROWS), RowLimit::EDITOR_DEFAULT, within(CALL))
        .await
        .expect("the read");

    let sql = render_sql_insert(
        connection.dialect().as_ref(),
        &public("exported"),
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
            "SELECT id, name FROM public.exported ORDER BY id DESC"
        )
        .await,
        saved
    );
}
