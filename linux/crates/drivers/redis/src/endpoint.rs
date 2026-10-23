use std::io;
use std::sync::Arc;

use redis::aio::MultiplexedConnection;
use redis::{AsyncConnectionConfig, RedisConnectionInfo, Value};
use rustls_pki_types::ServerName;
use secrecy::ExposeSecret;
use tablepro_core::{
    APPLICATION_NAME, ConfigError, ConnectEnvironment, Credentials, DriverError, LivenessPolicy, LossPhase,
    NetworkTarget, ServerInfo, TimeoutPhase, TlsFailure, Transport, TransportError, TransportStream,
};
use tablepro_net::tls::{TlsSetupError, build_client_config};
use tokio_rustls::TlsConnector;

use crate::errors::{map_error, server_error};
use crate::link::{Link, command};
use crate::server_version;
use crate::tls_watch::{TlsFailureSlot, TlsWatch};

/// Everything needed to open a link to one server: the transport, the
/// TLS it negotiates and the login. Every link of a connection, its
/// editor sessions and its exports included, opens from here.
pub(crate) struct RedisEndpoint {
    transport: Arc<dyn Transport>,
    tls: Option<TlsSetup>,
    login: RedisConnectionInfo,
    liveness: LivenessPolicy,
}

struct TlsSetup {
    connector: TlsConnector,
    server_name: ServerName<'static>,
}

impl RedisEndpoint {
    /// Reads the CA and client files, so it runs off the runtime.
    pub(crate) fn new(
        target: &NetworkTarget,
        liveness: LivenessPolicy,
        environment: &ConnectEnvironment,
    ) -> Result<Self, DriverError> {
        let database = tablepro_core::keyspace::database_number(target.database.as_deref())?;
        let login = login(&target.credentials)?
            .set_db(i64::from(database))
            .set_lib_name(APPLICATION_NAME, &environment.client_version);
        let tls = match build_client_config(&target.tls).map_err(setup_error)? {
            Some(config) => Some(TlsSetup {
                connector: TlsConnector::from(config),
                server_name: ServerName::try_from(target.tls_server_name().to_owned())
                    .map_err(|_| ConfigError::InvalidServerName)?,
            }),
            None => None,
        };
        Ok(Self {
            transport: target.transport.clone(),
            tls,
            login,
            liveness,
        })
    }

    pub(crate) fn liveness(&self) -> &LivenessPolicy {
        &self.liveness
    }

    /// A new link, logged in on the connection's database, named in the
    /// server's client list, with its client id read.
    pub(crate) async fn open(&self) -> Result<Link, DriverError> {
        let slot = TlsFailureSlot::default();
        let opened = self.login(&slot).await;
        match (opened, slot.get()) {
            (Err(DriverError::ConnectionLost { .. }), Some((failure, detail))) => {
                Err(DriverError::Tls { failure, detail })
            }
            (opened, _) => opened,
        }
    }

    async fn login(&self, slot: &TlsFailureSlot) -> Result<Link, DriverError> {
        let stream = self.stream(slot).await?;
        let config = AsyncConnectionConfig::new()
            .set_connection_timeout(None)
            .set_response_timeout(None);
        let login = MultiplexedConnection::new_with_config(&self.login, stream, config);
        let (connection, reader) = match tokio::time::timeout(self.liveness.login_timeout, login).await {
            Err(_) => {
                return Err(DriverError::Timeout {
                    phase: TimeoutPhase::Login,
                    server_cancelled: false,
                });
            }
            Ok(Err(error)) => return Err(self.explain(map_error(&error, LossPhase::Connect)).await),
            Ok(Ok(opened)) => opened,
        };
        let link = Link::new(connection, tokio::spawn(reader));
        let named = tokio::time::timeout(self.liveness.login_timeout, identify(&link)).await;
        match named {
            Err(_) => Err(DriverError::Timeout {
                phase: TimeoutPhase::Login,
                server_cancelled: false,
            }),
            Ok(Err(error)) => Err(self.explain(error).await),
            Ok(Ok(client_id)) => Ok(link.with_client_id(client_id)),
        }
    }

