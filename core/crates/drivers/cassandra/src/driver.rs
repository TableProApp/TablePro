use std::sync::Arc;

use async_trait::async_trait;
use tablepro_core::{
    ConnectOptions, ConnectTarget, Connection, DatabaseDriver, DriverCapabilities, DriverError, UnsupportedFeature,
};
use tokio_util::sync::CancellationToken;

use crate::capabilities::CAPABILITIES;
use crate::connection::CqlConnection;
use crate::session::CqlEndpoint;

/// Cassandra and ScyllaDB, which speak the same native protocol.
#[derive(Debug, Default, Clone, Copy)]
pub struct CassandraDriver;

#[async_trait]
impl DatabaseDriver for CassandraDriver {
    fn id(&self) -> &'static str {
        "cassandra"
    }

    fn display_name(&self) -> &'static str {
        "Cassandra / ScyllaDB"
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
                feature: UnsupportedFeature::DatabaseFile,
            });
        };
        if let Some(tls) = CAPABILITIES.tls.as_ref() {
            target.tls.validate(tls, target.transport.kind().class())?;
        }
        let endpoint = Arc::new(CqlEndpoint::new(target, options.liveness, &options.environment).await?);
        let link = endpoint.open(endpoint.keyspace(), &cancel).await?;
        let server = tokio::select! {
            () = cancel.cancelled() => return Err(DriverError::Cancelled),
            server = tokio::time::timeout(options.liveness.login_timeout, link.server_info()) => {
                server.map_err(|_| DriverError::Timeout {
                    phase: tablepro_core::TimeoutPhase::Login,
                    server_cancelled: false,
                })??
            }
        };
        Ok(Arc::new(CqlConnection::new(
            endpoint,
            link,
            options.workspace_settings,
            server,
        )))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn driver_names_itself() {
        assert_eq!(CassandraDriver.id(), "cassandra");
        assert_eq!(CassandraDriver.display_name(), "Cassandra / ScyllaDB");
        assert_eq!(CassandraDriver.capabilities().default_port(), Some(9042));
    }
}
