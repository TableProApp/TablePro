use std::sync::Arc;

use async_trait::async_trait;
use tablepro_core::{ConnectOptions, DatabaseDriver, LivenessPolicy, WorkspaceSettings};

use crate::FaultTransport;
use crate::conformance::ConformanceFailure;

/// What a document engine's integration target supplies so the document
/// suite can run against it: how to start the server and connect, and
/// the engine's own statements for what the cases set up.
#[async_trait]
pub trait DocumentEngine: Send + Sync + Sized + 'static {
    fn driver() -> Arc<dyn DatabaseDriver>;

    async fn start() -> Result<Self, ConformanceFailure>;

    fn connect_options(&self, settings: WorkspaceSettings, liveness: LivenessPolicy) -> ConnectOptions;

    /// Options whose transport is the returned `FaultTransport`, so the
    /// case can drop the route under a live connection.
    async fn faulty_connect_options(
        &self,
        settings: WorkspaceSettings,
        liveness: LivenessPolicy,
    ) -> Result<(ConnectOptions, Arc<FaultTransport>), ConformanceFailure>;

    /// The database the connection opens and the cases write in.
    fn database(&self) -> &str;

    /// Statements, one per line, that make `collection` hold `documents`
    /// documents, the `n`th with `_id` the integer `n`, `label` the text
    /// `row n` and `nested` a document holding `n`.
    fn fill_statements(&self, collection: &str, documents: u32) -> String;

    /// A read of `collection` that runs until something stops it, tagged
    /// with `marker` so the server's list of operations can find it.
    fn unbounded_statement(&self, collection: &str, marker: &str) -> String;

    /// A statement that writes the results of a read into `target`.
    fn writing_read(&self, collection: &str, target: &str) -> String;

    /// How many operations tagged with `marker` the server is running.
    async fn running_operations(&self, marker: &str) -> Result<u64, ConformanceFailure>;
}
