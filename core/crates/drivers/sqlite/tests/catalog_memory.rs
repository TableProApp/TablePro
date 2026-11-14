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
const BULKY_CHILDREN: usize = 60;
const ORPHANS: usize = 3_000;

fn quoted(name: &str) -> String {
    format!("\"{name}\"")
}

// Each shape costs the file a few hundred kilobytes and, read without a bound, a gigabyte or more:
// - one column carrying REFERENCES 4,000 times, which the pragma names on every key;
// - a child with a 64 KiB name and 4,000 keys, each of which names the child;
// - 4,000 keys naming no columns of a parent whose primary key is 64 KiB of names, each a copy of it;
// - 20,000 rows of a table with a 64 KiB name that break its key, which a check named on every row;
// - one row of a table with a 64 KiB name that breaks 4,000 keys, which the check named on every key;
// - 60 children of one parent, each CREATE TABLE 256 KiB long, which SQLite queued 50 at a time;
// - 3,000 rows that each break 1,000 keys, three million broken keys from 30 KB of text and rows, which stop a save.
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
        format!(
            "CREATE TABLE {} (a INTEGER{})",
            quoted(&broken_keys()),
            " REFERENCES named_parent".repeat(KEYS)
        ),
        format!("INSERT INTO {} VALUES (1)", quoted(&broken_keys())),
        "CREATE TABLE bulky_parent (id INTEGER PRIMARY KEY)".to_owned(),
        format!(
            "CREATE TABLE orphans (a INTEGER{})",
            " REFERENCES named_parent".repeat(1_000)
        ),
        format!(
            "WITH RECURSIVE n(i) AS (SELECT 1 UNION ALL SELECT i + 1 FROM n WHERE i < {ORPHANS}) \
             INSERT INTO orphans SELECT i FROM n"
        ),
    ]
    .into_iter()
    .chain((0..BULKY_CHILDREN).map(|child| {
        format!(
            "CREATE TABLE bulky_{child:02} (a INTEGER REFERENCES bulky_parent /* {} */)",
            "x".repeat(256 * 1024)
        )
    }))
    .collect()
}

fn broken_keys() -> String {
    "k".repeat(LONG)
}

// A rebuild checks the keys its table breaks before and after; the rows that broke them already are not its own.
fn checked_save(table: &str) -> WriteBatch {
    let mut builder = StatementBuilder::new();
    builder.push_sql(&format!("UPDATE {} SET a = a WHERE 0", quoted(table)));
    WriteBatch::new(
        WriteKind::SchemaChanges,
        TableRef::unqualified(table),
        vec![GuardedStatement::unguarded(builder.finish())],
        ForeignKeyMode::SuspendedThenVerified {
            checks: vec![ForeignKeyCheck::same_table(TableRef::unqualified(table))],
        },
    )
}

// How far the heap and SQLite's own memory, which the heap counter does not see, rose while `read` ran. SQLite's is 0
// where the library keeps no count.
async fn measured<T>(read: impl std::future::Future<Output = T>) -> (T, usize, i64) {
    // SAFETY: these calls only read and reset SQLite's own counters.
    let start = unsafe {
        libsqlite3_sys::sqlite3_memory_highwater(1);
        libsqlite3_sys::sqlite3_memory_used()
    };
    let (value, heap) = peak_of(read).await;
    // SAFETY: as above.
    let native = unsafe { libsqlite3_sys::sqlite3_memory_highwater(1) } - start;
    (value, heap, native)
}

// SQLite compiled a crafted table's key list, a copy of its long name for each key, into gigabytes.
const NATIVE_BOUND: i64 = 32 << 20;

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

    let (objects, heap, _) = measured(connection.list_objects(&ObjectScope::DefaultSchema, call())).await;
    assert_eq!(objects.unwrap().len(), 10 + BULKY_CHILDREN);
    assert!(heap < BOUND, "listing the tables held {heap} bytes");
    let (columns, _, _) = measured(connection.fetch_columns(&table("repeated"), call())).await;
    assert_eq!(columns.unwrap().len(), 1, "a long name alone is read");

    for (name, table) in [
        ("repeated", table("repeated")),
        ("the long child", child.clone()),
        ("pointer", table("pointer")),
    ] {
        let (read, heap, native) = measured(connection.fetch_foreign_keys(&table, call())).await;
        too_large(&format!("keys of {name}"), read);
        assert!(
            heap < BOUND && native < NATIVE_BOUND,
            "keys of {name}: {heap}, {native}"
        );
        let (read, heap, native) = measured(connection.fetch_outbound_foreign_keys(&table, call())).await;
        too_large(&format!("outbound keys of {name}"), read);
        assert!(
            heap < BOUND && native < NATIVE_BOUND,
            "outbound keys of {name}: {heap}, {native}"
        );
        let (read, heap, native) = measured(connection.fetch_table_definition(&table, call())).await;
        too_large(&format!("definition of {name}"), read);
        assert!(
            heap < BOUND && native < NATIVE_BOUND,
            "definition of {name}: {heap}, {native}"
        );
    }
    for parent in ["repeated_parent", "named_parent", "wide_key"] {
        let (read, heap, native) = measured(connection.fetch_inbound_foreign_keys(&table(parent), call())).await;
        too_large(&format!("keys into {parent}"), read);
        assert!(
            heap < BOUND && native < NATIVE_BOUND,
            "keys into {parent}: {heap}, {native}"
        );
        let (read, heap, native) = measured(connection.fetch_table_definition(&table(parent), call())).await;
        too_large(&format!("definition of {parent}"), read);
        assert!(
            heap < BOUND && native < NATIVE_BOUND,
            "definition of {parent}: {heap}, {native}"
        );
    }

    for (name, table) in [("broken rows", broken()), ("broken keys", broken_keys())] {
        let (written, heap, native) = measured(connection.write_batch(&checked_save(&table), call())).await;
        assert!(written.is_ok(), "{name}: {written:?}");
        assert!(
            heap < BOUND / 8 && native < NATIVE_BOUND,
            "checking the {name}: {heap}, {native}"
        );
    }
    let (written, heap, native) = measured(connection.write_batch(&checked_save("orphans"), call())).await;
    too_large("checking the orphans", written.map_err(|error| error.cause().clone()));
    assert!(
        heap < BOUND && native < NATIVE_BOUND,
        "checking the orphans: {heap}, {native}"
    );

    // A child's CREATE TABLE is read alone, never 50 of them queued in SQLite's reader.
    let (inbound, heap, native) = measured(connection.fetch_inbound_foreign_keys(&table("bulky_parent"), call())).await;
    assert_eq!(inbound.unwrap().len(), BULKY_CHILDREN);
    assert!(
        heap < BOUND / 8 && native < 8 << 20,
        "keys into bulky_parent: {heap}, {native}"
    );
    connection.close().await.unwrap();
}
