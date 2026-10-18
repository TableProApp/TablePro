use std::sync::Arc;

use async_trait::async_trait;
use tablepro_core::{ConnectOptions, ConnectTarget, Connection, DatabaseDriver, DriverCapabilities, DriverError};
use tokio_util::sync::CancellationToken;

use crate::capabilities::CAPABILITIES;
use crate::connection::ClickHouseConnection;
use crate::endpoint::ClickHouseEndpoint;

/// ClickHouse over its HTTP interface, reached through whatever transport
/// the target carries.
#[derive(Debug, Default, Clone, Copy)]
pub struct ClickhouseDriver;

#[async_trait]
impl DatabaseDriver for ClickhouseDriver {
    fn id(&self) -> &'static str {
        "clickhouse"
    }

    fn display_name(&self) -> &'static str {
        "ClickHouse"
    }

    fn capabilities(&self) -> &'static DriverCapabilities {
        &CAPABILITIES
    }

    async fn connect(
        &self,
        options: ConnectOptions,
        cancel: CancellationToken,
    ) -> Result<Arc<dyn Connection>, DriverError> {
        let ConnectTarget::Network(target) = &options.target else {
            return Err(DriverError::Unsupported {
                feature: "a database file",
            });
        };
        if let Some(tls) = CAPABILITIES.tls.as_ref() {
            target.tls.validate(tls, target.transport.kind().class())?;
        }
        let endpoint = Arc::new(ClickHouseEndpoint::new(
            target,
            options.liveness,
            &options.environment,
            options.workspace_settings.read_only,
        )?);
        // HTTP has no login of its own, so the first request is the one
        // that proves the credentials, and a cancel abandons it.
        let (server, database) = tokio::select! {
            () = cancel.cancelled() => return Err(DriverError::Cancelled),
            identified = endpoint.identify() => identified?,
        };
        Ok(Arc::new(ClickHouseConnection::new(
            endpoint,
            options.workspace_settings,
            server,
            database,
        )))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn driver_names_itself() {
        assert_eq!(ClickhouseDriver.id(), "clickhouse");
        assert_eq!(ClickhouseDriver.display_name(), "ClickHouse");
        assert_eq!(ClickhouseDriver.capabilities().default_port(), Some(8123));
    }
}
