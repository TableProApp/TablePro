use std::sync::Arc;
use std::time::Duration;

use secrecy::ExposeSecret;
use sqlx::mysql::{MySqlConnectOptions, MySqlConnection, MySqlSslMode};
use sqlx::{AssertSqlSafe, ConnectOptions as _, Executor as _, Row as _};
use tablepro_core::{
    ConfigError, Credentials, DriverError, LivenessPolicy, NetworkEndpoint, NetworkTarget, TimeoutPhase, TlsMode,
    Transport, TransportRoute,
};
use tokio_util::sync::CancellationToken;

use crate::errors::{map_connect_error, map_error};
use crate::flavour::MySqlFlavour;
use crate::session_statements::{SessionLimits, for_session};
use crate::workspace_session::{WORKSPACE_SQL_MODE_STATEMENT, WORKSPACE_TIME_ZONE};

/// Which session a physical connection opens as.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum SessionKind {
    /// The pool, a streamed read: TIMESTAMP in UTC, backslashes
    /// pinned to be escapes.
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
/// transport is asked only for where it leads: a TCP endpoint, or the
/// Unix socket an SSH forward listens on.
pub(crate) struct MysqlEndpoint {
    transport: Arc<dyn Transport>,
    options: MySqlConnectOptions,
    tls_server_name: String,
    liveness: LivenessPolicy,
}

impl MysqlEndpoint {
    pub(crate) fn new(target: &NetworkTarget, liveness: LivenessPolicy) -> Result<Self, DriverError> {
        let Credentials::Password { username, password } = &target.credentials else {
            return Err(DriverError::Config(ConfigError::AuthModeUnsupported));
        };
        tablepro_net::tls::check_pem_files(&target.tls)?;
        let mut options = MySqlConnectOptions::new()
            .username(username)
            .password(password.expose_secret())
            .ssl_mode(ssl_mode(target.tls.mode))
            // Each of these would send a session statement of sqlx's own
            // at login, and the session must be the server's default.
            .pipes_as_concat(false)
            .no_engine_substitution(false)
            .set_names(false)
            .timezone(None::<String>)
            // No statement outlives the call that prepared it, so a pool
            // connection never piles up server-side statement handles.
            .statement_cache_capacity(0)
            // sqlx would log every statement, values and all.
            .disable_statement_logging();
        if let Some(database) = target.database.as_deref().filter(|name| !name.is_empty()) {
            options = options.database(database);
        }
        if target.tls.mode != TlsMode::Disable {
            if let Some(ca_file) = &target.tls.ca_file {
                let pem = std::fs::read(ca_file).map_err(|error| ConfigError::CaFile {
                    path: ca_file.clone(),
                    problem: tablepro_core::CertificateFileProblem::Unreadable {
                        detail: error.to_string(),
                    },
                })?;
                options = options.ssl_ca_from_pem(pem);
            }
            let identity = tablepro_net::tls::client_identity_pem(&target.tls).map_err(|error| match error {
                tablepro_net::tls::TlsSetupError::Config(config) => DriverError::Config(config),
                other => DriverError::Tls {
                    failure: tablepro_core::TlsFailure::ClientIdentityInvalid,
                    detail: other.to_string(),
                },
            })?;
            if let Some(identity) = identity {
                options = options
                    .ssl_client_cert_from_pem(identity.certificate)
                    .ssl_client_key_from_pem(identity.key);
            }
        }
        Ok(Self {
            transport: target.transport.clone(),
            options,
            tls_server_name: target.tls_server_name().to_owned(),
            liveness,
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
    fn options_for(&self, kind: SessionKind) -> MySqlConnectOptions {
        let options = match self.transport.route() {
            TransportRoute::Tcp(endpoint) => self.options.clone().host(endpoint.host()).port(endpoint.port()),
            TransportRoute::UnixSocket(path) => self.options.clone().socket(path).host(&self.tls_server_name),
        };
        match kind {
            SessionKind::Workspace => options.timezone(Some(WORKSPACE_TIME_ZONE.to_owned())),
            SessionKind::Editor | SessionKind::Control => options,
        }
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
                Err(_) => Err(DriverError::Timeout {
                    phase: TimeoutPhase::Login,
                    server_cancelled: false,
                }),
            },
        }
    }

    async fn open(&self, kind: SessionKind, limits: &SessionLimits) -> Result<MySqlPhysical, DriverError> {
        let options = self.options_for(kind);
        let mut connection = match options.connect().await {
            Ok(connection) => connection,
            Err(error) => return Err(self.explain(map_connect_error(&error, self.service())).await),
        };
        let (connection_id, version) = identify(&mut connection, self.service()).await?;
        let flavour = MySqlFlavour::detect(&version);
        let mut statements = match kind {
            SessionKind::Control => Vec::new(),
            SessionKind::Workspace | SessionKind::Editor => for_session(flavour, limits),
        };
        if kind == SessionKind::Workspace {
            statements.push(WORKSPACE_SQL_MODE_STATEMENT.to_owned());
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

    /// A stream that closed may be the transport's doing, such as an SSH
    /// master that exited, which says more than "connection lost".
    pub(crate) async fn explain(&self, error: DriverError) -> DriverError {
        if !matches!(error, DriverError::ConnectionLost { .. }) {
            return error;
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

fn ssl_mode(mode: TlsMode) -> MySqlSslMode {
    match mode {
        TlsMode::Disable => MySqlSslMode::Disabled,
        TlsMode::Require => MySqlSslMode::Required,
        TlsMode::VerifyFull => MySqlSslMode::VerifyIdentity,
    }
}

/// The connection id and version, read over the text protocol so no
/// statement is prepared before the session is set up.
async fn identify(connection: &mut MySqlConnection, endpoint: &NetworkEndpoint) -> Result<(u64, String), DriverError> {
    let row = sqlx::raw_sql("SELECT CONNECTION_ID(), VERSION()")
        .fetch_one(&mut *connection)
        .await
        .map_err(|error| map_connect_error(&error, endpoint))?;
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
