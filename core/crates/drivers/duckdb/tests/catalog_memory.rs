// Catalog reads of a crafted file hold what they return, and stop at the catalog budget. A test binary of its own
// because it counts every heap allocation the process makes, which another test running beside it would add to. Add
// no other test here.

use std::time::Duration;

use tablepro_core::meta::TableRef;
use tablepro_core::{
    ByteLimit, CallOptions, ConnectEnvironment, ConnectOptions, ConnectTarget, DatabaseDriver, DriverError,
    FileEndpoint, WorkspaceSettings,
};
use tablepro_driver_duckdb::DuckDbDriver;
use tablepro_test_support::conformance::test_liveness;
use tablepro_test_support::{HeapCounter, heap_peak_of};
use tokio::time::Instant;
use tokio_util::sync::CancellationToken;

#[global_allocator]
static HEAP: HeapCounter = HeapCounter;

// The budget counts the text a read holds, not the vectors and maps around it.
const BOUND: usize = 2 * ByteLimit::CATALOG_DEFAULT.get() as usize;

const KEYS: usize = 1_000;
const NAMED_KEYS: usize = 600;

// DuckDB takes seconds to create and open more than this:
// - a child declaring 1,000 keys into one parent, whose CREATE TABLE, 40 KB, was read again for each of them;
// - a child with a 64 KiB name and 600 keys, each named after it, and its name again on each key into the parent;
// - a CHECK naming 600 columns of 200-byte names, which is each column's. Flat: DuckDB binds a nested one on the
//   calling thread's stack.
fn crafted_schema() -> String {
    let column_names: Vec<String> = (0..600)
        .map(|index| format!("c{index:03}{}", "c".repeat(196)))
        .collect();
    let columns: Vec<String> = column_names.iter().map(|name| format!("{name} INTEGER")).collect();
    format!(
        "CREATE TABLE parent (id INTEGER PRIMARY KEY); \
         CREATE TABLE child (a INTEGER{}); \
         CREATE TABLE named_parent (id INTEGER PRIMARY KEY); \
         CREATE TABLE {} (a INTEGER{}); \
         CREATE TABLE checked ({}, CHECK (greatest({}) > 0)); \
         CHECKPOINT;",
        ", FOREIGN KEY (a) REFERENCES parent (id)".repeat(KEYS),
        "n".repeat(64 * 1024),
        ", FOREIGN KEY (a) REFERENCES named_parent (id)".repeat(NAMED_KEYS),
        columns.join(", "),
        column_names.join(", "),
    )
}

fn call() -> CallOptions {
    CallOptions::new(
        Some(Instant::now() + Duration::from_secs(120)),
        CancellationToken::new(),
    )
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
async fn a_crafted_catalog_holds_what_it_returns() {
    let directory = tempfile::tempdir().unwrap();
    let path = directory.path().join("crafted.duckdb");
    duckdb::Connection::open(&path)
        .unwrap()
        .execute_batch(&crafted_schema())
        .unwrap();
    let options = ConnectOptions {
        target: ConnectTarget::File(FileEndpoint::open_existing(path).unwrap()),
        workspace_settings: WorkspaceSettings::workspace(true),
        liveness: test_liveness(),
        environment: ConnectEnvironment::new("test"),
    };
    let connection = DuckDbDriver.connect(options, CancellationToken::new()).await.unwrap();
    let table = |name: &str| TableRef::new(Some("main".to_owned()), name);

    let (outbound, peak) = heap_peak_of(connection.fetch_outbound_foreign_keys(&table("child"), call())).await;
    assert_eq!(outbound.unwrap().len(), KEYS);
    assert!(peak < BOUND / 8, "the keys of child held {peak} bytes");
    let (inbound, peak) = heap_peak_of(connection.fetch_inbound_foreign_keys(&table("parent"), call())).await;
    assert_eq!(inbound.unwrap().len(), KEYS);
    assert!(peak < BOUND / 8, "the keys into parent held {peak} bytes");
    let (definition, peak) = heap_peak_of(connection.fetch_table_definition(&table("parent"), call())).await;
    assert_eq!(definition.unwrap().inbound_foreign_keys.len(), KEYS);
    assert!(peak < BOUND / 8, "the definition of parent held {peak} bytes");

    let named = table(&"n".repeat(64 * 1024));
    let (inbound, peak) = heap_peak_of(connection.fetch_inbound_foreign_keys(&table("named_parent"), call())).await;
    too_large("keys into named_parent", inbound);
    assert!(peak < BOUND, "the keys into named_parent held {peak} bytes");
    let (keys, peak) = heap_peak_of(connection.fetch_foreign_keys(&named, call())).await;
    assert_eq!(
        keys.map(|keys| keys.len()),
        Ok(NAMED_KEYS),
        "its own keys, named once each, fit"
    );
    assert!(peak < BOUND, "the keys of the long child held {peak} bytes");
    let (checked, peak) = heap_peak_of(connection.fetch_table_definition(&table("checked"), call())).await;
    too_large("definition of checked", checked);
    assert!(peak < BOUND, "the definition of checked held {peak} bytes");
    connection.close().await.unwrap();
}
