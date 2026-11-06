//! Where an editor result's columns come from: ClickHouse reports nothing, so the driver resolves the statement's table
//! in the tab's own session.

use tablepro_core::column::ColumnOrigin;
use tablepro_core::{EditorSession, ResultEvent, TableRef};

use crate::support::{DATABASE, Events, connect, quoted, run_ok, session, setup, start, table, unique};

fn origin(table: &TableRef, column: &str) -> Option<ColumnOrigin> {
    Some(ColumnOrigin::new(table.clone(), column))
}

fn origins(events: &Events) -> Vec<Option<ColumnOrigin>> {
    events
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

async fn traced(editor: &dyn EditorSession, sql: &str) -> Vec<Option<ColumnOrigin>> {
    origins(&run_ok(editor, sql).await)
}

#[tokio::test]
#[ignore = "requires docker"]
async fn columns_read_straight_from_a_table_name_it() {
    let fixture = start().await;
    let connection = connect(&fixture, false).await;
    let name = unique("origin");
    let other = unique("elsewhere");
    setup(
        connection.as_ref(),
        &[
            &format!(
                "CREATE TABLE {} (id UInt64, a String, b Int32) ENGINE = MergeTree ORDER BY id",
                quoted(&name)
            ),
            &format!("INSERT INTO {} VALUES (1, 'one', 10)", quoted(&name)),
            &format!("CREATE DATABASE {}", quoted(&other)),
            &format!(
                "CREATE TABLE {}.t2 (id UInt64, c String) ENGINE = MergeTree ORDER BY id",
                quoted(&other)
            ),
        ],
    )
    .await;
    let editor = session(connection.as_ref()).await;
    let t = table(&name);
    let t2 = TableRef::new(Some(other.clone()), "t2");
    let from = quoted(&name);

    assert_eq!(
        traced(editor.as_ref(), &format!("SELECT * FROM {from}")).await,
        vec![origin(&t, "id"), origin(&t, "a"), origin(&t, "b")]
    );
    assert_eq!(
        traced(editor.as_ref(), &format!("SELECT a AS x, id FROM {from}")).await,
        vec![origin(&t, "a"), origin(&t, "id")]
    );
    assert_eq!(
        traced(editor.as_ref(), &format!("SELECT id, b + 1 AS next, _part FROM {from}")).await,
        vec![origin(&t, "id"), None, None],
        "an expression and a virtual column are none of the table's columns"
    );
    assert_eq!(
        traced(editor.as_ref(), &format!("SELECT * FROM {DATABASE}.{from}")).await,
        vec![origin(&t, "id"), origin(&t, "a"), origin(&t, "b")]
    );
    assert_eq!(
        traced(editor.as_ref(), &format!("SELECT * FROM {}.t2", quoted(&other))).await,
        vec![origin(&t2, "id"), origin(&t2, "c")]
    );
    run_ok(editor.as_ref(), &format!("USE {}", quoted(&other))).await;
    assert_eq!(
        traced(editor.as_ref(), "SELECT c, id FROM t2").await,
        vec![origin(&t2, "c"), origin(&t2, "id")],
        "an unqualified name is the session's current database's"
    );
    editor.close().await;
    connection.close().await.expect("a close");
}

#[tokio::test]
#[ignore = "requires docker"]
async fn a_view_a_temporary_table_or_an_unkeyed_engine_is_not_traced() {
    let fixture = start().await;
    let connection = connect(&fixture, false).await;
    let name = unique("origin");
    let view = unique("view");
    let memory = unique("memory");
    setup(
        connection.as_ref(),
        &[
            &format!(
                "CREATE TABLE {} (id UInt64, a String) ENGINE = MergeTree ORDER BY id",
                quoted(&name)
            ),
            &format!("CREATE VIEW {} AS SELECT id, a FROM {}", quoted(&view), quoted(&name)),
            &format!("CREATE TABLE {} (id UInt64) ENGINE = Memory", quoted(&memory)),
        ],
    )
    .await;
    let editor = session(connection.as_ref()).await;

    assert_eq!(
        traced(editor.as_ref(), &format!("SELECT * FROM {}", quoted(&view))).await,
        vec![None, None]
    );
    assert_eq!(
        traced(editor.as_ref(), &format!("SELECT * FROM {}", quoted(&memory))).await,
        vec![None]
    );
    run_ok(editor.as_ref(), "CREATE TEMPORARY TABLE scratch (x UInt8)").await;
    assert_eq!(traced(editor.as_ref(), "SELECT x FROM scratch").await, vec![None]);
    // A temporary table takes an unqualified name before the database's table of the same name.
    run_ok(
        editor.as_ref(),
        &format!("CREATE TEMPORARY TABLE {} (z UInt8)", quoted(&name)),
    )
    .await;
    assert_eq!(
        traced(editor.as_ref(), &format!("SELECT * FROM {}", quoted(&name))).await,
        vec![None]
    );
    editor.close().await;
    connection.close().await.expect("a close");
}
