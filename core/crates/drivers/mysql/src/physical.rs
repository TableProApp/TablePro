use std::path::Path;
use std::sync::{Arc, OnceLock};
use std::time::Duration;

use secrecy::ExposeSecret;
use sqlx::mysql::{MySqlConnectOptions, MySqlConnection, MySqlSslMode};
use sqlx::{AssertSqlSafe, ConnectOptions as _, Executor as _, Row as _};
use tablepro_core::{
    ConfigError, Credentials, DriverError, LivenessPolicy, LocalSocketProblem, NetworkEndpoint, NetworkTarget,
    TimeoutPhase, TlsMode, Transport, TransportClass, TransportError, TransportKind, TransportRoute,
};
use tablepro_net::PrivateAddress;
use tokio_util::sync::CancellationToken;

use crate::errors::{map_connect_error, map_error};
use crate::flavour::MySqlFlavour;
use crate::relay::Relay;
use crate::session_statements::{EDITOR_SQL_MODE_STATEMENT, SessionLimits, for_session};
use crate::workspace_session::{WORKSPACE_SQL_MODE_STATEMENT, WORKSPACE_TIME_ZONE};

// Room for every fixed catalog statement of either flavour.
const CACHED_STATEMENTS: usize = 32;

/// Which session a physical connection opens as.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum SessionKind {
    /// The pool, a streamed read: TIMESTAMP in UTC, backslashes
    /// pinned to be escapes, strict mode on.
    Workspace,
    /// An editor tab: the server's own zone and sql_mode, as the mysql
    /// client would have them.
    Editor,
    /// The connection that sends KILL QUERY. It runs nothing else, so
    /// it changes nothing about its session.
    Control,
}

/// One login to the server and what it said about itself.
pub(crate) struct MySqlPhysical {
    pub connection: MySqlConnection,
    /// What KILL QUERY names. The id the handshake carried is private to
    /// sqlx, so it is asked for.
    pub connection_id: u64,
    pub version: String,
    pub flavour: MySqlFlavour,
}

/// Everything needed to log in to one server, again and again.
///
/// sqlx dials the route itself rather than taking a stream, so the
/// transport is asked only for where it leads: a TCP endpoint, the Unix
/// socket an SSH forward listens on, or the relay's own listener.
pub(crate) struct MysqlEndpoint {
    transport: Arc<dyn Transport>,
    options: MySqlConnectOptions,
    tls_server_name: String,
    verifies_name: bool,
    liveness: LivenessPolicy,
    // Started by the first login over an in-process route; it stops when the endpoint drops.
    relay: OnceLock<Relay>,
}

