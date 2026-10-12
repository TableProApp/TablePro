use std::sync::Arc;

use async_trait::async_trait;
use tablepro_core::{
    ConfigError, ConnectOptions, ConnectTarget, Connection, DatabaseDriver, DriverCapabilities, DriverError,
};
use tokio_util::sync::CancellationToken;

use crate::capabilities::CAPABILITIES;
use crate::connection::MssqlConnection;
use crate::endpoint::MssqlEndpoint;
use crate::errors::map_pool_error;
use crate::mssql_manager::build_pool;
use crate::physical::server_info;

/// SQL Server over tiberius, reached through whatever transport the
/// target carries.
#[derive(Debug, Default, Clone, Copy)]
pub struct MssqlDriver;

#[async_trait]
impl DatabaseDriver for MssqlDriver {
    fn id(&self) -> &'static str {
        "mssql"
    }

    fn display_name(&self) -> &'static str {
        "SQL Server"
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
        if !CAPABILITIES.supports(target.credentials.mode()) {
            return Err(DriverError::Config(ConfigError::AuthModeUnsupported));
        }
        let endpoint = Arc::new(MssqlEndpoint::new(
            target,
            options.liveness,
            &options.workspace_settings,
        )?);
        let pool = build_pool(endpoint.clone())?;
        // The first pool member is opened here, so a connect fails with
        // the reason the server gave and a cancel abandons the login.
        let opening = async {
            let mut first = pool.get().await.map_err(map_pool_error)?;
            server_info(&mut first).await
        };
        let opened = tokio::select! {
            biased;
            () = cancel.cancelled() => Err(DriverError::Cancelled),
            opened = opening => opened,
        };
        match opened {
            Ok(server) => Ok(Arc::new(MssqlConnection::new(
                endpoint,
                pool,
                options.workspace_settings,
                server,
            ))),
            Err(error) => {
                pool.close();
                Err(endpoint.explain(error).await)
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use std::path::PathBuf;

    use tablepro_core::{ConnectEnvironment, FileEndpoint, LivenessPolicy, WorkspaceSettings};

    use super::*;

    #[test]
    fn driver_names_itself() {
        assert_eq!(MssqlDriver.id(), "mssql");
        assert_eq!(MssqlDriver.display_name(), "SQL Server");
        assert_eq!(MssqlDriver.capabilities().default_port(), Some(1433));
    }

    #[tokio::test]
    async fn a_database_file_is_refused() {
        let file = FileEndpoint::open_existing(PathBuf::from("/tmp/tablepro.db")).unwrap();
        let options = ConnectOptions {
            target: ConnectTarget::File(file),
            workspace_settings: WorkspaceSettings::workspace(false),
            liveness: LivenessPolicy::DESKTOP,
            environment: ConnectEnvironment::new("test"),
        };

        let outcome = MssqlDriver.connect(options, CancellationToken::new()).await;

        assert!(matches!(outcome, Err(DriverError::Unsupported { .. })));
    }
}
