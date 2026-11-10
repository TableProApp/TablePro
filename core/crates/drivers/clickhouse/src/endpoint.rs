use std::sync::Arc;
use std::time::Duration;

use tablepro_core::{
    ConnectEnvironment, DriverError, LivenessPolicy, NetworkTarget, ServerInfo, TimeoutPhase, TlsFailure, TlsMode,
    Transport,
};
use uuid::Uuid;

use crate::call_client::whole_seconds;
use crate::client_factory::{
    ChangeableSettings, MAX_EXECUTION_TIME, MUTATIONS_SYNC, TIMEOUT_OVERFLOW_MODE, base_client, read_level,
    read_only_settings,
};
use crate::errors::{ErrorContext, map_error_in, missing_at_login};
use crate::result_reader::drain;

/// How long the server keeps an editor session's state between runs.
const SESSION_TIMEOUT: Duration = Duration::from_secs(3600);

// The login's answer is a few short strings. A longer body is not a ClickHouse server's, and is never held whole.
const IDENTITY_LIMIT: usize = 64 << 10;

/// Everything needed to reach one server: the workspace's client, the
/// sessionless control client that KILLs and resolves, and the
/// transport behind both.
pub(crate) struct ClickHouseEndpoint {
    // Carries no setting, so the login cannot refuse it for one.
    login: clickhouse::Client,
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
    changeable: ChangeableSettings,
    // Whether the server waits for a save's mutation, by the driver's `mutations_sync` or the login's own.
    waits_for_mutations: bool,
    /// The database every request names, as the client was built with it.
    database: Option<String>,
}

// What the login's first answer says.
struct Identity {
    version: String,
    database: String,
    readonly: u8,
    changeable: ChangeableSettings,
    mutations_sync: u64,
}

impl ClickHouseEndpoint {
    pub(crate) fn new(
        target: &NetworkTarget,
        liveness: LivenessPolicy,
        environment: &ConnectEnvironment,
        read_only: bool,
    ) -> Result<Self, DriverError> {
        let login = base_client(target, &liveness, environment)?;
        let mut endpoint = Self {
            workspace: login.clone(),
            control: login.clone(),
            login,
            transport: target.transport.clone(),
            liveness,
            tls_requested: target.tls.mode != TlsMode::Disable,
            tls_server_name: target.tls_server_name().to_owned(),
            session_timeout: SESSION_TIMEOUT,
            read_only,
            login_readonly: 0,
            changeable: ChangeableSettings::all(),
            waits_for_mutations: true,
            database: target.database.clone().filter(|name| !name.is_empty()),
        };
        endpoint.hold(0, ChangeableSettings::all(), 0);
        Ok(endpoint)
    }

    // A login refuses a whole request that changes a setting it may not, so the clients wait for its answer before
    // they ask for any.
    fn hold(&mut self, login_readonly: u8, changeable: ChangeableSettings, login_mutations_sync: u64) {
        let mut control = self.login.clone();
        for (name, value) in changeable.common() {
            control = control.with_setting(name, value);
        }
        let mut workspace = control.clone();
        if self.read_only {
            for (name, value) in read_only_settings(login_readonly) {
                workspace = workspace.with_setting(name, value);
            }
        }
        self.login_readonly = login_readonly;
        self.waits_for_mutations = changeable.allows(MUTATIONS_SYNC) || login_mutations_sync > 0;
        self.changeable = changeable;
        self.control = control;
        self.workspace = workspace;
    }