impl MysqlEndpoint {
    pub(crate) fn new(target: &NetworkTarget, liveness: LivenessPolicy) -> Result<Self, DriverError> {
        let Credentials::Password { username, password } = &target.credentials else {
            return Err(DriverError::Config(ConfigError::AuthModeUnsupported));
        };
        tablepro_net::tls::check_pem_files(&target.tls)?;
        let local_socket = target.transport.kind().class() == TransportClass::LocalSocket;
        // MySQL counts a socket as secure and expects caching_sha2_password's cleartext there,
        // which sqlx sends only inside TLS: without it the first login after a restart is refused.
        let ssl = match (local_socket, target.tls.mode) {
            (true, TlsMode::Disable) => MySqlSslMode::Preferred,
            (_, mode) => ssl_mode(mode)?,
        };
        let mut options = MySqlConnectOptions::new()
            .username(username)
            .password(password.expose_secret())
            .ssl_mode(ssl)
            // Each of these would send a session statement of sqlx's own
            // at login, and the session must be the server's default.
            .pipes_as_concat(false)
            .no_engine_substitution(false)
            .set_names(false)
            .timezone(None::<String>)
            // No statement outlives the call that prepared it, so a
            // session never piles up server-side statement handles.
            .statement_cache_capacity(0)
            // sqlx would log every statement, values and all.
            .disable_statement_logging();
        if let Some(database) = target.database.as_deref().filter(|name| !name.is_empty()) {
            options = options.database(database);
        }
        if target.tls.mode == TlsMode::VerifyFull {
            // sqlx seeds its own Mozilla roots and takes any other trust
            // only as PEM, so the system store and the CA file go in as
            // one bundle: what PostgreSQL and ClickHouse trust too.
            let roots = tablepro_net::tls::ca_bundle_pem(&target.tls)
                .map_err(|error| tls_setup_failed(error, tablepro_core::TlsFailure::CaFileInvalid))?;
            options = options.ssl_ca_from_pem(roots);
        }
        if target.tls.mode != TlsMode::Disable {
            let identity = tablepro_net::tls::client_identity_pem(&target.tls)
                .map_err(|error| tls_setup_failed(error, tablepro_core::TlsFailure::ClientIdentityInvalid))?;
            if let Some(identity) = identity {
                options = options
                    .ssl_client_cert_from_pem(identity.certificate)
                    .ssl_client_key_from_pem(identity.key);
            }
        }
        // sqlx makes a TLS name of `host` even unchecked, and a socket's path is none.
        let tls_server_name = match (local_socket, &target.tls.server_name) {
            (true, Some(name)) => name.clone(),
            (true, None) => "localhost".to_owned(),
            (false, _) => target.tls_server_name().to_owned(),
        };
        Ok(Self {
            transport: target.transport.clone(),
            options,
            tls_server_name,
            verifies_name: target.tls.mode == TlsMode::VerifyFull,
            liveness,
            relay: OnceLock::new(),
        })
    }

    pub(crate) fn liveness(&self) -> &LivenessPolicy {
        &self.liveness
    }

    pub(crate) fn service(&self) -> &NetworkEndpoint {
        self.transport.service_endpoint()
    }

    /// The options for one login over the transport's route. Over a
    /// socket the `host` is not dialled, so it carries the name TLS
    /// verifies: the service's own, never the forward's.
    ///
    /// Over TCP, sqlx verifies the certificate against the host it dials
    /// and takes no other name, so a route whose name differs is refused
    /// rather than checked against the wrong one.
    fn options_for(&self, kind: SessionKind) -> Result<MySqlConnectOptions, DriverError> {
        let options = match self.transport.route() {
            TransportRoute::Tcp(endpoint) => self.tcp_options(endpoint.host(), endpoint.port())?,
            TransportRoute::UnixSocket(path) => self.socket_options(&path),
            TransportRoute::InProcess => match self.relay()?.address() {
                #[cfg(unix)]
                PrivateAddress::Unix(path) => self.socket_options(path),
                PrivateAddress::Tcp(address) => self.tcp_options(&address.ip().to_string(), address.port())?,
            },
        };
        Ok(match kind {
            // The catalog's fixed statements stay prepared, so a later read
            // skips the PREPARE; the bound caps the handles a pool member holds.
            SessionKind::Workspace => options
                .timezone(Some(WORKSPACE_TIME_ZONE.to_owned()))
                .statement_cache_capacity(CACHED_STATEMENTS),
            SessionKind::Editor | SessionKind::Control => options,
        })
    }

    fn tcp_options(&self, host: &str, port: u16) -> Result<MySqlConnectOptions, DriverError> {
        if self.verifies_name && host != self.tls_server_name {
            return Err(DriverError::Config(ConfigError::ServerNameOverrideUnsupported {
                route: self.transport.kind().class(),
            }));
        }
        Ok(self.options.clone().host(host).port(port))
    }

    fn socket_options(&self, path: &Path) -> MySqlConnectOptions {
        self.options.clone().socket(path).host(&self.tls_server_name)
    }

    fn relay(&self) -> Result<&Relay, DriverError> {
        if let Some(relay) = self.relay.get() {
            return Ok(relay);
        }
        let started = Relay::start(self.transport.clone()).map_err(|error| {
            DriverError::Transport(TransportError::Unreachable {
                endpoint: self.service().clone(),
                detail: format!("the local relay could not listen: {error}"),
            })
        })?;
        // A login racing this one may have set its own first; then this one stops as it drops.
        Ok(self.relay.get_or_init(|| started))
    }

