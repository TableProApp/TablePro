use std::sync::Arc;

use async_trait::async_trait;
use tablepro_core::{
    ConnectOptions, ConnectTarget, Connection, DatabaseDriver, DriverCapabilities, DriverError, TimeoutPhase,
};
use tokio_util::sync::CancellationToken;

use crate::capabilities::CAPABILITIES;
use crate::connection::SqliteConnection;

/// The workspace pool's size. SQLite runs one writer at a time, and a
/// single connection is also what lets a temporary table or an
/// attached database stay visible from one call to the next.
pub const WORKSPACE_POOL_MAX_SIZE: usize = 1;

/// The SQLite engine.
#[derive(Debug, Clone, Copy, Default)]
pub struct SqliteDriver;

#[async_trait]
impl DatabaseDriver for SqliteDriver {
    fn id(&self) -> &'static str {
        "sqlite"
    }

    fn display_name(&self) -> &'static str {
        "SQLite"
    }

    fn capabilities(&self) -> &'static DriverCapabilities {
        &CAPABILITIES
    }

    async fn connect(
        &self,
        options: ConnectOptions,
        cancel: CancellationToken,
    ) -> Result<Arc<dyn Connection>, DriverError> {
        let ConnectTarget::File(endpoint) = &options.target else {
            return Err(DriverError::Unsupported {
                feature: "network connections",
            });
        };
        let opening = SqliteConnection::open(endpoint, options.workspace_settings, options.liveness);
        tokio::select! {
            biased;
            () = cancel.cancelled() => Err(DriverError::Cancelled),
            opened = tokio::time::timeout(options.liveness.connect_timeout, opening) => match opened {
                Ok(opened) => opened.map(|connection| Arc::new(connection) as Arc<dyn Connection>),
                Err(_) => Err(DriverError::Timeout {
                    phase: TimeoutPhase::Connect,
                    server_cancelled: false,
                }),
            },
        }
    }
}
