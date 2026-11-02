use std::sync::Arc;
use std::time::Duration;

use tablepro_core::{
    ConnectEnvironment, DriverError, LivenessPolicy, NetworkTarget, ServerInfo, TimeoutPhase, TlsMode, Transport,
};
use uuid::Uuid;

use crate::client_factory::{base_client, read_level, read_only_settings};
use crate::errors::{ErrorContext, map_error_in};
use crate::result_reader::drain;

/// How long the server keeps an editor session's state between runs.
const SESSION_TIMEOUT: Duration = Duration::from_secs(3600);

/// Everything needed to reach one server: the workspace's client, the
/// sessionless control client that KILLs and resolves, and the
/// transport behind both.
pub(crate) struct ClickHouseEndpoint {
    workspace: clickhouse::Client,
    control: clickhouse::Client,
    transport: Arc<dyn Transport>,
    liveness: LivenessPolicy,
    tls_requested: bool,
    session_timeout: Duration,
    read_only: bool,
    // The login's own `readonly` level, learned on connect.
    login_readonly: u8,
}

impl ClickHouseEndpoint {
    pub(crate) fn new(
        target: &NetworkTarget,
        liveness: LivenessPolicy,
        environment: &ConnectEnvironment,
        read_only: bool,
    ) -> Result<Self, DriverError> {
        let control = base_client(target, &liveness, environment)?;
        let mut endpoint = Self {
            workspace: control.clone(),
            control,
            transport: target.transport.clone(),
            liveness,
            tls_requested: target.tls.mode != TlsMode::Disable,
            session_timeout: SESSION_TIMEOUT,
            read_only,
            login_readonly: 0,
        };
        endpoint.hold(0);
        Ok(endpoint)
    }

    // A login at a `readonly` level of its own refuses any request that changes it, so the workspace waits for
    // the level before it asks for one.
    fn hold(&mut self, login_readonly: u8) {
        self.login_readonly = login_readonly;
        let mut workspace = self.control.clone();
        if self.read_only {
            for (name, value) in read_only_settings(login_readonly) {
                workspace = workspace.with_setting(name, value);
            }
        }
        self.workspace = workspace;
    }

    pub(crate) fn read_level(&self, user_sql: bool) -> Option<&'static str> {
        read_level(self.read_only, user_sql, self.login_readonly)
    }

    #[cfg(test)]
    pub(crate) fn for_fixture(fixture: &tablepro_test_fixtures::ClickHouseFixture, liveness: LivenessPolicy) -> Self {
        use secrecy::SecretString;
        use tablepro_core::{Credentials, NetworkEndpoint, TlsConfig};
        use tablepro_net::DirectTcpTransport;

        let address = NetworkEndpoint::new(fixture.host(), fixture.http_port()).expect("an endpoint");
        let credentials = fixture.password_credentials();
        let target = NetworkTarget {
            transport: Arc::new(DirectTcpTransport::new(address, &liveness)),
            credentials: Credentials::Password {
                username: credentials.username.clone(),
                password: SecretString::from(credentials.password.clone()),
            },
            database: Some("tablepro".to_owned()),
            tls: TlsConfig::disabled(),
            options: Default::default(),
        };
        Self::new(&target, liveness, &ConnectEnvironment::new("test"), false).expect("an endpoint")
    }

    #[cfg(test)]
    pub(crate) fn with_session_timeout(mut self, timeout: Duration) -> Self {
        self.session_timeout = timeout;
        self
    }

    /// The client of the workspace's own requests, read-only when the
    /// connection is.
    pub(crate) fn workspace(&self) -> &clickhouse::Client {
        &self.workspace
    }

    /// Not held read-only, because a KILL and a SYSTEM FLUSH LOGS are not
    /// reads, and it runs only SQL the driver itself wrote.
    pub(crate) fn control(&self) -> &clickhouse::Client {
        &self.control
    }

    pub(crate) fn liveness(&self) -> &LivenessPolicy {
        &self.liveness
    }

    /// The client that creates one editor session: the server keeps a
    /// session's settings and temporary tables under its id, for as long
    /// as the request that created it asked.
    pub(crate) fn session(&self, id: Uuid) -> clickhouse::Client {
        self.workspace
            .clone()
            .with_setting("session_id", id.to_string())
            .with_setting("session_timeout", self.session_timeout.as_secs().max(1).to_string())
    }

    /// What the server says it is, and the database unqualified names
    /// resolve to, asked as the login: the first request is where a
    /// refused password or a failed handshake shows up.
    pub(crate) async fn identify(&mut self) -> Result<(ServerInfo, String), DriverError> {
        let bound = self.liveness.connect_timeout + self.liveness.login_timeout;
        let asking = self
            .control
            .query_raw(
                "SELECT version() AS version, currentDatabase() AS database, \
                 toUInt8(getSetting('readonly')) AS readonly",
            )
            .fetch_one::<Identity>();
        let identity = match tokio::time::timeout(bound, asking).await {
            Err(_) => {
                return Err(DriverError::Timeout {
                    phase: TimeoutPhase::Login,
                    server_cancelled: false,
                });
            }
            Ok(Err(error)) => {
                let context = ErrorContext::Login {
                    tls_requested: self.tls_requested,
                };
                return Err(self.explain(map_error_in(&error, context)).await);
            }
            Ok(Ok(identity)) => identity,
        };
        self.hold(identity.readonly);
        let (major, minor, patch) = version_numbers(&identity.version);
        Ok((
            ServerInfo::new("ClickHouse", identity.version, major, minor, patch),
            identity.database,
        ))
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

    /// A fresh request of its own, asked one trivial question within
    /// `bound`.
    pub(crate) async fn check(&self, bound: Duration) -> Result<(), DriverError> {
        let checking = drain(self.control.query_raw("SELECT 1"));
        match tokio::time::timeout(bound, checking).await {
            Ok(outcome) => outcome.map(|_| ()),
            Err(_) => Err(DriverError::Timeout {
                phase: TimeoutPhase::Probe,
                server_cancelled: false,
            }),
        }
    }
}

#[derive(Debug, serde::Deserialize, clickhouse::Row)]
struct Identity {
    version: String,
    database: String,
    readonly: u8,
}

/// `24.8.4.13` is major 24, minor 8.
fn version_numbers(version: &str) -> (u32, u32, u32) {
    let mut parts = version.split('.').map(|part| part.parse::<u32>().unwrap_or(0));
    let mut next = || parts.next().unwrap_or(0);
    (next(), next(), next())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_version_splits_into_major_minor_and_patch() {
        assert_eq!(version_numbers("24.8.4.13"), (24, 8, 4));
        assert_eq!(version_numbers("25.10.1.1"), (25, 10, 1));
        assert_eq!(version_numbers("not a version"), (0, 0, 0));
    }
}
