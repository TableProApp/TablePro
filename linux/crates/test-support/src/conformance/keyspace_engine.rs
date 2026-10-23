use std::sync::Arc;

use async_trait::async_trait;
use tablepro_core::meta::KeyKind;
use tablepro_core::{ConnectOptions, DatabaseDriver, LivenessPolicy, WorkspaceSettings};

use crate::FaultTransport;
use crate::conformance::ConformanceFailure;

/// What a key-value engine's integration target supplies so the keyspace
/// suite can run against it: how to start the server and connect, and
/// the engine's own commands for what the cases set up.
#[async_trait]
pub trait KeyspaceEngine: Send + Sync + Sized + 'static {
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

    /// Commands, one per line, that make `key` hold `entries` distinct
    /// entries of `kind`, or a string of `entries` bytes.
    fn fill_commands(&self, key: &str, kind: KeyKind, entries: u32) -> String;

    /// A read that waits on `key` until something stops it.
    fn blocking_command(&self, key: &str) -> String;

    /// A command that writes `key`.
    fn write_command(&self, key: &str) -> String;

    /// A read of every entry `key` holds, one row each.
    fn read_all_command(&self, key: &str) -> String;

    /// How many commands the server holds waiting on a key now.
    async fn blocked_commands(&self) -> Result<u64, ConformanceFailure>;
}
