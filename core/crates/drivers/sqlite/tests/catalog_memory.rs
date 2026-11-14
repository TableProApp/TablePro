// Catalog reads of a crafted file stop at the catalog budget. A test binary of its own because it counts every heap
// allocation the process makes, which another test running beside it would add to. Add no other test here.

use std::sync::Arc;
use std::time::Duration;

use sqlx::sqlite::{SqliteConnectOptions, SqliteConnection};
use sqlx::{Connection as _, Executor as _};
use tablepro_core::meta::{ObjectScope, TableRef};
use tablepro_core::statement::{GuardedStatement, StatementBuilder};
use tablepro_core::{
    ByteLimit, CallOptions, ConnectEnvironment, ConnectOptions, ConnectTarget, Connection, DatabaseDriver, DriverError,
    FileEndpoint, ForeignKeyCheck, ForeignKeyMode, WorkspaceSettings, WriteBatch, WriteKind,
};
use tablepro_driver_sqlite::SqliteDriver;
use tablepro_test_support::conformance::test_liveness;
use tablepro_test_support::{HeapCounter, heap_peak_of as peak_of};
use tokio::time::Instant;
use tokio_util::sync::CancellationToken;

#[global_allocator]
static HEAP: HeapCounter = HeapCounter;

// The budget counts the text a read holds, not the vectors and maps around it.
const BOUND: usize = 2 * ByteLimit::CATALOG_DEFAULT.get() as usize;

const LONG: usize = 64 * 1024;
const KEYS: usize = 4_000;
const BROKEN_ROWS: usize = 20_000;

fn quoted(name: &str) -> String {
    format!("\"{name}\"")
}

// Each shape costs the file a few hundred kilobytes and, read without a bound, a gigabyte or more:
// - one column carrying REFERENCES 4,000 times, which the pragma names on every key;
// - a child with a 64 KiB name and 4,000 keys, each of which names the child;
// - 4,000 keys naming no columns of a parent whose primary key is 64 KiB of names, each a copy of it;
// - 20,000 rows of a table with a 64 KiB name that break its key, which a check named on every row.
fn crafted_schema() -> Vec<String> {
    let column = "c".repeat(LONG);
    let child = "n".repeat(LONG);
    let key_columns: Vec<String> = (0..64)
        .map(|index| format!("k{index:02}{}", "k".repeat(1_021)))
        .collect();
    let declared: Vec<String> = key_columns
        .iter()
        .map(|name| format!("{} INTEGER", quoted(name)))
        .collect();
    let listed: Vec<String> = key_columns.iter().map(|name| quoted(name)).collect();
    vec![
        "CREATE TABLE repeated_parent (id INTEGER PRIMARY KEY)".to_owned(),
        format!(
            "CREATE TABLE repeated ({} INTEGER{})",
            quoted(&column),
            " REFERENCES repeated_parent".repeat(KEYS)
        ),
        "CREATE TABLE named_parent (id INTEGER PRIMARY KEY)".to_owned(),
        format!(
            "CREATE TABLE {} (a INTEGER{})",
            quoted(&child),
            ", FOREIGN KEY (a) REFERENCES named_parent".repeat(KEYS)
        ),
        format!(
            "CREATE TABLE wide_key ({}, PRIMARY KEY ({}))",
            declared.join(", "),
            listed.join(", ")
        ),
        format!(
            "CREATE TABLE pointer (a INTEGER{})",
            ", FOREIGN KEY (a) REFERENCES wide_key".repeat(KEYS)
        ),
        format!("CREATE TABLE {} (a INTEGER REFERENCES named_parent)", quoted(&broken())),
        format!(
            "WITH RECURSIVE n(i) AS (SELECT 1 UNION ALL SELECT i + 1 FROM n WHERE i < {BROKEN_ROWS}) \
             INSERT INTO {} SELECT i FROM n",
            quoted(&broken())
        ),
    ]
}

fn broken() -> String {
    "b".repeat(LONG)
}

fn call() -> CallOptions {
    CallOptions::new(
        Some(Instant::now() + Duration::from_secs(120)),
        CancellationToken::new(),
    )
}

