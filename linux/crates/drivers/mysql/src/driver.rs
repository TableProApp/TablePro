use std::sync::Arc;

use async_trait::async_trait;
use tablepro_core::{
    ConfigError, ConnectOptions, ConnectTarget, Connection, DatabaseDriver, DriverCapabilities, DriverError,
};
use tokio_util::sync::CancellationToken;

use crate::capabilities::CAPABILITIES;
use crate::connection::MysqlConnection;
use crate::errors::map_pool_error;
use crate::mysql_manager::build_pool;
use crate::physical::MysqlEndpoint;
use crate::session_statements::SessionLimits;

/// MySQL and MariaDB over sqlx, reached through whatever route the
/// target's transport leads to.
#[derive(Debug, Default, Clone, Copy)]
pub struct MysqlDriver;

#[async_trait]
impl DatabaseDriver for MysqlDriver {
    fn id(&self) -> &'static str {
        "mysql"
    }

    fn display_name(&self) -> &'static str {
        "MySQL"
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
        if target.database.as_deref().is_none_or(str::is_empty) {
            return Err(DriverError::Config(ConfigError::DatabaseRequired));
        }
        if let Some(tls) = CAPABILITIES.tls.as_ref() {
            target.tls.validate(tls, target.transport.kind().class())?;
        }
        let endpoint = Arc::new(MysqlEndpoint::new(target, options.liveness)?);
        let pool = build_pool(endpoint.clone(), SessionLimits::workspace(&options.workspace_settings))?;
        // The first pool member is opened here, so a connect fails with
        // the reason the server gave and a cancel abandons the login.
        let opening = async {
            let first = pool.get().await.map_err(|error| map_pool_error(&error))?;
            Ok::<_, DriverError>((first.flavour, first.version.clone()))
        };
        let opened = tokio::select! {
            () = cancel.cancelled() => Err(DriverError::Cancelled),
            opened = opening => opened,
        };
        match opened {
            Ok((flavour, version)) => Ok(Arc::new(MysqlConnection::new(
                endpoint,
                pool,
                options.workspace_settings,
                flavour,
                flavour.server_info(&version),
            ))),
            Err(error) => {
                pool.close();
                Err(error)
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn driver_metadata() {
        assert_eq!(MysqlDriver.id(), "mysql");
        assert_eq!(MysqlDriver.display_name(), "MySQL");
        assert_eq!(MysqlDriver.capabilities().default_port(), Some(3306));
    }
}