    /// What the server is, asked on `link`. A login that may not run
    /// `INFO` still connects, without a version.
    pub(crate) async fn server_info(&self, link: &Link) -> Result<ServerInfo, DriverError> {
        let info = command(&["INFO", "server"]);
        let asked = tokio::time::timeout(self.liveness.login_timeout, link.send(&info));
        let reply = asked.await.map_err(|_| DriverError::Timeout {
            phase: TimeoutPhase::Login,
            server_cancelled: false,
        })??;
        match reply {
            Value::BulkString(bytes) => Ok(server_version::server_info(&String::from_utf8_lossy(&bytes))),
            Value::VerbatimString { text, .. } => Ok(server_version::server_info(&text)),
            _ => Ok(server_version::unknown()),
        }
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

    async fn stream(&self, slot: &TlsFailureSlot) -> Result<Box<dyn TransportStream>, DriverError> {
        let bound = self.liveness.connect_timeout;
        let stream = match tokio::time::timeout(bound, self.transport.open()).await {
            Err(_) => {
                return Err(TransportError::Timeout {
                    phase: TimeoutPhase::Connect,
                }
                .into());
            }
            Ok(opened) => opened?,
        };
        let Some(tls) = &self.tls else {
            return Ok(stream);
        };
        let handshake = tls.connector.connect(tls.server_name.clone(), stream);
        match tokio::time::timeout(bound, handshake).await {
            Err(_) => Err(DriverError::Timeout {
                phase: TimeoutPhase::Connect,
                server_cancelled: false,
            }),
            Ok(Err(error)) => Err(self.explain(handshake_error(&error)).await),
            Ok(Ok(stream)) => Ok(Box::new(TlsWatch::new(stream, slot.clone()))),
        }
    }
}

/// The login a link sends. redis-rs sends `AUTH` only with a password,
/// so a named user is always sent one, empty for an ACL user with
/// `nopass`; with neither, the link stays the `default` user's.
fn login(credentials: &Credentials) -> Result<RedisConnectionInfo, DriverError> {
    let Credentials::Password { username, password } = credentials else {
        return Err(ConfigError::AuthModeUnsupported.into());
    };
    let (username, password) = (username.trim(), password.expose_secret());
    Ok(match (username.is_empty(), password.is_empty()) {
        (true, true) => RedisConnectionInfo::default(),
        (true, false) => RedisConnectionInfo::default().set_password(password),
        (false, _) => RedisConnectionInfo::default()
            .set_username(username)
            .set_password(password),
    })
}

/// Name the link in the server's client list and read its id. A login
/// with no password on a server that wants one is refused here, since
/// redis-rs sends no AUTH without a password; one whose ACL denies
/// `CLIENT` keeps no id, and its stop can only close the link.
async fn identify(link: &Link) -> Result<Option<u64>, DriverError> {
    let mut pipeline = redis::pipe();
    pipeline.cmd("CLIENT").arg("SETNAME").arg(APPLICATION_NAME);
    pipeline.cmd("CLIENT").arg("ID");
    let replies = link.send_all(&pipeline).await?;
    for reply in &replies {
        if let Value::ServerError(error) = reply
            && error.code() == "NOAUTH"
        {
            return Err(server_error(error));
        }
    }
    Ok(match replies.get(1) {
        Some(Value::Int(id)) => u64::try_from(*id).ok(),
        _ => None,
    })
}

fn handshake_error(error: &io::Error) -> DriverError {
    match tablepro_net::tls::classify(error) {
        Some((failure, detail)) => DriverError::Tls { failure, detail },
        // The server closed the stream instead of answering the hello.
        None if matches!(
            error.kind(),
            io::ErrorKind::UnexpectedEof | io::ErrorKind::ConnectionReset | io::ErrorKind::BrokenPipe
        ) =>
        {
            DriverError::Tls {
                failure: TlsFailure::ServerRefusedTls,
                detail: error.to_string(),
            }
        }
        None => DriverError::ConnectionLost {
            during: LossPhase::Connect,
        },
    }
}

fn setup_error(error: TlsSetupError) -> DriverError {
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

#[cfg(test)]
mod tests {
    use super::*;

    fn password(username: &str, password: &str) -> Credentials {
        Credentials::Password {
            username: username.to_owned(),
            password: secrecy::SecretString::from(password.to_owned()),
        }
    }

    #[test]
    fn a_named_user_always_sends_a_password() {
        let nopass = login(&password("reader", "")).unwrap();
        let default = login(&password(" ", "s3cret")).unwrap();
        let anonymous = login(&password("", "")).unwrap();

        assert_eq!((nopass.username(), nopass.password()), (Some("reader"), Some("")));
        assert_eq!((default.username(), default.password()), (None, Some("s3cret")));
        assert_eq!((anonymous.username(), anonymous.password()), (None, None));
        assert!(login(&Credentials::Integrated).is_err());
    }

    #[test]
    fn a_server_that_hangs_up_on_the_hello_refused_tls() {
        let error = handshake_error(&io::Error::new(io::ErrorKind::UnexpectedEof, "eof"));

        assert!(
            matches!(
                error,
                DriverError::Tls {
                    failure: TlsFailure::ServerRefusedTls,
                    ..
                }
            ),
            "{error:?}"
        );
    }
}
