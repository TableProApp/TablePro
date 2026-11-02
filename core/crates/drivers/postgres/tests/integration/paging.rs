//! Paging a table the way the browse tab does: past the edge row's key,
//! or for a table with no key through heap block windows, so no page
//! sorts the whole table.

use tablepro_core::browse::{PageRead, PageRequest, PagingMode, build_page, read_page};
use tablepro_core::filter::FilterSet;
use tablepro_core::meta::{CtidWindow, PagePosition, RowIdentity, TableRef};
use tablepro_core::{ColumnInfo, Connection, RowLimit, Value};

use crate::support::{CALL, connect, setup, start, statement, within};

type Failure = Box<dyn std::error::Error + Send + Sync>;

const PAGE: u64 = 1_000;

struct Table {
    table: TableRef,
    columns: Vec<ColumnInfo>,
    identity: RowIdentity,
}

impl Table {
    async fn read(connection: &dyn Connection, name: &str) -> Self {
        let table = TableRef::new(Some("public".to_owned()), name);
        let columns = connection
            .fetch_columns(&table, within(CALL))
            .await
            .expect("the columns");
        let identity = connection
            .row_identity(&table, within(CALL))
            .await
            .expect("the identity");
        Self {
            table,
            columns,
            identity,
        }
    }

    fn request<'a>(&'a self, filter: &'a FilterSet, position: &'a PagePosition) -> PageRequest<'a> {
        PageRequest {
            table: &self.table,
            columns: &self.columns,
            filter,
            sort: &[],
            identity: &self.identity,
            position,
            limit: PAGE,
        }
    }

    async fn page(&self, connection: &dyn Connection, position: &PagePosition) -> PageRead {
        let filter = FilterSet::default();
        read_page::<Failure>(connection, &self.request(&filter, position), &within(CALL))
            .await
            .expect("a page")
    }

    /// What the server plans for `position`'s statement.
    async fn plan(&self, connection: &dyn Connection, position: &PagePosition) -> String {
        let filter = FilterSet::default();
        let spec = build_page(&*connection.dialect(), &self.request(&filter, position)).expect("a page query");
        let explain = spec.statement.wrapped("EXPLAIN ", "");
        connection
            .query_bound(&explain, RowLimit::EDITOR_DEFAULT, within(CALL))
            .await
            .expect("the plan")
            .rows
            .iter()
            .filter_map(|row| match row.first() {
                Some(Value::Text(line)) => Some(line.clone()),
                _ => None,
            })
            .collect::<Vec<_>>()
            .join("\n")
    }
}

async fn everything(connection: &dyn Connection, sql: &str) -> Vec<Value> {
    connection
        .query_bound(&statement(sql), RowLimit::new(100_000).expect("a limit"), within(CALL))
        .await
        .expect("the whole table")
        .rows
        .into_iter()
        .filter_map(|row| row.into_iter().next())
        .collect()
}

fn numbers(read: &PageRead) -> Vec<Value> {
    read.result.rows.iter().filter_map(|row| row.first().cloned()).collect()
}

/// Every page from the first, each read past the last row of the one
/// before.
async fn forward(table: &Table, connection: &dyn Connection) -> Vec<Value> {
    let mut seen = Vec::new();
    let mut position = PagePosition::First;
    loop {
        let read = table.page(connection, &position).await;
        seen.extend(numbers(&read));
        if (read.result.rows.len() as u64) < PAGE {
            return seen;
        }
        position = read.next.expect("a full page names the page after it");
    }
}

/// Every page from the last, each read back from the first row of the
/// one after, down to the first page.
async fn backward(table: &Table, connection: &dyn Connection, expected: &[Value]) {
    let mut end = expected.len();
    let mut position = PagePosition::Last;
    loop {
        let read = table.page(connection, &position).await;
        let rows = numbers(&read);
        if read.position == PagePosition::First {
            assert_eq!(rows, expected[..rows.len()], "the first page, reached going back");
            return;
        }
        assert_eq!(
            rows,
            expected[end - rows.len()..end],
            "a page read backward ending at row {end}"
        );
        end -= rows.len();
        position = read.previous.expect("a page names the page before it");
    }
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
#[ignore = "requires docker"]
async fn a_table_with_no_key_pages_through_block_windows() {
    let fixture = start().await;
    let connection = connect(&fixture, false).await;
    // Dead rows leave windows short of a page, so the walk widens them.
    setup(
        connection.as_ref(),
        &[
            "CREATE TABLE heap (n int NOT NULL, note text)",
            "INSERT INTO heap SELECT n, repeat('x', n % 90) FROM generate_series(1, 60000) AS n",
            "DELETE FROM heap WHERE n % 7 = 0 OR n BETWEEN 20000 AND 31000",
            "ANALYZE heap",
        ],
    )
    .await;
    let table = Table::read(connection.as_ref(), "heap").await;
    // Rows of varied size fill gaps left in earlier blocks, so the heap
    // is not in insert order; sorting it whole is the order to match.
    let expected = everything(connection.as_ref(), "SELECT n FROM heap ORDER BY ctid").await;
    assert_eq!(expected.len(), 41_999);

    assert_eq!(forward(&table, connection.as_ref()).await, expected);
    backward(&table, connection.as_ref(), &expected).await;

    let first = table.page(connection.as_ref(), &PagePosition::First).await;
    assert_eq!(first.mode, PagingMode::CtidWindow);
    let window = PagePosition::CtidWindow(CtidWindow {
        after: Some((40, 3)),
        before: Some((60, 0)),
        backward: false,
    });
    let plan = table.plan(connection.as_ref(), &window).await;
    assert!(plan.contains("Tid Range Scan"), "{plan}");
    assert!(!plan.contains("Seq Scan"), "a window read the whole table:\n{plan}");
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
#[ignore = "requires docker"]
async fn a_keyed_table_pages_past_the_edge_key_to_its_last_page() {
    let fixture = start().await;
    let connection = connect(&fixture, false).await;
    setup(
        connection.as_ref(),
        &[
            "CREATE TABLE keyed (n int PRIMARY KEY, note text)",
            "INSERT INTO keyed SELECT n, 'row' FROM generate_series(1, 25500) AS n",
            "ANALYZE keyed",
        ],
    )
    .await;
    let table = Table::read(connection.as_ref(), "keyed").await;
    let expected: Vec<Value> = (1..=25_500).map(Value::Int).collect();

    assert_eq!(forward(&table, connection.as_ref()).await, expected);
    backward(&table, connection.as_ref(), &expected).await;

    let last = table.page(connection.as_ref(), &PagePosition::Last).await;
    let previous = last.previous.clone().expect("the page before the last");
    for position in [PagePosition::Last, previous] {
        let plan = table.plan(connection.as_ref(), &position).await;
        assert!(plan.contains("Index Scan Backward"), "{position:?}:\n{plan}");
        assert!(!plan.contains("Sort"), "{position:?} sorted the table:\n{plan}");
    }
}
