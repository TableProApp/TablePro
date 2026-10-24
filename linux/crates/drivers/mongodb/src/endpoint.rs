use std::future::Future;
use std::pin::Pin;
use std::sync::Arc;
use std::time::Duration;

use bson::doc;
use mongodb::Client;
use mongodb::error::ErrorKind;
use mongodb::options::{ClientOptions, Credential, DriverInfo, ServerAddress};
use rustls_pki_types::ServerName;
use secrecy::ExposeSecret;
use tablepro_core::{
    APPLICATION_NAME, ConfigError, ConnectEnvironment, Credentials, DriverError, LivenessPolicy, LossPhase,
    NetworkEndpoint, NetworkTarget, ServerInfo, TimeoutPhase, TlsFailure, Transport, TransportRoute,
};
use tablepro_net::tls::{TlsSetupError, build_client_config};
use tokio_rustls::TlsConnector;

use crate::client_tls::{ClientTls, private_dir};
use crate::connect_watch::ConnectWatch;
use crate::errors::map_error;
use crate::relay::{Relay, RelayTls, closed_unanswered};
use crate::server_version;

/// What a client of this connection is for, which sets how many
/// connections it may hold.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum ClientUse {
    /// The sidebar, the grid and saves, several at once.
    Workspace,
    /// The health probe and the check after a failed call: one
    /// connection of its own, so a busy workspace never holds it up.
    Probe,
    /// An editor tab or an export: its work, and its stop beside it.
    Own,
}

impl ClientUse {
    fn pool_size(self) -> u32 {
        match self {
            Self::Workspace => 8,
            Self::Probe => 1,
            Self::Own => 2,
        }
    }
}

/// How the client library reaches the servers.
enum Route {
    /// The library dials the servers and sets up TLS itself.
    Dialed(ClientTls),
    /// The library dials a relay whose streams come from the transport.
    Relayed(Relay),
}

/// Everything needed to open a client to the server: where it is, how
/// TLS is set up and the login. The workspace's client, the probe's and
/// each editor tab's and export's open from here.
pub(crate) struct MongoEndpoint {
    transport: Arc<dyn Transport>,
    service: NetworkEndpoint,
    template: ClientOptions,
    route: Route,
    liveness: LivenessPolicy,
    database: Option<String>,
}

impl MongoEndpoint {
    /// Resolves a DNS seed list and reads the TLS files, so the file part
    /// runs off the runtime and the rest is awaited.
    pub(crate) async fn new(
        target: &NetworkTarget,
        liveness: LivenessPolicy,
        environment: &ConnectEnvironment,
    ) -> Result<Self, DriverError> {
        let service = target.transport.service_endpoint().clone();
        let database = target.database.clone().filter(|name| !name.trim().is_empty());
        let mut template = match (target.options.dns_seed_list, target.transport.route()) {
            (true, TransportRoute::Tcp(_)) => seed_list(&service).await?,
            (true, TransportRoute::UnixSocket(_)) => return Err(ConfigError::SeedListOverSsh.into()),
            (false, TransportRoute::Tcp(endpoint)) => single_host(ServerAddress::Tcp {
                host: endpoint.host().to_owned(),
                port: Some(endpoint.port()),
            }),
            // Filled in once the relay listens.
            (false, TransportRoute::UnixSocket(_)) => single_host(ServerAddress::Tcp {
                host: service.host().to_owned(),
                port: Some(service.port()),
            }),
        };
        // A seed list's TXT record may name the authentication database.
        let listed_source = template.credential.take().and_then(|listed| listed.source);
        template.credential = credential(target)?.map(|mut credential| {
            credential.source = credential.source.or(listed_source);
            credential
        });
        template.app_name = Some(APPLICATION_NAME.to_owned());
        template.driver_info = Some(
            DriverInfo::builder()
                .name(APPLICATION_NAME)
                .version(environment.client_version.clone())
                .build(),
        );
        template.connect_timeout = Some(liveness.connect_timeout);
        template.server_selection_timeout = Some(liveness.login_timeout);
        // One operation is one send: a retried read or write would outlive
        // the stop and the ledger that account for it.
        template.retry_reads = Some(false);
        template.retry_writes = Some(false);
        template.min_pool_size = Some(0);

        let tls = target.tls.clone();
        let route = match target.transport.route() {
            TransportRoute::Tcp(_) => {
                Route::Dialed(tablepro_net::tls::set_up_off_runtime(move || ClientTls::new(&tls)).await?)
            }
            TransportRoute::UnixSocket(_) => {
                let server_name = target.tls_server_name().to_owned();
                let relay_tls = tablepro_net::tls::set_up_off_runtime(move || relay_tls(&tls, server_name)).await?;
                let relay = Relay::start(target.transport.clone(), relay_tls, liveness.login_timeout)
                    .map_err(|error| DriverError::Protocol(format!("the relay socket could not open: {error}")))?;
                template.hosts = vec![ServerAddress::Unix {
                    path: relay.path().to_owned(),
                }];
                template.tls = None;
                Route::Relayed(relay)
            }
        };
        Ok(Self {
            transport: target.transport.clone(),
            service,
            template,
            route,
            liveness,
            database,
        })
    }