    // What the relay met opening a stream, which a closed or silent login cannot say.
    fn relayed_failure(&self) -> Option<DriverError> {
        self.relay.get()?.take_failure().map(DriverError::Transport)
    }

    /// Log in and set the session up, within the connect and login
    /// timeouts. `cancel` abandons the attempt.
    pub(crate) async fn connect_physical(
        &self,
        kind: SessionKind,
        limits: &SessionLimits,
        cancel: &CancellationToken,
    ) -> Result<MySqlPhysical, DriverError> {
        let bound = self.liveness.connect_timeout + self.liveness.login_timeout;
        let opening = tokio::time::timeout(bound, self.open(kind, limits));
        tokio::select! {
            biased;
            () = cancel.cancelled() => Err(DriverError::Cancelled),
            opened = opening => match opened {
                Ok(opened) => opened,
                Err(_) => Err(self.relayed_failure().unwrap_or(DriverError::Timeout {
                    phase: TimeoutPhase::Login,
                    server_cancelled: false,
                })),
            },
        }
    }

    async fn open(&self, kind: SessionKind, limits: &SessionLimits) -> Result<MySqlPhysical, DriverError> {
        let options = self.options_for(kind)?;
        // What an earlier login's stream met is not this one's.
        if let Some(relay) = self.relay.get() {
            relay.take_failure();
        }
        let database = options.get_database();
        let mut connection = match options.connect().await {
            Ok(connection) => connection,
            Err(error) => return Err(self.explain(self.connect_error(&error, database)).await),
        };
        let (connection_id, version) = identify(&mut connection, self.service(), database).await?;
        let flavour = MySqlFlavour::detect(&version);
        let mut statements = match kind {
            SessionKind::Control => Vec::new(),
            SessionKind::Workspace | SessionKind::Editor => for_session(flavour, limits),
        };
        match kind {
            SessionKind::Workspace => statements.push(WORKSPACE_SQL_MODE_STATEMENT.to_owned()),
            SessionKind::Editor => statements.push(EDITOR_SQL_MODE_STATEMENT.to_owned()),
            SessionKind::Control => {}
        }
        if !statements.is_empty() {
            connection
                .execute(AssertSqlSafe(statements.join("; ")))
                .await
                .map_err(|error| map_error(&error, flavour))?;
        }
        Ok(MySqlPhysical {
            connection,
            connection_id,
            version,
            flavour,
        })
    }

    // sqlx opens a local socket itself, so the transport never says what was wrong with it.
    fn connect_error(&self, error: &sqlx::Error, database: Option<&str>) -> DriverError {
        if let (TransportKind::LocalSocket { path }, sqlx::Error::Io(io)) = (self.transport.kind(), error)
            && matches!(
                io.kind(),
                std::io::ErrorKind::NotFound
                    | std::io::ErrorKind::ConnectionRefused
                    | std::io::ErrorKind::PermissionDenied
            )
        {
            return DriverError::Transport(TransportError::LocalSocket {
                path,
                problem: LocalSocketProblem::from_io(io),
            });
        }
        map_connect_error(error, self.service(), database)
    }

    /// A stream that closed may be the transport's doing, such as an SSH
    /// master that exited, which says more than "connection lost".
    pub(crate) async fn explain(&self, error: DriverError) -> DriverError {
        if !matches!(error, DriverError::ConnectionLost { .. }) {
            return error;
        }
        if let Some(relayed) = self.relayed_failure() {
            return relayed;
        }
        match self.transport.explain_closed_stream().await {
            Some(transport) => DriverError::Transport(transport),
            None => error,
        }
    }

    /// Log in on a connection of its own and ask one trivial question,
    /// within `bound`. This is the probe that never waits for a pool.
    pub(crate) async fn check(&self, bound: Duration) -> Result<(), DriverError> {
        let checking = async {
            let mut physical = self.open(SessionKind::Control, &no_limits()).await?;
            let flavour = physical.flavour;
            physical
                .connection
                .execute("SELECT 1")
                .await
                .map(|_| ())
                .map_err(|error| map_error(&error, flavour))
        };
        match tokio::time::timeout(bound, checking).await {
            Ok(outcome) => outcome,
            Err(_) => Err(DriverError::Timeout {
                phase: TimeoutPhase::Probe,
                server_cancelled: false,
            }),
        }
    }
}

