use std::sync::Arc;

use async_trait::async_trait;
use tablepro_core::{
    ConnectOptions, ConnectTarget, Connection, DatabaseDriver, DriverCapabilities, DriverError, TlsCapabilities,
};
use tokio_util::sync::CancellationToken;
use tokio_util::task::TaskTracker;

use crate::capabilities::CAPABILITIES;
use crate::connection::PgConnection;
use crate::errors::map_pool_error;
use crate::physical::{PgEndpoint, server_info};
use crate::pool::build_pool;

/// PostgreSQL over tokio-postgres, reached through whatever transport the
/// target carries.
#[derive(Debug, Default, Clone, Copy)]
pub struct PgDriver;

#[async_trait]
impl DatabaseDriver for PgDriver {
    fn id(&self) -> &'static str {
        "postgres"
    }

    fn display_name(&self) -> &'static str {
        "PostgreSQL"
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
        let tls: Option<&TlsCapabilities> = CAPABILITIES.tls.as_ref();
        if let Some(tls) = tls {
            target.tls.validate(tls, target.transport.kind().class())?;
        }
        let endpoint = Arc::new(PgEndpoint::new(target, options.liveness)?);
        let tracker = TaskTracker::new();
        let pool = build_pool(endpoint.clone(), tracker.clone())?;
        // The first pool member is opened here, so a connect fails with
        // the reason the server gave and a cancel abandons the login.
        let opening = async {
            let first = pool.get().await.map_err(|error| map_pool_error(&error))?;
            server_info(&first).await
        };
        let opened = tokio::select! {
            () = cancel.cancelled() => Err(DriverError::Cancelled),
            opened = opening => opened,
        };
        match opened {
            Ok(server) => Ok(Arc::new(PgConnection::new(
                endpoint,
                pool,
                tracker,
                options.workspace_settings,
                server,
            ))),
            Err(error) => {
                pool.close();
                tracker.close();
                Err(endpoint.explain(error).await)
            }
        }
    }
}