    pub(crate) fn liveness(&self) -> &LivenessPolicy {
        &self.liveness
    }

    /// The database the connection names, if any.
    pub(crate) fn database(&self) -> Option<&str> {
        self.database.as_deref()
    }

    /// A new client, connected: its first server answered a `ping` under
    /// the login timeout, so a refused password or a failed handshake is
    /// this call's error. A server that every heartbeat fails to reach
    /// fails the open at once rather than at the end of the timeout.
    pub(crate) fn open(
        &self,
        purpose: ClientUse,
    ) -> Pin<Box<dyn Future<Output = Result<Client, DriverError>> + Send + '_>> {
        Box::pin(async move {
            let watch = ConnectWatch::new();
            let mut options = self.template.clone();
            options.max_pool_size = Some(purpose.pool_size());
            options.sdam_event_handler = Some(watch.handler());
            // What an earlier client's streams met is not this one's. The
            // client starts its monitors as it is built, so a failure
            // they meet lands after this.
            if let Route::Relayed(relay) = &self.route {
                relay.failure().take();
            }
            let client = self.build(options).await?;
            let admin = client.database("admin");
            let ping = admin.run_command(doc! { "ping": 1_i32 });
            let answered = tokio::select! {
                answered = tokio::time::timeout(self.liveness.login_timeout, ping) => answered,
                failure = watch.unreachable() => Ok(Err(failure)),
            };
            match answered {
                Ok(Ok(_)) => Ok(client),
                Ok(Err(error)) => {
                    client.shutdown().immediate(true).await;
                    Err(self.explain(&error, LossPhase::Connect).await)
                }
                Err(_) => {
                    client.shutdown().immediate(true).await;
                    Err(match self.relayed_failure() {
                        Some(error) => error,
                        None => DriverError::Timeout {
                            phase: TimeoutPhase::Login,
                            server_cancelled: false,
                        },
                    })
                }
            }
        })
    }

    /// Build the client where the library reads its TLS files, which live
    /// only until it has.
    async fn build(&self, mut options: ClientOptions) -> Result<Client, DriverError> {
        let tls = match &self.route {
            Route::Dialed(tls) => Some(tls.clone()),
            Route::Relayed(_) => None,
        };
        let runtime = tokio::runtime::Handle::current();
        let built = tokio::task::spawn_blocking(move || {
            let _entered = runtime.enter();
            let dir = private_dir()?;
            if let Some(tls) = tls {
                options.tls = Some(tls.option(dir.path())?);
            }
            Ok::<_, std::io::Error>(Client::with_options(options))
        })
        .await
        .map_err(|_| DriverError::Protocol("building the client panicked".to_owned()))?
        .map_err(|error| DriverError::Protocol(format!("the TLS files could not be written: {error}")))?;
        built.map_err(|error| map_error(&error, &self.service, LossPhase::Connect))
    }

    /// What a failed call means, with what the transport knows about a
    /// closed stream and what the relay saw. Boxed as `Send`, which a
    /// caller deep in a spawned call cannot otherwise prove for every
    /// lifetime of the borrows.
    pub(crate) fn explain<'a>(
        &'a self,
        error: &'a mongodb::error::Error,
        during: LossPhase,
    ) -> Pin<Box<dyn Future<Output = DriverError> + Send + 'a>> {
        Box::pin(async move {
            let mapped = map_error(error, &self.service, during);
            if !matches!(mapped, DriverError::ConnectionLost { .. } | DriverError::Transport(_)) {
                return mapped;
            }
            if let Some(relayed) = self.relayed_failure() {
                return relayed;
            }
            if self.closed_in_tls(error, during) {
                return closed_unanswered();
            }
            match self.transport.explain_closed_stream().await {
                Some(explained) => DriverError::Transport(explained),
                None => mapped,
            }
        })
    }

    /// A connect the server ended on a TLS session the library set up,
    /// before any answer: the session ended without TLS's own close.
    fn closed_in_tls(&self, error: &mongodb::error::Error, during: LossPhase) -> bool {
        let Route::Dialed(tls) = &self.route else {
            return false;
        };
        during == LossPhase::Connect
            && tls.enabled()
            && matches!(error.kind.as_ref(), ErrorKind::Io(io) if io.kind() == std::io::ErrorKind::UnexpectedEof)
    }

    fn relayed_failure(&self) -> Option<DriverError> {
        match &self.route {
            Route::Relayed(relay) => relay.failure().take(),
            Route::Dialed(_) => None,
        }
    }

    /// What the server is, from `buildInfo`. A login that may not run it
    /// still connects, without a version.
    pub(crate) async fn server_info(&self, client: &Client) -> ServerInfo {
        let admin = client.database("admin");
        let asked = admin.run_command(doc! { "buildInfo": 1_i32 });
        match tokio::time::timeout(self.liveness.login_timeout, asked).await {
            Ok(Ok(reply)) => server_version::server_info(reply.get_str("version").unwrap_or_default()),
            _ => server_version::server_info(""),
        }
    }

    pub(crate) fn cancel_grace(&self) -> Duration {
        self.liveness.cancel_grace
    }
}