/// The limits of a session that sets none.
pub(crate) fn no_limits() -> SessionLimits {
    SessionLimits {
        read_only: false,
        statement_timeout: None,
        lock_timeout: Duration::ZERO,
    }
}

fn tls_setup_failed(error: tablepro_net::tls::TlsSetupError, failure: tablepro_core::TlsFailure) -> DriverError {
    match error {
        tablepro_net::tls::TlsSetupError::Config(config) => DriverError::Config(config),
        other => DriverError::Tls {
            failure,
            detail: other.to_string(),
        },
    }
}

fn ssl_mode(mode: TlsMode) -> Result<MySqlSslMode, DriverError> {
    match mode {
        TlsMode::Disable => Ok(MySqlSslMode::Disabled),
        TlsMode::Prefer => Ok(MySqlSslMode::Preferred),
        TlsMode::Require => Ok(MySqlSslMode::Required),
        TlsMode::VerifyFull => Ok(MySqlSslMode::VerifyIdentity),
        TlsMode::Strict => Err(DriverError::Config(ConfigError::UnsupportedTlsMode)),
    }
}

/// The connection id and version, read over the text protocol so no
/// statement is prepared before the session is set up.
async fn identify(
    connection: &mut MySqlConnection,
    endpoint: &NetworkEndpoint,
    database: Option<&str>,
) -> Result<(u64, String), DriverError> {
    let row = sqlx::raw_sql("SELECT CONNECTION_ID(), VERSION()")
        .fetch_one(&mut *connection)
        .await
        .map_err(|error| map_connect_error(&error, endpoint, database))?;
    let text = |index: usize| -> Result<String, DriverError> {
        let bytes: &[u8] = row.try_get_unchecked(index).map_err(|error| DriverError::Decode {
            column: index.to_string(),
            detail: error.to_string(),
        })?;
        Ok(String::from_utf8_lossy(bytes).into_owned())
    };
    let id = text(0)?;
    let connection_id = id
        .trim()
        .parse::<u64>()
        .map_err(|_| DriverError::Protocol(format!("CONNECTION_ID() returned {id:?}")))?;
    Ok((connection_id, text(1)?))
}

#[cfg(test)]
mod tests {
    use async_trait::async_trait;
    use secrecy::SecretString;
    use tablepro_core::{TlsConfig, TransportClass, TransportKind, TransportStream};

    use super::*;

    /// A route whose dial target is not the service, as a forward that
    /// listens on a local port would be.
    #[derive(Debug)]
    struct Route {
        service: NetworkEndpoint,
        kind: TransportKind,
        route: TransportRoute,
    }

    #[async_trait]
    impl Transport for Route {
        fn service_endpoint(&self) -> &NetworkEndpoint {
            &self.service
        }

        fn kind(&self) -> TransportKind {
            self.kind.clone()
        }

        fn route(&self) -> TransportRoute {
            self.route.clone()
        }

        async fn open(&self) -> Result<Box<dyn TransportStream>, TransportError> {
            Err(TransportError::Refused {
                endpoint: self.service.clone(),
            })
        }

        async fn reroute(&self, _endpoint: NetworkEndpoint) -> Result<Arc<dyn Transport>, TransportError> {
            Err(TransportError::Refused {
                endpoint: self.service.clone(),
            })
        }

        async fn explain_closed_stream(&self) -> Option<TransportError> {
            None
        }
    }

    fn endpoint(host: &str) -> NetworkEndpoint {
        NetworkEndpoint::new(host, 3306).unwrap()
    }

    fn mysql_endpoint(route: Route, server_name: Option<&str>) -> MysqlEndpoint {
        mysql_endpoint_with(
            route,
            TlsConfig {
                server_name: server_name.map(str::to_owned),
                ..TlsConfig::verify_full()
            },
        )
    }

