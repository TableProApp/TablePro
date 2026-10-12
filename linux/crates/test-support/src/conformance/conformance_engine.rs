use std::sync::Arc;
use std::time::Duration;

use async_trait::async_trait;
use tablepro_core::{ConnectOptions, DatabaseDriver, LivenessPolicy, TableRef, WorkspaceSettings};

use crate::conformance::ConformanceFailure;

/// What a driver's integration target supplies so the connection suite
/// can run against its engine.
///
/// Each case starts its own engine, so a case that leaves the server in
/// a bad state cannot fail the next one.
#[async_trait]
pub trait ConformanceEngine: Send + Sync + Sized + 'static {
    fn driver() -> Arc<dyn DatabaseDriver>;

    /// Start a server through tablepro-test-fixtures, or a file for an
    /// engine without one, and keep it alive as long as `Self` is.
    async fn start() -> Result<Self, ConformanceFailure>;

    fn connect_options(&self, settings: WorkspaceSettings, liveness: LivenessPolicy) -> ConnectOptions;

    fn scratch_table(&self, name: &str) -> TableRef;

    /// A table with `id integer primary key` and `label text not null`,
    /// in the engine's own spelling.
    fn create_scratch_table_sql(&self, table: &TableRef) -> String;

    /// A read that never finishes on its own and carries `marker` in its
    /// text, so the server's own session list can find it.
    fn unbounded_statement_sql(&self, marker: &str) -> String;

    /// A read that finishes after at least `hold`.
    async fn blocking_statement_sql(&self, marker: &str, hold: Duration) -> Result<String, ConformanceFailure>;

    /// A read of `rows` rows.
    fn row_source_sql(&self, rows: u64) -> String;
}
