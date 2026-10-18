use std::sync::Arc;

use async_trait::async_trait;
use tablepro_core::{ConnectOptions, LivenessPolicy, WorkspaceSettings};

use crate::FaultTransport;
use crate::conformance::{ConformanceEngine, ConformanceFailure};

/// An engine reached over the network, whose route a case can break and
/// whose server can be asked what is still running.
#[async_trait]
pub trait NetworkConformanceEngine: ConformanceEngine {
    /// Options whose transport is the returned `FaultTransport`, so the
    /// case can drop the route under a live connection.
    async fn faulty_connect_options(
        &self,
        settings: WorkspaceSettings,
        liveness: LivenessPolicy,
    ) -> Result<(ConnectOptions, Arc<FaultTransport>), ConformanceFailure>;

    /// A query returning one integer: how many statements carrying
    /// `marker` the server is running, not counting itself.
    fn running_statement_count_sql(&self, marker: &str) -> String;
}
