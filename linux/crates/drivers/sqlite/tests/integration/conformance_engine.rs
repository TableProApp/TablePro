//! The connection conformance suite on SQLite.

use std::path::PathBuf;
use std::sync::Arc;
use std::time::Duration;

use async_trait::async_trait;
use drivers_sqlite::SqliteDriver;
use sqlx::sqlite::{SqliteConnectOptions, SqliteConnection};
use sqlx::{Connection as _, Executor as _};
use tablepro_core::{
    ConnectEnvironment, ConnectOptions, ConnectTarget, DatabaseDriver, FileEndpoint, LivenessPolicy, TableRef,
    WorkspaceSettings,
};
use tablepro_test_support::conformance::{
    ConformanceDdlEngine, ConformanceEngine, ConformanceFailure, EditorTransactionEngine, PooledConformanceEngine,
};
use tempfile::TempDir;

use crate::support::create_database;

/// A database file of the case's own, which exists before the driver
/// opens it: the suite never relies on the driver creating one.
pub struct SqliteEngine {
    _directory: TempDir,
    path: PathBuf,
    endpoint: FileEndpoint,
}

fn quote(name: &str) -> String {
    format!("\"{}\"", name.replace('"', "\"\""))
}

#[async_trait]
impl ConformanceEngine for SqliteEngine {
    fn driver() -> Arc<dyn DatabaseDriver> {
        Arc::new(SqliteDriver)
    }

    async fn start() -> Result<Self, ConformanceFailure> {
        let directory = tempfile::tempdir().map_err(ConformanceFailure::setup)?;
        let path = directory.path().join("conformance.sqlite3");
        create_database(&path).await.map_err(ConformanceFailure::setup)?;
        let endpoint = FileEndpoint::open_existing(path.clone()).map_err(ConformanceFailure::setup)?;
        Ok(Self {
            _directory: directory,
            path,
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

    /// SQLite has no sleep, but a recursive CTE without a stop never
    /// produces its count.
    fn unbounded_statement_sql(&self, marker: &str) -> String {
        format!("WITH RECURSIVE r(n) AS (SELECT 1 UNION ALL SELECT n + 1 FROM r) SELECT count(*), '{marker}' FROM r")
    }

    /// Hold an exclusive lock on a connection of the engine's own for
    /// `hold`, and return a read that waits for it in the busy handler.
    async fn blocking_statement_sql(&self, marker: &str, hold: Duration) -> Result<String, ConformanceFailure> {
        let options = SqliteConnectOptions::new().filename(&self.path);
        let mut holder = SqliteConnection::connect_with(&options)
            .await
            .map_err(ConformanceFailure::setup)?;
        holder
            .execute("BEGIN EXCLUSIVE")
            .await
            .map_err(ConformanceFailure::setup)?;
        tokio::spawn(async move {
            tokio::time::sleep(hold).await;
            let _ = holder.execute("ROLLBACK").await;
            let _ = holder.close().await;
        });
        Ok(format!("SELECT count(*), '{marker}' FROM sqlite_schema"))
    }

    fn row_source_sql(&self, rows: u64) -> String {
        format!("WITH RECURSIVE r(n) AS (SELECT 1 UNION ALL SELECT n + 1 FROM r WHERE n < {rows}) SELECT n FROM r")
    }
}

impl PooledConformanceEngine for SqliteEngine {
    const WORKSPACE_POOL_MAX_SIZE: usize = drivers_sqlite::WORKSPACE_POOL_MAX_SIZE;
}

impl EditorTransactionEngine for SqliteEngine {
    fn begin_sql(&self) -> String {
        "BEGIN".to_owned()
    }

    fn commit_sql(&self) -> String {
        "COMMIT".to_owned()
    }
}

impl ConformanceDdlEngine for SqliteEngine {
    fn integer_type(&self) -> &'static str {
        "INTEGER"
    }

    fn text_type(&self) -> &'static str {
        "TEXT"
    }

    fn timestamp_type(&self) -> &'static str {
        "TEXT"
    }

    fn current_timestamp_expression(&self) -> &'static str {
        "CURRENT_TIMESTAMP"
    }
}

tablepro_test_support::ddl_conformance_suite! {
    engine: SqliteEngine,
    docker: false,
}

// Every stored value is one of five storage classes and all five are
// decoded, so there is no unsupported type to list. SQLite has no
// server statement timeout, so no case bounds DDL by one.
tablepro_test_support::connection_conformance_suite! {
    engine: SqliteEngine,
    docker: false,
    endpoint: file,
    pool: pooled,
    editor_transactions: true,
    unsupported_types: false,
    bounded_ddl: false,
}
