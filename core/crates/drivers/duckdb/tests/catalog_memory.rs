// Catalog reads of a crafted file hold what they return, and stop at the catalog budget. A test binary of its own
// because it counts every heap allocation the process makes, which another test running beside it would add to. Add
// no other test here.

use std::sync::Arc;
use std::time::Duration;

use tablepro_core::meta::{ObjectScope, TableRef};
use tablepro_core::{
    ByteLimit, CallOptions, ConnectEnvironment, ConnectOptions, ConnectTarget, Connection, DatabaseDriver, DriverError,
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

// DuckDB takes seconds to create and open more than this. One file a real schema could be:
// - a child declaring 1,000 keys into one parent, whose CREATE TABLE, 40 KB, was read again for each of them;
// - a CHECK naming 600 columns of 200-byte names, which is each column's. Flat: DuckDB binds a nested one on the
//   calling thread's stack.
fn large_schema() -> String {
    let column_names: Vec<String> = (0..600)
        .map(|index| format!("c{index:03}{}", "c".repeat(196)))
        .collect();
    let columns: Vec<String> = column_names.iter().map(|name| format!("{name} INTEGER")).collect();
    format!(
        "CREATE TABLE parent (id INTEGER PRIMARY KEY); \
         CREATE TABLE child (a INTEGER{}); \
         CREATE TABLE checked ({}, CHECK (greatest({}) > 0)); \
         CHECKPOINT;",
        ", FOREIGN KEY (a) REFERENCES parent (id)".repeat(KEYS),
        columns.join(", "),
        column_names.join(", "),
    )
}

// And one crafted: a child with a 64 KiB name and 600 keys, which DuckDB names after it whatever table a read asks for.
fn crafted_schema() -> String {
    format!(
        "CREATE TABLE named_parent (id INTEGER PRIMARY KEY); \
         CREATE TABLE other (id INTEGER PRIMARY KEY); \
         CREATE TABLE {} (a INTEGER{}); \
         CHECKPOINT;",
        "n".repeat(64 * 1024),
        ", FOREIGN KEY (a) REFERENCES named_parent (id)".repeat(NAMED_KEYS),
    )
}

async fn open(directory: &std::path::Path, name: &str, schema: &str) -> Result<Arc<dyn Connection>, String> {
    let path = directory.join(name);
    duckdb::Connection::open(&path)
        .and_then(|writer| writer.execute_batch(schema))
        .map_err(|error| error.to_string())?;
    let options = ConnectOptions {
        target: ConnectTarget::File(FileEndpoint::open_existing(path).map_err(|error| error.to_string())?),
        workspace_settings: WorkspaceSettings::workspace(true),
        liveness: test_liveness(),
        environment: ConnectEnvironment::new("test"),
    };
    DuckDbDriver
        .connect(options, CancellationToken::new())
        .await
        .map_err(|error| error.to_string())
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
    let table = |name: &str| TableRef::new(Some("main".to_owned()), name);
    let connection = open(directory.path(), "large.duckdb", &large_schema()).await.unwrap();

    let (outbound, peak) = heap_peak_of(connection.fetch_outbound_foreign_keys(&table("child"), call())).await;
    assert_eq!(outbound.unwrap().len(), KEYS);
    assert!(peak < BOUND / 8, "the keys of child held {peak} bytes");
    let (inbound, peak) = heap_peak_of(connection.fetch_inbound_foreign_keys(&table("parent"), call())).await;
    assert_eq!(inbound.unwrap().len(), KEYS);
    assert!(peak < BOUND / 8, "the keys into parent held {peak} bytes");
    let (definition, peak) = heap_peak_of(connection.fetch_table_definition(&table("parent"), call())).await;
    assert_eq!(definition.unwrap().inbound_foreign_keys.len(), KEYS);
    assert!(peak < BOUND / 8, "the definition of parent held {peak} bytes");
    let (checked, peak) = heap_peak_of(connection.fetch_table_definition(&table("checked"), call())).await;
    too_large("definition of checked", checked);
    assert!(peak < BOUND, "the definition of checked held {peak} bytes");
    connection.close().await.unwrap();

    let connection = open(directory.path(), "crafted.duckdb", &crafted_schema())
        .await
        .unwrap();
    let (inbound, peak) = heap_peak_of(connection.fetch_inbound_foreign_keys(&table("named_parent"), call())).await;
    too_large("keys into named_parent", inbound);
    assert!(peak < BOUND / 8, "the keys into named_parent held {peak} bytes");
    let (keys, peak) = heap_peak_of(connection.fetch_foreign_keys(&table("other"), call())).await;
    too_large("keys of an unrelated table", keys);
    assert!(peak < BOUND / 8, "the keys of an unrelated table held {peak} bytes");
    let (objects, _) = heap_peak_of(connection.list_objects(&ObjectScope::DefaultSchema, call())).await;
    assert_eq!(objects.unwrap().len(), 3, "the table list reads no constraint");
    connection.close().await.unwrap();
}