async fn open(path: &std::path::Path) -> Result<Arc<dyn Connection>, DriverError> {
    let options = ConnectOptions {
        target: ConnectTarget::File(FileEndpoint::open_existing(path.to_path_buf())?),
        workspace_settings: WorkspaceSettings::workspace(false),
        liveness: test_liveness(),
        environment: ConnectEnvironment::new("test"),
    };
    SqliteDriver.connect(options, CancellationToken::new()).await
}

fn too_large<T>(read: &str, result: Result<T, DriverError>) {
    let limit = ByteLimit::CATALOG_DEFAULT.get();
    assert!(
        matches!(result, Err(DriverError::CatalogTooLarge { limit_bytes }) if limit_bytes == limit),
        "{read}: {:?}",
        result.err()
    );
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_crafted_catalog_stops_at_the_budget() {
    let directory = tempfile::tempdir().unwrap();
    let path = directory.path().join("crafted.sqlite3");
    let options = SqliteConnectOptions::new()
        .filename(&path)
        .create_if_missing(true)
        .foreign_keys(false);
    let mut writer = SqliteConnection::connect_with(&options).await.unwrap();
    for sql in crafted_schema() {
        writer.execute(sqlx::AssertSqlSafe(sql)).await.unwrap();
    }
    writer.close().await.unwrap();
    let connection = open(&path).await.unwrap();
    let table = |name: &str| TableRef::unqualified(name);
    let child = table(&"n".repeat(LONG));

    let (objects, peak) = peak_of(connection.list_objects(&ObjectScope::DefaultSchema, call())).await;
    assert_eq!(objects.unwrap().len(), 7);
    assert!(peak < BOUND, "listing the tables held {peak} bytes");
    let (columns, _) = peak_of(connection.fetch_columns(&table("repeated"), call())).await;
    assert_eq!(columns.unwrap().len(), 1, "a long name alone is read");

    for (name, table) in [
        ("repeated", table("repeated")),
        ("the long child", child.clone()),
        ("pointer", table("pointer")),
    ] {
        let (read, peak) = peak_of(connection.fetch_foreign_keys(&table, call())).await;
        too_large(&format!("keys of {name}"), read);
        assert!(peak < BOUND, "keys of {name} held {peak} bytes");
        let (read, peak) = peak_of(connection.fetch_outbound_foreign_keys(&table, call())).await;
        too_large(&format!("outbound keys of {name}"), read);
        assert!(peak < BOUND, "outbound keys of {name} held {peak} bytes");
        let (read, peak) = peak_of(connection.fetch_table_definition(&table, call())).await;
        too_large(&format!("definition of {name}"), read);
        assert!(peak < BOUND, "definition of {name} held {peak} bytes");
    }
    for parent in ["repeated_parent", "named_parent", "wide_key"] {
        let (read, peak) = peak_of(connection.fetch_inbound_foreign_keys(&table(parent), call())).await;
        too_large(&format!("keys into {parent}"), read);
        assert!(peak < BOUND, "keys into {parent} held {peak} bytes");
        let (read, peak) = peak_of(connection.fetch_table_definition(&table(parent), call())).await;
        too_large(&format!("definition of {parent}"), read);
        assert!(peak < BOUND, "definition of {parent} held {peak} bytes");
    }

    // A rebuild checks the keys its table breaks before and after; the rows that broke them already are not its own.
    let mut builder = StatementBuilder::new();
    builder.push_sql(&format!("UPDATE {} SET a = a WHERE 0", quoted(&broken())));
    let batch = WriteBatch::new(
        WriteKind::SchemaChanges,
        table(&broken()),
        vec![GuardedStatement::unguarded(builder.finish())],
        ForeignKeyMode::SuspendedThenVerified {
            checks: vec![ForeignKeyCheck::same_table(table(&broken()))],
        },
    );
    let (written, peak) = peak_of(connection.write_batch(&batch, call())).await;
    assert!(written.is_ok(), "{written:?}");
    assert!(peak < BOUND / 8, "checking {BROKEN_ROWS} broken rows held {peak} bytes");
    connection.close().await.unwrap();
}
