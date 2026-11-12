//! Where an editor result's columns come from: DuckDB reports nothing, so the driver resolves the statement's table on
//! the tab's own connection.

use std::sync::Arc;

use tablepro_core::column::ColumnOrigin;
use tablepro_core::meta::TableRef;
use tablepro_core::{Connection, EditorSession, ResultEvent, RunEnd, TransactionState};

use crate::support::{Collected, TestFile, run, session};

const SCHEMA: &str = "CREATE TABLE t (id INTEGER PRIMARY KEY, a VARCHAR, b INTEGER); \
                      INSERT INTO t VALUES (1, 'one', 10); \
                      CREATE VIEW v AS SELECT * FROM t; \
                      CREATE SCHEMA sales; \
                      CREATE TABLE sales.orders (id INTEGER PRIMARY KEY, total INTEGER); \
                      CREATE TABLE \"MixedCase\" (\"Id\" INTEGER PRIMARY KEY, \"Some Col\" VARCHAR)";

fn main_table(name: &str) -> TableRef {
    TableRef::new(Some("main".to_owned()), name)
}

fn origin(table: &TableRef, column: &str) -> Option<ColumnOrigin> {
    Some(ColumnOrigin::new(table.clone(), column))
}

// The columns of the run's last result set.
fn origins(collected: &Collected) -> Vec<Option<ColumnOrigin>> {
    collected
        .events()
        .into_iter()
        .filter_map(|event| match event {
            ResultEvent::ResultSetStarted { columns } => {
                Some(columns.iter().map(|column| column.origin.clone()).collect())
            }
            _ => None,
        })
        .next_back()
        .expect("a result set")
}

async fn traced(editor: &dyn EditorSession, sql: &str) -> Vec<Option<ColumnOrigin>> {
    let (summary, collected) = run(editor, sql).await;
    assert_eq!(summary.end, RunEnd::Completed, "{sql}");
    origins(&collected)
}

async fn ready(file: &TestFile) -> (Arc<dyn Connection>, Arc<dyn EditorSession>) {
    let connection = file.open().await;
    let editor = session(connection.as_ref()).await;
    let (summary, _) = run(editor.as_ref(), SCHEMA).await;
    assert_eq!(summary.end, RunEnd::Completed);
    (connection, editor)
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn columns_read_straight_from_a_table_name_it() {
    let file = TestFile::new();
    let (connection, editor) = ready(&file).await;
    let t = main_table("t");

    assert_eq!(
        traced(editor.as_ref(), "SELECT * FROM t").await,
        vec![origin(&t, "id"), origin(&t, "a"), origin(&t, "b")]
    );
    assert_eq!(
        traced(editor.as_ref(), "SELECT a AS x, id FROM t").await,
        vec![origin(&t, "a"), origin(&t, "id")]
    );
    assert_eq!(
        traced(editor.as_ref(), "SELECT id, b + 1 AS next FROM t").await,
        vec![origin(&t, "id"), None]
    );
    assert_eq!(
        traced(editor.as_ref(), "SELECT rowid, ID FROM T").await,
        vec![None, origin(&t, "id")],
        "rowid is no column of the table, and a name in another case is the catalogue's column"
    );
    let mixed = main_table("MixedCase");
    assert_eq!(
        traced(editor.as_ref(), "SELECT * FROM mixedcase").await,
        vec![origin(&mixed, "Id"), origin(&mixed, "Some Col")]
    );
    editor.close().await;
    connection.close().await.unwrap();
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_table_in_another_schema_is_named_with_it() {
    let file = TestFile::new();
    let (connection, editor) = ready(&file).await;
    let orders = TableRef::new(Some("sales".to_owned()), "orders");

    assert_eq!(
        traced(editor.as_ref(), "SELECT * FROM sales.orders").await,
        vec![origin(&orders, "id"), origin(&orders, "total")]
    );
    assert_eq!(
        traced(editor.as_ref(), "USE sales; SELECT total, id FROM orders").await,
        vec![origin(&orders, "total"), origin(&orders, "id")]
    );
    editor.close().await;
    connection.close().await.unwrap();
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_view_a_temporary_table_or_another_database_is_not_traced() {
    let file = TestFile::new();
    let (connection, editor) = ready(&file).await;

    assert_eq!(traced(editor.as_ref(), "SELECT * FROM v").await, vec![None; 3]);
    assert_eq!(
        traced(
            editor.as_ref(),
            "CREATE TEMP TABLE scratch (id INTEGER); SELECT * FROM scratch"
        )
        .await,
        vec![None]
    );
    // A temporary table takes the name first, also as `main.t`.
    let (shadowing, _) = run(editor.as_ref(), "CREATE TEMP TABLE t (z INTEGER)").await;
    assert_eq!(shadowing.end, RunEnd::Completed);
    assert_eq!(traced(editor.as_ref(), "SELECT * FROM t").await, vec![None]);
    assert_eq!(traced(editor.as_ref(), "SELECT * FROM main.t").await, vec![None]);
    let (dropped, _) = run(editor.as_ref(), "DROP TABLE temp.main.t").await;
    assert_eq!(dropped.end, RunEnd::Completed);
    assert_eq!(
        traced(editor.as_ref(), "SELECT id FROM t").await,
        vec![origin(&main_table("t"), "id")]
    );
    let other = file.path.with_file_name("other.duckdb");
    let attaching = format!(
        "ATTACH '{}' AS other; CREATE TABLE other.w (id INTEGER PRIMARY KEY); SELECT * FROM other.w",
        other.display()
    );
    assert_eq!(traced(editor.as_ref(), &attaching).await, vec![None]);
    assert_eq!(
        traced(editor.as_ref(), "USE other; SELECT * FROM w").await,
        vec![None],
        "the table tab names the file's own catalogue"
    );
    editor.close().await;
    connection.close().await.unwrap();
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn nothing_is_looked_up_inside_a_transaction() {
    let file = TestFile::new();
    let (connection, editor) = ready(&file).await;

    assert_eq!(traced(editor.as_ref(), "BEGIN; SELECT id FROM t").await, vec![None]);
    let (open, collected) = run(editor.as_ref(), "SELECT id FROM t").await;
    assert_eq!(open.transaction_state, TransactionState::InTransaction);
    assert_eq!(origins(&collected), vec![None]);
    let (ended, _) = run(editor.as_ref(), "ROLLBACK").await;
    assert_eq!(ended.transaction_state, TransactionState::Idle);
    assert_eq!(
        traced(editor.as_ref(), "SELECT id FROM t").await,
        vec![origin(&main_table("t"), "id")]
    );
    editor.close().await;
    connection.close().await.unwrap();
}
