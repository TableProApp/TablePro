// DuckDB parses, binds, reads and prints an expression one call per level, partly on threads of its own, and a
// level past what a thread's stack holds ends the process. These files are as deep as DuckDB lets one be.

use std::path::{Path, PathBuf};

use tablepro_core::meta::{ObjectScope, TableRef};
use tablepro_core::{Connection, DriverError, FileEndpoint, ServerCode};
use tempfile::TempDir;

use crate::support::{apply, call, connect, statement, writable};

// The deepest a CHECK, DEFAULT, generated column, view or macro nests under DuckDB's own default limit of 1,000.
const DUCKDB_DEFAULT_DEPTH: usize = 992;

fn nested(levels: usize, inner: &str) -> String {
    format!("{}{inner}{}", "abs(".repeat(levels), ")".repeat(levels))
}

// DuckDB recurses while it writes these too, so the file is made on a stack that holds them.
fn create(directory: &TempDir, statements: Vec<String>) -> PathBuf {
    let path = directory.path().join("deep.duckdb");
    let target = path.clone();
    std::thread::Builder::new()
        .stack_size(256 << 20)
        .spawn(move || {
            let writer = duckdb::Connection::open(&target)?;
            statements.iter().try_for_each(|sql| writer.execute_batch(sql))
        })
        .unwrap()
        .join()
        .unwrap()
        .unwrap();
    path
}

async fn open(path: &Path) -> std::sync::Arc<dyn Connection> {
    connect(FileEndpoint::open_existing(path.to_path_buf()).unwrap(), writable())
        .await
        .unwrap()
}

#[track_caller]
fn refused_as_too_deep<T: std::fmt::Debug>(read: &str, result: Result<T, DriverError>) {
    let error = match result {
        Err(DriverError::RolledBack { source, .. }) => *source,
        Err(error) => error,
        Ok(value) => panic!("{read} read a value: {value:?}"),
    };
    let DriverError::Server(diagnostics) = &error else {
        panic!("{read}: {error:?}");
    };
    assert!(
        matches!(&diagnostics.code, Some(ServerCode::DuckDb { error_type }) if error_type == "Binder"),
        "{read}: {error:?}"
    );
    assert!(
        diagnostics
            .message
            .starts_with("Max expression depth limit of 250 exceeded"),
        "{read}: {error:?}"
    );
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_file_as_deep_as_duckdb_allows_is_read_or_refused() {
    let directory = tempfile::tempdir().unwrap();
    let path = create(
        &directory,
        vec![format!(
            "CREATE TABLE other (id INTEGER PRIMARY KEY); \
             CREATE TABLE t (a INTEGER CHECK ({check} > 0), b INTEGER DEFAULT ({default}), c INTEGER AS ({check})); \
             CREATE VIEW v AS SELECT {check} AS x FROM t; \
             CREATE MACRO m(x) AS {macro_body}; \
             CHECKPOINT;",
            check = nested(DUCKDB_DEFAULT_DEPTH, "a"),
            default = nested(DUCKDB_DEFAULT_DEPTH, "1"),
            macro_body = nested(DUCKDB_DEFAULT_DEPTH, "x"),
        )],
    );
    let connection = open(&path).await;
    let table = |name: &str| TableRef::new(Some("main".to_owned()), name);

    let objects = connection
        .list_objects(&ObjectScope::DefaultSchema, call())
        .await
        .unwrap();
    assert_eq!(
        objects.iter().map(|object| object.name.as_str()).collect::<Vec<_>>(),
        ["other", "t", "v"]
    );
    refused_as_too_deep("the columns of t", connection.fetch_columns(&table("t"), call()).await);
    refused_as_too_deep(
        "the definition of other",
        connection.fetch_table_definition(&table("other"), call()).await,
    );
    refused_as_too_deep(
        "the keys of other",
        connection.fetch_foreign_keys(&table("other"), call()).await,
    );
    refused_as_too_deep(
        "the view",
        connection
            .query_bound(
                &statement("SELECT * FROM v"),
                tablepro_core::RowLimit::EDITOR_DEFAULT,
                call(),
            )
            .await,
    );
    refused_as_too_deep(
        "the macro",
        connection
            .query_bound(
                &statement("SELECT m(1)"),
                tablepro_core::RowLimit::EDITOR_DEFAULT,
                call(),
            )
            .await,
    );
    refused_as_too_deep(
        "an insert",
        apply(connection.as_ref(), &["INSERT INTO t (a) VALUES (1)"]).await,
    );
    connection.close().await.unwrap();
}

// Made by raising DuckDB's limit. DuckDB reads it back at open with no limit of its own, deeper than the 2 MiB a
// runtime's blocking thread has.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_file_deeper_than_a_runtime_thread_holds_opens() {
    let directory = tempfile::tempdir().unwrap();
    let path = create(
        &directory,
        vec![
            "SET max_expression_depth = 100000".to_owned(),
            format!(
                "CREATE TABLE t (a INTEGER CHECK ({} > 0)); CHECKPOINT;",
                nested(3_000, "a")
            ),
        ],
    );

    let connection = open(&path).await;

    assert_eq!(connection.server_info().product, "DuckDB");
    connection.close().await.unwrap();
}
