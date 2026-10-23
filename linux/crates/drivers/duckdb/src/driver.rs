use std::sync::Arc;

use async_trait::async_trait;
use tablepro_core::{
    ConnectOptions, ConnectTarget, Connection, DatabaseDriver, DriverCapabilities, DriverError, TimeoutPhase,
    UnsupportedFeature,
};
use tokio_util::sync::CancellationToken;

use crate::capabilities::CAPABILITIES;
use crate::connection::DuckDbConnection;

/// The DuckDB engine, compiled into the app from the sources the duckdb
/// crate ships.
#[derive(Debug, Clone, Copy, Default)]
pub struct DuckDbDriver;

#[async_trait]
impl DatabaseDriver for DuckDbDriver {
    fn id(&self) -> &'static str {
        "duckdb"
    }

    fn display_name(&self) -> &'static str {
        "DuckDB"
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
                feature: UnsupportedFeature::NetworkConnection,
            });
        };
        let opening = DuckDbConnection::open(endpoint, options.workspace_settings, options.liveness);
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