    fn mysql_endpoint_with(route: Route, tls: TlsConfig) -> MysqlEndpoint {
        let target = NetworkTarget {
            transport: Arc::new(route),
            credentials: Credentials::Password {
                username: "app".to_owned(),
                password: SecretString::from("secret"),
            },
            database: Some("app".to_owned()),
            tls,
            options: Default::default(),
        };
        MysqlEndpoint::new(&target, LivenessPolicy::DESKTOP).unwrap()
    }

    fn in_process() -> Route {
        Route {
            service: endpoint("db.prod"),
            kind: TransportKind::SshForward {
                destination: "bastion".to_owned(),
            },
            route: TransportRoute::InProcess,
        }
    }

    #[test]
    fn a_direct_route_verifies_the_host_it_dials() {
        let direct = mysql_endpoint(
            Route {
                service: endpoint("db.prod"),
                kind: TransportKind::DirectTcp,
                route: TransportRoute::Tcp(endpoint("db.prod")),
            },
            None,
        );

        let options = direct.options_for(SessionKind::Editor).unwrap();

        assert_eq!(options.get_host(), "db.prod");
        assert_eq!(options.get_socket(), None);
    }

    /// sqlx would check the certificate against 127.0.0.1, not the name
    /// the user gave, so the login is refused before it is attempted.
    #[test]
    fn a_tcp_route_to_another_host_than_the_name_is_refused() {
        let forwarded = |server_name| {
            mysql_endpoint(
                Route {
                    service: endpoint("db.prod"),
                    kind: TransportKind::SshForward {
                        destination: "bastion".to_owned(),
                    },
                    route: TransportRoute::Tcp(endpoint("127.0.0.1")),
                },
                server_name,
            )
        };

        for server_name in [None, Some("db.internal")] {
            assert!(
                matches!(
                    forwarded(server_name).options_for(SessionKind::Workspace),
                    Err(DriverError::Config(ConfigError::ServerNameOverrideUnsupported {
                        route: TransportClass::SshForward
                    }))
                ),
                "{server_name:?}"
            );
        }
    }

    #[test]
    fn a_socket_route_carries_the_name_tls_verifies() {
        let socket = mysql_endpoint(
            Route {
                service: endpoint("db.prod"),
                kind: TransportKind::SshForward {
                    destination: "bastion".to_owned(),
                },
                route: TransportRoute::UnixSocket("/run/user/1000/forward.sock".into()),
            },
            Some("db.internal"),
        );

        let options = socket.options_for(SessionKind::Control).unwrap();

        assert_eq!(options.get_host(), "db.internal");
        assert_eq!(
            options.get_socket().map(|path| path.as_path()),
            Some(std::path::Path::new("/run/user/1000/forward.sock"))
        );
    }

    #[test]
    fn a_local_socket_logs_in_with_tls_when_offered_under_a_name_sqlx_accepts() {
        let socket = mysql_endpoint_with(
            Route {
                service: endpoint("/run/mysqld/mysqld.sock"),
                kind: TransportKind::LocalSocket {
                    path: "/run/mysqld/mysqld.sock".into(),
                },
                route: TransportRoute::UnixSocket("/run/mysqld/mysqld.sock".into()),
            },
            TlsConfig::disabled(),
        );

        let options = socket.options_for(SessionKind::Workspace).unwrap();

        assert_eq!(options.get_host(), "localhost");
        assert_eq!(
            options.get_socket().map(|path| path.as_path()),
            Some(std::path::Path::new("/run/mysqld/mysqld.sock"))
        );
        assert!(matches!(options.get_ssl_mode(), MySqlSslMode::Preferred));

        let verified = mysql_endpoint_with(
            Route {
                service: endpoint("/run/mysqld/mysqld.sock"),
                kind: TransportKind::LocalSocket {
                    path: "/run/mysqld/mysqld.sock".into(),
                },
                route: TransportRoute::UnixSocket("/run/mysqld/mysqld.sock".into()),
            },
            TlsConfig::verify_full(),
        );
        let options = verified.options_for(SessionKind::Workspace).unwrap();
        assert!(
            matches!(options.get_ssl_mode(), MySqlSslMode::VerifyIdentity),
            "an explicit check of the certificate was dropped on a socket"
        );
    }

