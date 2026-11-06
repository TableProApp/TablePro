use std::sync::Arc;
use std::time::Duration;

use tablepro_core::{
    ConnectEnvironment, DriverError, LivenessPolicy, NetworkTarget, ServerInfo, TimeoutPhase, TlsFailure, TlsMode,
    Transport,
};
use uuid::Uuid;

use crate::client_factory::{base_client, read_level, read_only_settings};
use crate::errors::{ErrorContext, map_error_in, missing_at_login};
use crate::result_reader::drain;

/// How long the server keeps an editor session's state between runs.
const SESSION_TIMEOUT: Duration = Duration::from_secs(3600);

// The level goes out as text, which every JSON output setting writes as a string; a login at a readonly level of
// its own cannot change those settings for this query.
const IDENTITY_SQL: &str = "SELECT version(), currentDatabase(), toString(toUInt8(getSetting('readonly')))";

/// The login's answer is two short strings and a byte. A longer body is
/// not a ClickHouse server's, and is never held in memory whole.
const IDENTITY_LIMIT: usize = 64 << 10;

/// Everything needed to reach one server: the workspace's client, the
/// sessionless control client that KILLs and resolves, and the
/// transport behind both.
pub(crate) struct ClickHouseEndpoint {
    workspace: clickhouse::Client,
    control: clickhouse::Client,
    transport: Arc<dyn Transport>,
    liveness: LivenessPolicy,
    tls_requested: bool,
    tls_server_name: String,
    session_timeout: Duration,
    read_only: bool,
    // The login's own `readonly` level, learned on connect.
    login_readonly: u8,
    /// The database every request names, as the client was built with it.
    database: Option<String>,
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
            tls_server_name: target.tls_server_name().to_owned(),
            session_timeout: SESSION_TIMEOUT,
            read_only,
            login_readonly: 0,
            database: target.database.clone().filter(|name| !name.is_empty()),
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
        let asking = read_identity(&self.control);
        let body = match tokio::time::timeout(bound, asking).await {
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
                let mapped = missing_at_login(map_error_in(&error, context), self.database.as_deref());
                let failed = self.explain(mapped).await;
                return Err(self.refused_in_the_clear(failed).await);
            }
            Ok(Ok(body)) => body,
        };
        let (version, database, readonly) = identity_of(body)?;
        self.hold(readonly);
        let (major, minor, patch) = version_numbers(&version);
        Ok((ServerInfo::new("ClickHouse", version, major, minor, patch), database))
    }

    // A server that takes only TLS drops a login in the clear unanswered, which a handshake of its own tells apart.
    async fn refused_in_the_clear(&self, failed: DriverError) -> DriverError {
        if self.tls_requested || !matches!(failed, DriverError::ConnectionLost { .. }) {
            return failed;
        }
        let within = self.liveness.login_timeout;
        if !tablepro_net::tls::serves_tls(self.transport.as_ref(), &self.tls_server_name, within).await {
            return failed;
        }
        DriverError::Tls {
            failure: TlsFailure::ServerRequiresTls,
            detail: failed.to_string(),
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

/// The login answer's body, or None once it runs past `IDENTITY_LIMIT`.
/// A RowBinary read would buffer a string of whatever length the server
/// declares before it could refuse it.
async fn read_identity(control: &clickhouse::Client) -> Result<Option<Vec<u8>>, clickhouse::error::Error> {
    let mut cursor = control.query_raw(IDENTITY_SQL).fetch_bytes("JSONCompactEachRow")?;
    let mut body = Vec::new();
    while let Some(chunk) = cursor.next().await? {
        if body.len() + chunk.len() > IDENTITY_LIMIT {
            return Ok(None);
        }
        body.extend_from_slice(&chunk);
    }
    Ok(Some(body))
}

/// The version, the current database and the login's `readonly` level.
fn identity_of(body: Option<Vec<u8>>) -> Result<(String, String, u8), DriverError> {
    let body = body.ok_or_else(|| {
        DriverError::Protocol(format!(
            "the server's answer to the login ran past {} KiB",
            IDENTITY_LIMIT >> 10
        ))
    })?;
    let unreadable =
        |detail: String| DriverError::Protocol(format!("the server's answer to the login could not be read: {detail}"));
    let (version, database, readonly): (String, String, String) =
        serde_json::from_slice(&body).map_err(|error| unreadable(error.to_string()))?;
    let readonly = readonly
        .parse()
        .map_err(|_| unreadable(format!("readonly level {readonly:?}")))?;
    Ok((version, database, readonly))
}

/// `24.8.4.13` is major 24, minor 8.
fn version_numbers(version: &str) -> (u32, u32, u32) {
    let mut parts = version.split('.').map(|part| part.parse::<u32>().unwrap_or(0));
    let mut next = || parts.next().unwrap_or(0);
    (next(), next(), next())
}

#[cfg(test)]
mod tests {
    use secrecy::SecretString;
    use tablepro_core::{Credentials, NetworkEndpoint, TlsConfig};
    use tablepro_net::DirectTcpTransport;
    use tokio::io::{AsyncReadExt, AsyncWriteExt};
    use tokio::net::TcpListener;

    use super::*;

    /// Answers every request with HTTP 200 and `body`, and keeps the socket
    /// open, so the client reads the body to its stated length.
    async fn answer_every_request(listener: TcpListener, body: Vec<u8>) {
        let mut held = Vec::new();
        while let Ok((mut socket, _)) = listener.accept().await {
            let mut request = Vec::new();
            let mut chunk = [0; 4096];
            while !request.windows(4).any(|end| end == b"\r\n\r\n") {
                match socket.read(&mut chunk).await {
                    Ok(0) | Err(_) => break,
                    Ok(read) => request.extend_from_slice(&chunk[..read]),
                }
            }
            let head = format!("HTTP/1.1 200 OK\r\nContent-Length: {}\r\n\r\n", body.len());
            if socket.write_all(head.as_bytes()).await.is_ok() && socket.write_all(&body).await.is_ok() {
                held.push(socket);
            }
        }
    }

    /// The login against a loopback server whose every answer is `body`,
    /// run where a runtime worker would run it, on a 2 MiB stack.
    fn identify_against(body: Vec<u8>) -> Result<(ServerInfo, String, u8), DriverError> {
        let worker = std::thread::Builder::new().stack_size(2 << 20);
        let handle = worker
            .spawn(move || {
                let runtime = tokio::runtime::Builder::new_current_thread()
                    .enable_all()
                    .build()
                    .expect("a runtime");
                runtime.block_on(async move {
                    let listener = TcpListener::bind("127.0.0.1:0").await.expect("a listener");
                    let port = listener.local_addr().expect("an address").port();
                    let answering = tokio::spawn(answer_every_request(listener, body));
                    let liveness = LivenessPolicy::DESKTOP;
                    let address = NetworkEndpoint::new("127.0.0.1", port).expect("an endpoint");
                    let target = NetworkTarget {
                        transport: Arc::new(DirectTcpTransport::new(address, &liveness)),
                        credentials: Credentials::Password {
                            username: "default".to_owned(),
                            password: SecretString::from(String::new()),
                        },
                        database: None,
                        tls: TlsConfig::disabled(),
                        options: Default::default(),
                    };
                    let mut endpoint =
                        ClickHouseEndpoint::new(&target, liveness, &ConnectEnvironment::new("test"), false)
                            .expect("an endpoint");
                    let identity = endpoint
                        .identify()
                        .await
                        .map(|(info, database)| (info, database, endpoint.login_readonly));
                    answering.abort();
                    identity
                })
            })
            .expect("a worker");
        handle.join().expect("the login ran to an outcome")
    }

    /// RowBinaryWithNamesAndTypes header: the column count, the names,
    /// then the types, each string after its LEB128 length.
    fn header(name: &str, type_name: &str) -> Vec<u8> {
        let mut body = vec![1];
        for text in [name, type_name] {
            let mut length = text.len();
            while length >= 0x80 {
                body.push((length & 0x7f) as u8 | 0x80);
                length >>= 7;
            }
            body.push(length as u8);
            body.extend_from_slice(text.as_bytes());
        }
        body
    }

    #[test]
    fn a_version_splits_into_major_minor_and_patch() {
        assert_eq!(version_numbers("24.8.4.13"), (24, 8, 4));
        assert_eq!(version_numbers("25.10.1.1"), (25, 10, 1));
        assert_eq!(version_numbers("not a version"), (0, 0, 0));
    }

    #[test]
    fn a_login_answer_naming_a_type_nested_100000_deep_fails_the_login() {
        let nested = format!("{}UInt8{}", "Array(".repeat(100_000), ")".repeat(100_000));

        let outcome = identify_against(header("version", &nested));

        assert!(outcome.is_err(), "{outcome:?}");
    }

    #[test]
    fn a_login_answer_reads_as_the_version_the_database_and_the_readonly_level() {
        let (info, database, readonly) =
            identify_against(b"[\"24.8.4.13\",\"tablepro\",\"2\"]\n".to_vec()).expect("a login");

        assert_eq!((info.major, info.minor, info.patch), (24, 8, 4));
        assert_eq!(database, "tablepro");
        assert_eq!(readonly, 2);
    }

    #[test]
    fn a_login_answer_past_64_kib_fails_the_login() {
        let body = format!("[\"{}\",\"default\",0]\n", "9".repeat(1 << 20));

        let outcome = identify_against(body.into_bytes());

        assert!(
            matches!(&outcome, Err(DriverError::Protocol(message)) if message.contains("64 KiB")),
            "{:?}",
            outcome.map(|(info, _, _)| info.version.len())
        );
    }

    #[test]
    fn a_login_answer_counting_2_to_the_62_columns_fails_the_login() {
        let mut body = vec![0x80; 8];
        body.push(0x40);
        body.extend_from_slice(b"\x07version");

        let outcome = identify_against(body);

        assert!(outcome.is_err(), "{outcome:?}");
    }
}
