use std::sync::Arc;

use async_trait::async_trait;
use bson::{Bson, doc};
use mongodb::Client;
use tablepro_core::{
    ConnectOptions, ConnectTarget, Connection, DatabaseDriver, DriverCapabilities, DriverError, UnsupportedFeature,
};
use tokio_util::sync::CancellationToken;

use crate::capabilities::CAPABILITIES;
use crate::connection::MongoConnection;
use crate::endpoint::{ClientUse, MongoEndpoint};

/// The database mongosh opens when none is named.
const SHELL_DEFAULT: &str = "test";

/// MongoDB, and servers that speak its protocol, over the mongodb crate,
/// reached through whatever transport the target carries.
#[derive(Debug, Default, Clone, Copy)]
pub struct MongoDriver;

#[async_trait]
impl DatabaseDriver for MongoDriver {
    fn id(&self) -> &'static str {
        "mongodb"
    }

    fn display_name(&self) -> &'static str {
        "MongoDB"
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
        target
            .options
            .validate(&CAPABILITIES, target.transport.kind().class())?;
        // The workspace's client and the probe's open here, so a refused
        // password or a failed handshake is the connect's error and a
        // cancel abandons the login.
        let opening = async {
            let endpoint = Arc::new(MongoEndpoint::new(target, options.liveness, &options.environment).await?);
            let client = endpoint.open(ClientUse::Workspace).await?;
            let probe = match endpoint.open(ClientUse::Probe).await {
                Ok(probe) => probe,
                Err(error) => {
                    client.shutdown().immediate(true).await;
                    return Err(error);
                }
            };
            let server = endpoint.server_info(&client).await;
            let database = default_database(&endpoint, &client).await;
            Ok::<_, DriverError>((endpoint, client, probe, server, database))
        };
        let (endpoint, client, probe, server, database) = tokio::select! {
            () = cancel.cancelled() => return Err(DriverError::Cancelled),
            opened = opening => opened?,
        };
        Ok(Arc::new(MongoConnection::new(
            endpoint,
            client,
            probe,
            options.workspace_settings,
            server,
            database,
        )))
    }
}

/// The database the connection names, else the first the login may see
/// that MongoDB does not keep for itself, else mongosh's own default.
async fn default_database(endpoint: &MongoEndpoint, client: &Client) -> String {
    if let Some(named) = endpoint.database() {
        return named.trim().to_owned();
    }
    let admin = client.database("admin");
    let listing = admin.run_command(doc! { "listDatabases": 1_i32, "nameOnly": true, "authorizedDatabases": true });
    let names: Vec<String> = match tokio::time::timeout(endpoint.liveness().login_timeout, listing).await {
        Ok(Ok(answer)) => match answer.get("databases") {
            Some(Bson::Array(items)) => items
                .iter()
                .filter_map(|item| item.as_document()?.get_str("name").ok().map(str::to_owned))
                .collect(),
            _ => Vec::new(),
        },
        _ => Vec::new(),
    };
    let mut user: Vec<String> = names
        .into_iter()
        .filter(|name| !["admin", "config", "local"].contains(&name.as_str()))
        .collect();
    user.sort();
    user.into_iter().next().unwrap_or_else(|| SHELL_DEFAULT.to_owned())
}
