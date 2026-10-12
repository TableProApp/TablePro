use std::sync::Arc;
use std::sync::atomic::Ordering;
use std::time::Duration;

use secrecy::ExposeSecret;
use tablepro_core::{
    APPLICATION_NAME, ConfigError, Credentials, DriverError, LivenessPolicy, NetworkTarget, ServerInfo, TimeoutPhase,
    Transport,
};
use tokio_postgres::config::ChannelBinding;
use tokio_postgres::{CancelToken, Client, Config, SimpleQueryMessage};
use tokio_util::sync::CancellationToken;
use tokio_util::task::TaskTracker;

use crate::errors::{map_connect_error, map_error, transport_error};
use crate::tls::{PgTlsSetup, PgTlsStream};
use crate::transport_io::TransportIo;

/// The half of a physical connection that does the I/O. Whoever owns it
/// must poll it, or nothing the client sends ever reaches the server.
pub(crate) type PgRawConnection = tokio_postgres::Connection<TransportIo, PgTlsStream>;

/// Everything needed to open a physical connection to one server, and
/// to reach it again with a cancel request.
///
/// Every stream comes from the transport, so the driver never learns
/// whether the server is reached directly or through an SSH forward.
pub(crate) struct PgEndpoint {
    transport: Arc<dyn Transport>,
    config: Config,
    tls: PgTlsSetup,
    liveness: LivenessPolicy,
}

impl PgEndpoint {
    pub(crate) fn new(target: &NetworkTarget, liveness: LivenessPolicy) -> Result<Self, DriverError> {
        let Credentials::Password { username, password } = &target.credentials else {
            return Err(DriverError::Config(ConfigError::AuthModeUnsupported));
        };
        let tls = PgTlsSetup::new(&target.tls, target.tls_server_name())?;
        let mut config = Config::new();
        config
            .user(username)
            .password(password.expose_secret())
            .application_name(APPLICATION_NAME)
            .channel_binding(ChannelBinding::Prefer)
            .ssl_mode(tls.ssl_mode());
        if let Some(database) = target.database.as_deref().filter(|name| !name.is_empty()) {
            config.dbname(database);
        }
        Ok(Self {
            transport: target.transport.clone(),
            config,
            tls,
            liveness,
        })
    }

    pub(crate) fn liveness(&self) -> &LivenessPolicy {
        &self.liveness
    }

    /// Open a physical connection: a stream from the transport, then the
    /// startup and login under the login timeout. `cancel` abandons
    /// either step.
    pub(crate) async fn open(&self, cancel: &CancellationToken) -> Result<(Client, PgRawConnection), DriverError> {
        let opening = async {
            let stream = self.transport.open().await.map_err(transport_error)?;
            self.login(TransportIo::new(stream)).await
        };
        tokio::select! {
            () = cancel.cancelled() => Err(DriverError::Cancelled),
            opened = opening => opened,
        }
    }

    async fn login(&self, stream: TransportIo) -> Result<(Client, PgRawConnection), DriverError> {
        let (connector, handshake_started) = self.tls.connector();
        let login = self.config.connect_raw(stream, connector);
        match tokio::time::timeout(self.liveness.login_timeout, login).await {
            Err(_) => Err(DriverError::Timeout {
                phase: TimeoutPhase::Login,
                server_cancelled: false,
            }),
            Ok(Ok(connected)) => Ok(connected),
            Ok(Err(error)) => {
                let started = handshake_started.load(Ordering::SeqCst);
                let mapped = map_connect_error(&error, self.tls.requested(), started);
                Err(self.explain(mapped).await)
            }
        }
    }

    /// Ask the server to stop whatever the connection behind `token` is
    /// running. The request goes over a stream of its own, because the
    /// connection it names is busy.
    pub(crate) async fn cancel_request(&self, token: &CancelToken) -> Result<(), DriverError> {
        let stream = TransportIo::new(self.transport.open().await.map_err(transport_error)?);
        let (connector, _) = self.tls.connector();
        token
            .cancel_query_raw(stream, connector)
            .await
            .map_err(|error| map_error(&error))
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

    /// Open a connection of its own and ask it one trivial question,
    /// within `bound`. This is the probe that never waits for a pool.
    pub(crate) async fn check(&self, bound: Duration, tracker: &TaskTracker) -> Result<(), DriverError> {
        let checking = async {
            let (client, connection) = self.open(&CancellationToken::new()).await?;
            let driving = tracker.spawn(async move {
                let _ = connection.await;
            });
            let answered = client.simple_query("SELECT 1").await.map_err(|error| map_error(&error));
            drop(client);
            driving.abort();
            answered.map(|_| ())
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

/// What the server says it is, read once at connect.
pub(crate) async fn server_info(client: &Client) -> Result<ServerInfo, DriverError> {
    let messages = client
        .simple_query("SELECT current_setting('server_version_num'), current_setting('server_version')")
        .await
        .map_err(|error| map_error(&error))?;
    let row = messages.iter().find_map(|message| match message {
        SimpleQueryMessage::Row(row) => Some(row),
        _ => None,
    });
    let number = row.and_then(|row| row.get(0)).and_then(|text| text.parse::<u32>().ok());
    let version = row.and_then(|row| row.get(1)).unwrap_or_default().to_owned();
    let Some(number) = number else {
        return Err(DriverError::Protocol(
            "the server did not report server_version_num".to_owned(),
        ));
    };
    let (major, minor) = split_version_number(number);
    Ok(ServerInfo::new("PostgreSQL", version, major, minor, 0))
}

/// `server_version_num` is major * 10000 + minor from PostgreSQL 10 on,
/// which is two numbers: there is no patch to read.
fn split_version_number(number: u32) -> (u32, u32) {
    (number / 10_000, number % 10_000)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn version_numbers_split_into_major_and_minor() {
        assert_eq!(split_version_number(130_016), (13, 16));
        assert_eq!(split_version_number(180_000), (18, 0));
    }
}
