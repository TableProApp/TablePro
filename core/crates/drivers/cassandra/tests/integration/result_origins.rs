//! Where an editor result's columns come from: the RESULT metadata names the table, and the statement says which
//! columns are its own.

use tablepro_core::column::ColumnOrigin;
use tablepro_core::{EditorSession, ResultEvent, TableRef};

use crate::support::{CassandraServer, ScyllaServer, Server, connect, run_ok, session, setup, start, table};

const T: &str = "CREATE TABLE tablepro.t (id int PRIMARY KEY, a text, b int)";
const MIXED: &str = "CREATE TABLE tablepro.\"MyTable\" (\"Id\" int PRIMARY KEY, \"Some Col\" text)";
const BY_B: &str = "CREATE MATERIALIZED VIEW tablepro.t_by_b AS SELECT * FROM tablepro.t \
                    WHERE b IS NOT NULL AND id IS NOT NULL PRIMARY KEY (b, id)";
const ROW: &str = "INSERT INTO tablepro.t (id, a, b) VALUES (1, 'one', 10)";

fn origin(table: &TableRef, column: &str) -> Option<ColumnOrigin> {
    Some(ColumnOrigin::new(table.clone(), column))
}

async fn traced(editor: &dyn EditorSession, sql: &str) -> Vec<Option<ColumnOrigin>> {
    run_ok(editor, sql)
        .await
        .all()
        .into_iter()
        .find_map(|event| match event {
            ResultEvent::ResultSetStarted { columns } => {
                Some(columns.iter().map(|column| column.origin.clone()).collect())
            }
            _ => None,
        })
        .expect("a result set")
}

async fn columns_of_a_table_name_it_and_others_do_not<S: Server>() {
    let fixture = start::<S>().await;
    let connection = connect(&fixture, false).await;
    setup(connection.as_ref(), &[T, MIXED, BY_B, ROW]).await;
    fixture
        .cql(
            "CREATE KEYSPACE tp_other WITH replication = {'class': 'SimpleStrategy', 'replication_factor': 1};\n\
             CREATE TABLE tp_other.t2 (id int PRIMARY KEY, c text);",
        )
        .await
        .expect("a second keyspace");
    let editor = session(connection.as_ref()).await;
    let t = table("t");
    let mixed = table("MyTable");
    let t2 = TableRef::new(Some("tp_other".to_owned()), "t2");

    assert_eq!(
        traced(editor.as_ref(), "SELECT * FROM t").await,
        vec![origin(&t, "id"), origin(&t, "a"), origin(&t, "b")]
    );
    assert_eq!(
        traced(editor.as_ref(), "SELECT a AS x, ID FROM t WHERE id = 1").await,
        vec![origin(&t, "a"), origin(&t, "id")]
    );
    assert_eq!(
        traced(editor.as_ref(), "SELECT * FROM \"MyTable\"").await,
        vec![origin(&mixed, "Id"), origin(&mixed, "Some Col")]
    );
    assert_eq!(
        traced(editor.as_ref(), "SELECT * FROM tp_other.t2").await,
        vec![origin(&t2, "id"), origin(&t2, "c")]
    );
    assert_eq!(
        traced(editor.as_ref(), "SELECT id, writetime(a) FROM t").await,
        vec![None, None],
        "a function is no column, and its statement reads the table through it"
    );
    assert_eq!(
        traced(editor.as_ref(), "SELECT * FROM t_by_b").await,
        vec![None, None, None],
        "a materialized view takes no writes"
    );
    assert_eq!(
        traced(editor.as_ref(), "SELECT cluster_name FROM system.local").await,
        vec![None]
    );
    editor.close().await;
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
#[ignore = "requires docker"]
async fn cassandra_result_columns_name_their_table() {
    columns_of_a_table_name_it_and_others_do_not::<CassandraServer>().await;
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
#[ignore = "requires docker"]
async fn scylla_result_columns_name_their_table() {
    columns_of_a_table_name_it_and_others_do_not::<ScyllaServer>().await;
}