fn single_host(address: ServerAddress) -> ClientOptions {
    let mut options = ClientOptions::default();
    options.hosts = vec![address];
    // One host is the server the user named, as mongosh connects to it:
    // the servers a replica set lists by their own names may not be
    // reachable from here.
    options.direct_connection = Some(true);
    options
}

/// The servers the host's SRV records name, with the options its TXT
/// record sets, such as the replica set and the authentication database.
async fn seed_list(service: &NetworkEndpoint) -> Result<ClientOptions, DriverError> {
    let uri = format!("mongodb+srv://{}/", percent_encoded(service.host()));
    ClientOptions::parse(uri.as_str())
        .await
        .map_err(|error| map_error(&error, service, LossPhase::Connect))
}

/// The login, checked in the database the user is defined in: the one
/// named for it, else for a seed list the one its TXT record names or
/// `admin`, else the connection's database, else `admin`, as the macOS
/// app and mongosh choose.
fn credential(target: &NetworkTarget) -> Result<Option<Credential>, DriverError> {
    let Credentials::Password { username, password } = &target.credentials else {
        return Err(ConfigError::AuthModeUnsupported.into());
    };
    if username.trim().is_empty() {
        return Ok(None);
    }
    let database = target
        .database
        .as_deref()
        .map(str::trim)
        .filter(|name| !name.is_empty());
    let source = match (target.options.auth_database(), target.options.dns_seed_list, database) {
        (Some(explicit), _, _) => Some(explicit.to_owned()),
        (None, true, _) => None,
        (None, false, Some(database)) => Some(database.to_owned()),
        (None, false, None) => Some("admin".to_owned()),
    };
    let mut credential = Credential::default();
    credential.username = Some(username.trim().to_owned());
    credential.password = Some(password.expose_secret().to_owned());
    credential.source = source;
    Ok(Some(credential))
}

