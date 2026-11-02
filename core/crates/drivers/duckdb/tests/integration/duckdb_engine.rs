//! The conformance engine adapter on DuckDB. The `large_table` test
//! target shares it, so it uses nothing else from this target.

use std::path::Path;
use std::sync::Arc;
use std::time::Duration;

use async_trait::async_trait;
use tablepro_core::{
    ConnectEnvironment, ConnectOptions, ConnectTarget, DatabaseDriver, FileEndpoint, LivenessPolicy, TableRef,
    WorkspaceSettings,
};
use tablepro_driver_duckdb::DuckDbDriver;
use tablepro_test_support::conformance::{
    ConformanceDdlEngine, ConformanceEngine, ConformanceFailure, EditorTransactionEngine, LargeTableEngine,
    PooledConformanceEngine, TypedConformanceEngine, UnsupportedTypeCase,
};
use tempfile::TempDir;

/// Make an empty database the way another program would, so the driver
/// only ever opens a file that exists. The connection closes before the
/// driver opens the file.
pub fn create_database(path: &Path) -> Result<(), duckdb::Error> {
    duckdb::Connection::open(path)?.execute_batch("CHECKPOINT")
}

/// A database file of the case's own, which exists before the driver
/// opens it: the suite never relies on the driver creating one.
pub struct DuckDbEngine {
    _directory: TempDir,
    endpoint: FileEndpoint,
}

fn quote(name: &str) -> String {
    format!("\"{}\"", name.replace('"', "\"\""))
}

#[async_trait]
impl ConformanceEngine for DuckDbEngine {
    const READ_ONLY_BESIDE_WRITER: bool = false;

    fn driver() -> Arc<dyn DatabaseDriver> {
        Arc::new(DuckDbDriver)
    }

    async fn start() -> Result<Self, ConformanceFailure> {
        let directory = tempfile::tempdir().map_err(ConformanceFailure::setup)?;
        let path = directory.path().join("conformance.duckdb");
        create_database(&path).map_err(ConformanceFailure::setup)?;
        let endpoint = FileEndpoint::open_existing(path).map_err(ConformanceFailure::setup)?;
        Ok(Self {
            _directory: directory,
            endpoint,
        })
    }

    fn connect_options(&self, settings: WorkspaceSettings, liveness: LivenessPolicy) -> ConnectOptions {
        ConnectOptions {
            target: ConnectTarget::File(self.endpoint.clone()),
            workspace_settings: settings,
            liveness,
            environment: ConnectEnvironment::new("conformance"),
        }
    }

    fn scratch_table(&self, name: &str) -> TableRef {
        TableRef::unqualified(name)
    }

    fn create_scratch_table_sql(&self, table: &TableRef) -> String {
        format!(
            "CREATE TABLE {} (id integer primary key, label text not null)",
            quote(&table.name)
        )
    }

    /// A cross join far too large to finish, which DuckDB checks for an
    /// interrupt as it works through.
    fn unbounded_statement_sql(&self, marker: &str) -> String {
        format!("SELECT sum(a.range * b.range), '{marker}' FROM range(100000000) a, range(100000000) b")
    }

    async fn blocking_statement_sql(&self, marker: &str, hold: Duration) -> Result<String, ConformanceFailure> {
        Ok(format!("SELECT pg_sleep({}), '{marker}'", hold.as_secs_f64()))
    }

    fn row_source_sql(&self, rows: u64) -> String {
        format!("SELECT range + 1 AS n FROM range({rows})")
    }
}

impl PooledConformanceEngine for DuckDbEngine {
    const WORKSPACE_POOL_MAX_SIZE: usize = tablepro_driver_duckdb::WORKSPACE_POOL_MAX_SIZE;
}

impl EditorTransactionEngine for DuckDbEngine {
    fn begin_sql(&self) -> String {
        "BEGIN".to_owned()
    }

    fn commit_sql(&self) -> String {
        "COMMIT".to_owned()
    }
}

impl TypedConformanceEngine for DuckDbEngine {
    /// Arrow carries a TIME WITH TIME ZONE without its offset, and a
    /// BIGNUM in DuckDB's own encoding, so an editor run reads neither.
    fn unsupported_type_cases(&self) -> Vec<UnsupportedTypeCase> {
        vec![UnsupportedTypeCase {
            setup_sql: Vec::new(),
            declaration: "v TIMETZ".to_owned(),
            insert_value_sql: "TIMETZ '12:30:00+05:30'".to_owned(),
        }]
    }
}

impl ConformanceDdlEngine for DuckDbEngine {
    fn integer_type(&self) -> &'static str {
        "INTEGER"
    }

    fn text_type(&self) -> &'static str {
        "VARCHAR"
    }

    fn timestamp_type(&self) -> &'static str {
        "TIMESTAMP"
    }

    fn current_timestamp_expression(&self) -> &'static str {
        "current_timestamp"
    }
}

impl LargeTableEngine for DuckDbEngine {
    fn fill_scratch_table_sql(&self, table: &TableRef, rows: u64, label_width: usize) -> Vec<String> {
        vec![format!(
            "INSERT INTO {} (id, label) SELECT range + 1, lpad(CAST(range + 1 AS VARCHAR), {label_width}, '0') \
             FROM range({rows})",
            quote(&table.name)
        )]
    }
}
