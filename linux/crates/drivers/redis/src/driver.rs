use std::sync::Arc;

use async_trait::async_trait;
use tablepro_core::{
    ConnectOptions, ConnectTarget, Connection, DatabaseDriver, DriverCapabilities, DriverError, UnsupportedFeature,
};
use tokio_util::sync::CancellationToken;

use crate::capabilities::CAPABILITIES;
use crate::connection::RedisConnection;
use crate::endpoint::RedisEndpoint;

/// Redis, and servers that speak its protocol such as Valkey, over
/// redis-rs, reached through whatever transport the target carries.
#[derive(Debug, Default, Clone, Copy)]
pub struct RedisDriver;

#[async_trait]
impl DatabaseDriver for RedisDriver {
    fn id(&self) -> &'static str {
        "redis"
    }

    fn display_name(&self) -> &'static str {
        "Redis"
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
        let (setup_target, liveness, environment) = (target.clone(), options.liveness, options.environment.clone());
        let endpoint = Arc::new(
            tablepro_net::tls::set_up_off_runtime(move || {
                RedisEndpoint::new(&setup_target, liveness, &environment)
            })
            .await?,
        );
        // The first link opens here, so a refused password or a failed
        // handshake is the connect's error and a cancel abandons the login.
        let opening = async {
            let first = endpoint.open().await?;
            let server = endpoint.server_info(&first).await?;
            Ok::<_, DriverError>((first, server))
        };
        let opened = tokio::select! {
            () = cancel.cancelled() => Err(DriverError::Cancelled),
            opened = opening => opened,
        };
        let (first, server) = match opened {
            Ok(opened) => opened,
            Err(error) => return Err(endpoint.explain(error).await),
        };
        Ok(Arc::new(RedisConnection::new(
            endpoint,
            first,
            options.workspace_settings,
            server,
        )))
    }
}