    #[test]
    fn a_missing_local_socket_is_reported_as_the_socket() {
        let path = std::path::PathBuf::from("/run/mysqld/mysqld.sock");
        let socket = mysql_endpoint_with(
            Route {
                service: endpoint("/run/mysqld/mysqld.sock"),
                kind: TransportKind::LocalSocket { path: path.clone() },
                route: TransportRoute::UnixSocket(path.clone()),
            },
            TlsConfig::disabled(),
        );
        let missing = sqlx::Error::Io(std::io::Error::from(std::io::ErrorKind::NotFound));

        assert_eq!(
            socket.connect_error(&missing, None),
            DriverError::Transport(TransportError::LocalSocket {
                path,
                problem: LocalSocketProblem::Missing,
            })
        );
    }

    #[cfg(unix)]
    #[tokio::test]
    async fn an_in_process_route_dials_the_relay_socket_with_the_name_tls_verifies() {
        let relayed = mysql_endpoint(in_process(), Some("db.internal"));

        let first = relayed.options_for(SessionKind::Workspace).unwrap();
        let again = relayed.options_for(SessionKind::Editor).unwrap();

        assert_eq!(first.get_host(), "db.internal");
        let socket = first.get_socket().expect("a socket path");
        assert!(socket.exists(), "nothing listens at {}", socket.display());
        assert_eq!(again.get_socket(), Some(socket), "one relay serves every login");
    }

    // sqlx would check the certificate against 127.0.0.1, so only a login that checks no name dials the port.
    #[cfg(not(unix))]
    #[tokio::test]
    async fn an_in_process_route_dials_the_relay_port_unless_a_name_is_checked() {
        let verified = mysql_endpoint(in_process(), None);
        let required = mysql_endpoint_with(
            in_process(),
            TlsConfig {
                mode: TlsMode::Require,
                ..TlsConfig::disabled()
            },
        );

        let options = required.options_for(SessionKind::Control).unwrap();

        assert!(matches!(
            verified.options_for(SessionKind::Workspace),
            Err(DriverError::Config(ConfigError::ServerNameOverrideUnsupported {
                route: TransportClass::SshForward
            }))
        ));
        let Some(PrivateAddress::Tcp(relay)) = required.relay.get().map(Relay::address) else {
            panic!("no relay listens on a port");
        };
        assert_eq!(options.get_host(), "127.0.0.1");
        assert_eq!(options.get_port(), relay.port());
        assert_eq!(options.get_socket(), None);
    }

    #[tokio::test]
    async fn a_relayed_login_reports_why_the_transport_could_not_open() {
        let relayed = mysql_endpoint_with(in_process(), TlsConfig::disabled());

        let opened = tokio::time::timeout(
            Duration::from_secs(10),
            relayed.open(SessionKind::Control, &no_limits()),
        )
        .await
        .expect("the login ended");

        let Err(error) = opened else {
            panic!("a login with no server succeeded");
        };
        assert!(
            matches!(error, DriverError::Transport(TransportError::Refused { .. })),
            "{error:?}"
        );
    }

    #[test]
    fn each_mode_asks_sqlx_for_what_the_mysql_client_does() {
        let modes = [
            (TlsMode::Disable, MySqlSslMode::Disabled),
            (TlsMode::Prefer, MySqlSslMode::Preferred),
            (TlsMode::Require, MySqlSslMode::Required),
            (TlsMode::VerifyFull, MySqlSslMode::VerifyIdentity),
        ];
        for (mode, expected) in modes {
            assert!(
                matches!(ssl_mode(mode), Ok(asked) if std::mem::discriminant(&asked) == std::mem::discriminant(&expected)),
                "{mode:?}"
            );
        }
        assert!(ssl_mode(TlsMode::Strict).is_err());
    }
}