fn relay_tls(tls: &tablepro_core::TlsConfig, server_name: String) -> Result<Option<RelayTls>, DriverError> {
    let Some(config) = build_client_config(tls).map_err(setup_error)? else {
        return Ok(None);
    };
    let server_name = ServerName::try_from(server_name).map_err(|_| ConfigError::InvalidServerName)?;
    Ok(Some(RelayTls {
        connector: TlsConnector::from(config),
        server_name,
    }))
}

pub(crate) fn setup_error(error: TlsSetupError) -> DriverError {
    match error {
        TlsSetupError::Config(error) => DriverError::Config(error),
        TlsSetupError::ClientIdentity(error) => DriverError::Tls {
            failure: TlsFailure::ClientIdentityInvalid,
            detail: error.to_string(),
        },
        other => DriverError::Tls {
            failure: TlsFailure::Other,
            detail: other.to_string(),
        },
    }
}

/// A host as it goes into a connection string, every byte outside the
/// unreserved set escaped.
fn percent_encoded(text: &str) -> String {
    let mut out = String::with_capacity(text.len());
    for byte in text.bytes() {
        if byte.is_ascii_alphanumeric() || matches!(byte, b'-' | b'.' | b'_' | b'~') {
            out.push(char::from(byte));
        } else {
            out.push_str(&format!("%{byte:02X}"));
        }
    }
    out
}

#[cfg(test)]
mod tests {
    use secrecy::SecretString;
    use tablepro_core::{NetworkOptions, TlsConfig, TransportError, TransportKind, TransportStream};

    use super::*;

    #[derive(Debug)]
    struct Direct(NetworkEndpoint);

    #[async_trait::async_trait]
    impl Transport for Direct {
        fn service_endpoint(&self) -> &NetworkEndpoint {
            &self.0
        }

        fn kind(&self) -> TransportKind {
            TransportKind::DirectTcp
        }

        fn route(&self) -> TransportRoute {
            TransportRoute::Tcp(self.0.clone())
        }

        async fn open(&self) -> Result<Box<dyn TransportStream>, TransportError> {
            let (client, _server) = tokio::io::duplex(64);
            Ok(Box::new(client))
        }

        async fn reroute(&self, endpoint: NetworkEndpoint) -> Result<Arc<dyn Transport>, TransportError> {
            Ok(Arc::new(Self(endpoint)))
        }

        async fn explain_closed_stream(&self) -> Option<TransportError> {
            None
        }
    }

    fn target(username: &str, database: Option<&str>, options: NetworkOptions) -> NetworkTarget {
        NetworkTarget {
            transport: Arc::new(Direct(
                NetworkEndpoint::new("db.example.com", 27017).expect("an endpoint"),
            )),
            credentials: Credentials::Password {
                username: username.to_owned(),
                password: SecretString::from("secret"),
            },
            database: database.map(str::to_owned),
            tls: TlsConfig::disabled(),
            options,
        }
    }

    fn source(target: &NetworkTarget) -> Option<String> {
        credential(target)
            .expect("a login")
            .and_then(|credential| credential.source)
    }

    #[test]
    fn the_user_is_checked_where_it_is_defined() {
        let explicit = NetworkOptions {
            auth_database: Some(" users ".to_owned()),
            ..NetworkOptions::default()
        };
        let seed_list = NetworkOptions {
            dns_seed_list: true,
            ..NetworkOptions::default()
        };

        assert_eq!(source(&target("ann", Some("shop"), explicit)).as_deref(), Some("users"));
        assert_eq!(
            source(&target("ann", Some("shop"), NetworkOptions::default())).as_deref(),
            Some("shop")
        );
        assert_eq!(
            source(&target("ann", None, NetworkOptions::default())).as_deref(),
            Some("admin")
        );
        assert_eq!(
            source(&target("ann", Some("shop"), seed_list)),
            None,
            "the TXT record or admin"
        );
        assert!(
            credential(&target("  ", Some("shop"), NetworkOptions::default()))
                .expect("no login")
                .is_none()
        );
    }

    #[test]
    fn a_host_is_escaped_for_a_connection_string() {
        assert_eq!(percent_encoded("cluster0.example.net"), "cluster0.example.net");
        assert_eq!(percent_encoded("a/b@c"), "a%2Fb%40c");
    }
}
