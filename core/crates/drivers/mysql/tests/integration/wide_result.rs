use tablepro_core::{ResultEvent, RowLimit};

use crate::support::{CALL, Events, FLAVOURS, connect, run_ok, session, start, statement, text, within};

// 4,096 is MySQL's limit for a table, not for a SELECT, and sqlx-mysql 0.9.1 refused a wider set (core ADR 0042).
const WIDTH: usize = 4_097;

fn wide_select() -> String {
    let items: Vec<String> = (1..=WIDTH).map(|n| format!("{n} AS c{n}")).collect();
    format!("SELECT {}", items.join(", "))
}

fn expected_names() -> Vec<String> {
    (1..=WIDTH).map(|n| format!("c{n}")).collect()
}

fn expected_values() -> Vec<String> {
    (1..=WIDTH).map(|n| n.to_string()).collect()
}

fn started_names(events: &Events) -> Vec<Vec<String>> {
    events
        .all()
        .into_iter()
        .filter_map(|event| match event {
            ResultEvent::ResultSetStarted { columns } => {
                Some(columns.iter().map(|column| column.name.clone()).collect())
            }
            _ => None,
        })
        .collect()
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
#[ignore = "requires docker"]
async fn a_select_of_4097_columns_reads_every_column() {
    let sql = wide_select();
    for flavour in FLAVOURS {
        let fixture = start(flavour).await;
        let connection = connect(&fixture, false).await;

        let read = connection
            .query_bound(&statement(&sql), RowLimit::EDITOR_DEFAULT, within(CALL))
            .await
            .expect("a prepared read of 4,097 columns");
        let names: Vec<String> = read.columns.iter().map(|column| column.name.clone()).collect();
        assert_eq!(names, expected_names(), "{flavour:?}: prepared");
        let values: Vec<Vec<String>> = read.rows.iter().map(|row| row.iter().map(text).collect()).collect();
        assert_eq!(values, [expected_values()], "{flavour:?}: prepared");

        let editor = session(connection.as_ref()).await;
        let events = run_ok(editor.as_ref(), &sql).await;
        assert_eq!(started_names(&events), [expected_names()], "{flavour:?}: text");
        let values: Vec<Vec<String>> = events.rows().iter().map(|row| row.iter().map(text).collect()).collect();
        assert_eq!(values, [expected_values()], "{flavour:?}: text");

        editor.close().await;
        connection.close().await.expect("a close");
    }
}
