//! Paging a table the way the browse tab does, past the edge row's key.

use tablepro_core::browse::{PageRead, PageRequest, read_page};
use tablepro_core::filter::FilterSet;
use tablepro_core::meta::{PagePosition, RowIdentity, TableRef};
use tablepro_core::{ColumnInfo, Connection, Value};

use crate::support::{TestFile, apply, call};

type Failure = Box<dyn std::error::Error + Send + Sync>;

struct Table {
    table: TableRef,
    columns: Vec<ColumnInfo>,
    identity: RowIdentity,
}

impl Table {
    async fn read(connection: &dyn Connection, name: &str) -> Self {
        let table = TableRef::unqualified(name);
        Self {
            columns: connection.fetch_columns(&table, call()).await.unwrap(),
            identity: connection.row_identity(&table, call()).await.unwrap(),
            table,
        }
    }

    /// One row per page, so every page is read past a key.
    async fn page(&self, connection: &dyn Connection, position: &PagePosition) -> (PageRead, Vec<Value>) {
        let filter = FilterSet::default();
        let request = PageRequest {
            table: &self.table,
            columns: &self.columns,
            filter: &filter,
            sort: &[],
            identity: &self.identity,
            position,
            limit: 1,
        };
        let read = read_page::<Failure>(connection, &request, &call()).await.unwrap();
        let rows = read.result.rows.iter().map(|row| row[0].clone()).collect();
        (read, rows)
    }
}

/// An ENUM key sorts in the order its labels are declared, and the key a
/// page is read past compares the same way, forward and back.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn an_enum_key_pages_in_declared_order() {
    let file = TestFile::new();
    let connection = file.open().await;
    apply(
        connection.as_ref(),
        &[
            "CREATE TYPE mood AS ENUM ('sad', 'ok', 'happy')",
            "CREATE TABLE moods (m mood PRIMARY KEY)",
            "INSERT INTO moods VALUES ('happy'), ('sad'), ('ok')",
        ],
    )
    .await
    .unwrap();
    let table = Table::read(connection.as_ref(), "moods").await;
    let declared: Vec<Value> = ["sad", "ok", "happy"]
        .into_iter()
        .map(|label| Value::Text(label.to_owned()))
        .collect();

    let mut forward = Vec::new();
    let mut position = PagePosition::First;
    for _ in 0..declared.len() + 1 {
        let (read, rows) = table.page(connection.as_ref(), &position).await;
        if rows.is_empty() {
            break;
        }
        forward.extend(rows);
        position = read.next.unwrap();
    }
    // Going back ends on the first page, read again from the start.
    let mut backward = Vec::new();
    let mut position = PagePosition::Last;
    for _ in 0..declared.len() + 1 {
        let (read, rows) = table.page(connection.as_ref(), &position).await;
        if read.position == PagePosition::First {
            let unseen: Vec<Value> = rows.into_iter().filter(|row| !backward.contains(row)).collect();
            backward.splice(0..0, unseen);
            break;
        }
        backward.splice(0..0, rows);
        position = read.previous.unwrap();
    }

    assert_eq!(forward, declared);
    assert_eq!(backward, declared);
    connection.close().await.unwrap();
}