    pub(crate) fn read_level(&self, user_sql: bool) -> Option<&'static str> {
        read_level(self.read_only, user_sql, self.login_readonly)
    }

    pub(crate) fn bounds_reads(&self) -> bool {
        self.changeable.bounds_reads()
    }

    // Never a write, and ended by the server at `bound` where the login may set one; `None` leaves it unbounded.
    pub(crate) fn reading(&self, bound: Option<Duration>, user_sql: bool) -> clickhouse::Client {
        let mut client = self.workspace.clone();
        if self.bounds_reads() {
            client = client
                .with_setting(TIMEOUT_OVERFLOW_MODE, "throw")
                .with_setting(MAX_EXECUTION_TIME, whole_seconds(bound).to_string());
        }
        match self.read_level(user_sql) {
            Some(level) => client.with_setting("readonly", level),
            None => client,
        }
    }

    // Each statement of a save runs to its end: a mutation the server stops waiting for keeps running anyway.
    pub(crate) fn writing(&self, mutates: bool) -> clickhouse::Client {
        let mut writes = self.workspace.clone().with_setting("wait_end_of_query", "1");
        if self.changeable.allows(MAX_EXECUTION_TIME) {
            writes = writes.with_setting(MAX_EXECUTION_TIME, "0");
        }
        // A server that does not wait answers a mutation once it is queued, so a save would read as done while its
        // mutation may still fail. The setting this login may not change has the server refuse the save before any of
        // it runs.
        if mutates && !self.waits_for_mutations {
            writes = writes.with_setting(MUTATIONS_SYNC, "1");
        }
        writes
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
    #[cfg(test)]
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
        let asking = read_identity(&self.login);
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
        let identity = identity_of(body)?;
        self.hold(identity.readonly, identity.changeable, identity.mutations_sync);
        let (major, minor, patch) = version_numbers(&identity.version);
        Ok((
            ServerInfo::new("ClickHouse", identity.version, major, minor, patch),
            identity.database,
        ))
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
async fn read_identity(login: &clickhouse::Client) -> Result<Option<Vec<u8>>, clickhouse::error::Error> {
    let mut cursor = login.query_raw(&identity_sql()).fetch_bytes("JSONCompactEachRow")?;
    let mut body = Vec::new();
    while let Some(chunk) = cursor.next().await? {
        if body.len() + chunk.len() > IDENTITY_LIMIT {
            return Ok(None);
        }
        body.extend_from_slice(&chunk);
    }
    Ok(Some(body))
}

// Each column is text or an array of it, which reads the same under whatever JSON output settings the login's
// profile holds, since this request sends none.
fn identity_sql() -> String {
    let asked: Vec<String> = ChangeableSettings::asked().map(|name| format!("'{name}'")).collect();
    format!(
        "SELECT version(), currentDatabase(), toString(toUInt8(getSetting('readonly'))), \
         (SELECT groupArray(name) FROM system.settings WHERE readonly = 0 AND name IN ({})), \
         toString(getSetting('{MUTATIONS_SYNC}'))",
        asked.join(", ")
    )
}

fn identity_of(body: Option<Vec<u8>>) -> Result<Identity, DriverError> {
    let body = body.ok_or_else(|| {
        DriverError::Protocol(format!(
            "the server's answer to the login ran past {} KiB",
            IDENTITY_LIMIT >> 10
        ))
    })?;
    let unreadable =
        |detail: String| DriverError::Protocol(format!("the server's answer to the login could not be read: {detail}"));
    let (version, database, readonly, changeable, mutations_sync): (String, String, String, Vec<String>, String) =
        serde_json::from_slice(&body).map_err(|error| unreadable(error.to_string()))?;
    let readonly = readonly
        .parse()
        .map_err(|_| unreadable(format!("readonly level {readonly:?}")))?;
    let mutations_sync = mutations_sync
        .parse()
        .map_err(|_| unreadable(format!("mutations_sync {mutations_sync:?}")))?;
    Ok(Identity {
        version,
        database,
        readonly,
        changeable: ChangeableSettings::listed(&changeable),
        mutations_sync,
    })
}

/// `24.8.4.13` is major 24, minor 8.
fn version_numbers(version: &str) -> (u32, u32, u32) {
    let mut parts = version.split('.').map(|part| part.parse::<u32>().unwrap_or(0));
    let mut next = || parts.next().unwrap_or(0);
    (next(), next(), next())
}

#[cfg(test)]
mod tests {
    use std::sync::{Mutex, PoisonError};

    use secrecy::SecretString;
    use tablepro_core::{Credentials, NetworkEndpoint, TlsConfig};
    use tablepro_net::DirectTcpTransport;
    use tokio::io::{AsyncReadExt, AsyncWriteExt};
    use tokio::net::TcpListener;

    use super::*;

    // Answers every request with HTTP 200 and `body` and keeps the socket open, so the client reads the body to its
    // stated length.
    async fn answer_every_request(listener: TcpListener, body: Vec<u8>, heads: Arc<Mutex<Vec<String>>>) {
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
            heads
                .lock()
                .unwrap_or_else(PoisonError::into_inner)
                .push(String::from_utf8_lossy(&request).into_owned());
            let head = format!("HTTP/1.1 200 OK\r\nContent-Length: {}\r\n\r\n", body.len());
            if socket.write_all(head.as_bytes()).await.is_ok() && socket.write_all(&body).await.is_ok() {
                held.push(socket);
            }
        }
    }

    struct Login {
        identity: Result<(ServerInfo, String), DriverError>,
        endpoint: ClickHouseEndpoint,
        heads: Vec<String>,
    }

    // Run where a runtime worker would run it, on a 2 MiB stack.
    fn log_in_against(body: Vec<u8>, read_only: bool) -> Login {
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
                    let heads = Arc::new(Mutex::new(Vec::new()));
                    let answering = tokio::spawn(answer_every_request(listener, body, heads.clone()));
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
                        ClickHouseEndpoint::new(&target, liveness, &ConnectEnvironment::new("test"), read_only)
                            .expect("an endpoint");
                    let identity = endpoint.identify().await;
                    answering.abort();
                    let heads = heads.lock().unwrap_or_else(PoisonError::into_inner).clone();
                    Login {
                        identity,
                        endpoint,
                        heads,
                    }
                })
            })
            .expect("a worker");
        handle.join().expect("the login ran to an outcome")
    }

    fn identify_against(body: Vec<u8>) -> Result<(ServerInfo, String, u8), DriverError> {
        let login = log_in_against(body, false);
        let readonly = login.endpoint.login_readonly;
        login.identity.map(|(info, database)| (info, database, readonly))
    }

    fn answer(readonly: &str, changeable: &[&str]) -> Vec<u8> {
        answer_with(readonly, changeable, "0")
    }

    fn answer_with(readonly: &str, changeable: &[&str], mutations_sync: &str) -> Vec<u8> {
        let names: Vec<String> = changeable.iter().map(|name| format!("\"{name}\"")).collect();
        let names = names.join(",");
        format!("[\"26.8.1.1\",\"tablepro\",\"{readonly}\",[{names}],\"{mutations_sync}\"]\n").into_bytes()
    }

    // The server takes each of these as a setting, apart from the few names it reserves.
    fn url_names(head: &str) -> Vec<String> {
        let target = head.split_whitespace().nth(1).unwrap_or_default();
        let query = target.split_once('?').map_or("", |(_, query)| query);
        query
            .split('&')
            .filter(|pair| !pair.is_empty())
            .map(|pair| pair.split('=').next().unwrap_or_default().to_owned())
            .collect()
    }

    fn settings_on(client: &clickhouse::Client) -> Vec<&'static str> {
        ChangeableSettings::asked()
            .chain(["readonly", "allow_ddl"])
            .filter(|name| client.get_setting(name).is_some())
            .collect()
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
            identify_against(b"[\"24.8.4.13\",\"tablepro\",\"2\",[],\"0\"]\n".to_vec()).expect("a login");

        assert_eq!((info.major, info.minor, info.patch), (24, 8, 4));
        assert_eq!(database, "tablepro");
        assert_eq!(readonly, 2);
    }

    #[test]
    fn the_login_request_sends_no_setting() {
        let login = log_in_against(answer("1", &[]), false);

        assert!(login.identity.is_ok(), "{:?}", login.identity.err());
        let sent: Vec<Vec<String>> = login.heads.iter().map(String::as_str).map(url_names).collect();
        assert_eq!(sent, vec![vec!["default_format".to_owned()]]);
    }

    #[test]
    fn a_login_at_readonly_1_that_may_change_nothing_is_sent_only_its_own_level() {
        let login = log_in_against(answer("1", &[]), true);
        let endpoint = login.endpoint;
        let user_read = endpoint.reading(Some(Duration::from_secs(5)), true);
        let app_read = endpoint.reading(Some(Duration::from_secs(5)), false);
        let writes = endpoint.writing(false);

        assert_eq!(endpoint.login_readonly, 1);
        assert!(!endpoint.bounds_reads());
        assert_eq!(settings_on(endpoint.control()), Vec::<&str>::new());
        for client in [endpoint.workspace(), &user_read, &app_read, &writes] {
            assert_eq!(settings_on(client), vec!["readonly"]);
            assert_eq!(client.get_setting("readonly"), Some("1"));
        }
    }

    #[test]
    fn a_save_with_a_mutation_the_server_will_not_wait_for_asks_for_the_wait_so_it_is_refused() {
        let pinned = log_in_against(answer_with("0", &[MAX_EXECUTION_TIME], "0"), false).endpoint;
        let waits_itself = log_in_against(answer_with("0", &[MAX_EXECUTION_TIME], "2"), false).endpoint;

        assert_eq!(pinned.writing(true).get_setting(MUTATIONS_SYNC), Some("1"));
        assert_eq!(pinned.writing(false).get_setting(MUTATIONS_SYNC), None);
        assert_eq!(waits_itself.writing(true).get_setting(MUTATIONS_SYNC), None);
    }

    #[test]
    fn a_login_is_sent_only_the_settings_it_may_change() {
        let changeable = [
            "output_format_json_quote_denormals",
            MAX_EXECUTION_TIME,
            TIMEOUT_OVERFLOW_MODE,
        ];
        let login = log_in_against(answer("1", &changeable), false);
        let endpoint = login.endpoint;
        let read = endpoint.reading(Some(Duration::from_millis(1_500)), false);

        assert_eq!(
            settings_on(endpoint.control()),
            vec!["output_format_json_quote_denormals"]
        );
        assert_eq!(read.get_setting(MAX_EXECUTION_TIME), Some("2"));
        assert_eq!(read.get_setting(TIMEOUT_OVERFLOW_MODE), Some("throw"));
        assert_eq!(endpoint.writing(false).get_setting(MAX_EXECUTION_TIME), Some("0"));
    }

    #[test]
    fn a_login_free_to_change_every_setting_gets_them_all() {
        let all: Vec<&str> = ChangeableSettings::asked().collect();
        let login = log_in_against(answer("0", &all), true);
        let endpoint = login.endpoint;

        assert!(endpoint.bounds_reads());
        assert_eq!(endpoint.control().get_setting("mutations_sync"), Some("1"));
        assert_eq!(endpoint.workspace().get_setting("readonly"), Some("1"));
        assert_eq!(endpoint.workspace().get_setting("allow_ddl"), Some("0"));
        assert_eq!(endpoint.reading(None, false).get_setting(MAX_EXECUTION_TIME), Some("0"));
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
