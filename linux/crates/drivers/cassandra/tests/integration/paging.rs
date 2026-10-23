//! Paging a table the way the browse tab does: by the paging state the
//! server hands back, since CQL has no OFFSET and orders a scan by token.

use std::collections::BTreeSet;

use tablepro_core::browse::{PageRead, PageRequest, PagingMode, read_page};
use tablepro_core::filter::{FilterRule, FilterSet, FilterValue};
use tablepro_core::meta::{PagePosition, RowIdentity, TableRef};
use tablepro_core::{ColumnInfo, Connection, FilterOp, Value};
use tablepro_test_fixtures::CassandraFixture;

use crate::support::{CALL, CassandraServer, ScyllaServer, Server, connect, load_series, start, table, within};

type Failure = Box<dyn std::error::Error + Send + Sync>;

const PAGE: u64 = 1_000;
const ROWS: u64 = 2_500;

struct Table {
    table: TableRef,
    columns: Vec<ColumnInfo>,
    identity: RowIdentity,
}

impl Table {
    async fn read(connection: &dyn Connection, name: &str) -> Self {
        let table = table(name);
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

    async fn page(&self, connection: &dyn Connection, filter: &FilterSet, position: &PagePosition) -> PageRead {
        let request = PageRequest {
            table: &self.table,
            columns: &self.columns,
            filter,
            sort: &[],
            identity: &self.identity,
            position,
            limit: PAGE,
        };
        read_page::<Failure>(connection, &request, &within(CALL))
            .await
            .expect("a page")
    }

    /// Every page from `start`, each resumed where the one before ended.
    async fn walk(&self, connection: &dyn Connection, filter: &FilterSet, start: PagePosition) -> Vec<i64> {
        let mut seen = Vec::new();
        let mut position = start;
        loop {
            let read = self.page(connection, filter, &position).await;
            assert_eq!(read.mode, PagingMode::ServerPaging);
            assert_eq!(read.previous, None, "only an offset reaches a page before");
            assert!(read.result.rows.len() as u64 <= PAGE);
            seen.extend(numbers(&read));
            match read.next {
                Some(next) => position = next,
                None => return seen,
            }
        }
    }
}

/// The `n` column, which `SELECT *` puts after the partition key.
fn numbers(read: &PageRead) -> Vec<i64> {
    let rows = &read.result.rows;
    let numbers: Vec<i64> = rows
        .iter()
        .filter_map(|row| match row.get(1) {
            Some(Value::Int(n)) => Some(*n),
            _ => None,
        })
        .collect();
    assert_eq!(numbers.len(), rows.len(), "an n that is not an int: {rows:?}");
    numbers
}

async fn series(fixture: &CassandraFixture, name: &str) -> Table {
    load_series(fixture, name, ROWS).await;
    let connection = connect(fixture, false).await;
    Table::read(connection.as_ref(), name).await
}

async fn every_page_is_resumed_from_the_last_until_the_table_ends<S: Server>() {
    let fixture = start::<S>().await;
    let table = series(&fixture, "paged").await;
    let connection = connect(&fixture, false).await;

    let walked = table
        .walk(connection.as_ref(), &FilterSet::default(), PagePosition::First)
        .await;

    let distinct: BTreeSet<i64> = walked.iter().copied().collect();
    assert_eq!(walked.len() as u64, ROWS, "every row once");
    assert_eq!(distinct, (0..ROWS as i64).collect());

    let from_offset = table
        .walk(connection.as_ref(), &FilterSet::default(), PagePosition::Offset(1_500))
        .await;
    assert_eq!(
        from_offset,
        walked[1_500..],
        "an offset skips rows in the server's order"
    );
}

async fn a_filter_reads_only_its_rows_with_the_server_filtering<S: Server>() {
    let fixture = start::<S>().await;
    let table = series(&fixture, "filtered").await;
    let connection = connect(&fixture, false).await;
    let filter = FilterSet {
        rules: vec![FilterRule {
            column: "n".to_owned(),
            op: FilterOp::GtEq,
            value: Some(FilterValue::Single("2000".to_owned())),
        }],
        ..FilterSet::default()
    };

    let walked = table.walk(connection.as_ref(), &filter, PagePosition::First).await;

    let distinct: BTreeSet<i64> = walked.iter().copied().collect();
    assert_eq!(distinct, (2_000..ROWS as i64).collect());
    assert_eq!(walked.len(), distinct.len());

    // A range on the partition key, which only ALLOW FILTERING admits.
    let by_partition = FilterSet {
        rules: vec![FilterRule {
            column: "bucket".to_owned(),
            op: FilterOp::GtEq,
            value: Some(FilterValue::Single("2".to_owned())),
        }],
        ..FilterSet::default()
    };
    let walked: BTreeSet<i64> = table
        .walk(connection.as_ref(), &by_partition, PagePosition::First)
        .await
        .into_iter()
        .collect();
    assert_eq!(walked, (2_000..ROWS as i64).collect());
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
#[ignore = "requires docker"]
async fn cassandra_pages_resume_from_the_servers_paging_state() {
    every_page_is_resumed_from_the_last_until_the_table_ends::<CassandraServer>().await;
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
#[ignore = "requires docker"]
async fn scylla_pages_resume_from_the_servers_paging_state() {
    every_page_is_resumed_from_the_last_until_the_table_ends::<ScyllaServer>().await;
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
#[ignore = "requires docker"]
async fn cassandra_filtered_pages_hold_only_matching_rows() {
    a_filter_reads_only_its_rows_with_the_server_filtering::<CassandraServer>().await;
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
#[ignore = "requires docker"]
async fn scylla_filtered_pages_hold_only_matching_rows() {
    a_filter_reads_only_its_rows_with_the_server_filtering::<ScyllaServer>().await;
}
