//! What the Redis integration modules share: targets over the fixture's
//! port, one-line calls, and a sink that keeps what it gets.

use std::sync::{Arc, Mutex, PoisonError};
use std::time::Duration;

use async_trait::async_trait;
use secrecy::SecretString;
use tablepro_core::{
    CallOptions, ConnectEnvironment, ConnectOptions, ConnectTarget, Connection, Credentials, DatabaseDriver,
    EditorSession, EditorSessionOptions, LivenessPolicy, NetworkEndpoint, NetworkTarget, ResultEvent, ResultSink,
    RunOptions, RunSummary, SinkFlow, TlsConfig, Transport, UserSql, Value, WorkspaceSettings,
};
use tablepro_driver_redis::RedisDriver;
use tablepro_net::DirectTcpTransport;
use tablepro_test_fixtures::{FixtureCredentials, RedisFixture};
use tablepro_test_support::conformance::test_liveness;
use tokio::time::Instant;
use tokio_util::sync::CancellationToken;

pub const CALL: Duration = Duration::from_secs(30);

pub fn within(limit: Duration) -> CallOptions {
    CallOptions::new(Some(Instant::now() + limit), CancellationToken::new())
}

/// A name no other test uses, so tests sharing a server never meet.
pub fn unique(prefix: &str) -> String {
    let suffix = uuid::Uuid::new_v4().simple().to_string();
    format!("tp_{prefix}_{}", &suffix[..12])
}

pub fn direct(host: &str, port: u16, liveness: &LivenessPolicy) -> Arc<dyn Transport> {
    let endpoint = NetworkEndpoint::new(host, port).expect("a valid endpoint");
    Arc::new(DirectTcpTransport::new(endpoint, liveness))
}

pub fn password(credentials: &FixtureCredentials) -> Credentials {
    Credentials::Password {
        username: credentials.username.clone(),
        password: SecretString::from(credentials.password.clone()),
    }
}

pub fn options_over(
    transport: Arc<dyn Transport>,
    credentials: Credentials,
    database: Option<&str>,
    tls: TlsConfig,
    settings: WorkspaceSettings,
    liveness: LivenessPolicy,
) -> ConnectOptions {
    ConnectOptions {
        target: ConnectTarget::Network(NetworkTarget {
            transport,
            credentials,
            database: database.map(str::to_owned),
            tls,
        }),
        workspace_settings: settings,
        liveness,
        environment: ConnectEnvironment::new("test"),
    }
}

pub fn fixture_options(fixture: &RedisFixture, credentials: Credentials, database: Option<&str>) -> ConnectOptions {
    let liveness = test_liveness();
    options_over(
        direct(fixture.host(), fixture.port(), &liveness),
        credentials,
        database,
        TlsConfig::disabled(),
        WorkspaceSettings::workspace(false),
        liveness,
    )
}

pub async fn start() -> RedisFixture {
    RedisFixture::start().await.expect("a Redis container")
}

pub async fn connect(fixture: &RedisFixture) -> Arc<dyn Connection> {
    let options = fixture_options(fixture, password(&fixture.password_credentials()), None);
    RedisDriver
        .connect(options, CancellationToken::new())
        .await
        .expect("a connection")
}

pub async fn editor(connection: &dyn Connection) -> Arc<dyn EditorSession> {
    connection
        .open_editor_session(EditorSessionOptions::default(), CancellationToken::new())
        .await
        .expect("an editor session")
}

/// Run `text` in the editor session and keep what it sent.
pub async fn run(session: &dyn EditorSession, text: &str) -> (RunSummary, Vec<ResultEvent>) {
    let kept = Arc::new(Mutex::new(Vec::new()));
    let summary = session
        .run(
            UserSql::new(text),
            RunOptions::new(CancellationToken::new()),
            Box::new(Keep(kept.clone())),
        )
        .await
        .expect("the session ran the text");
    let events = std::mem::take(&mut *kept.lock().unwrap_or_else(PoisonError::into_inner));
    (summary, events)
}

/// Every row the events carried.
pub fn rows(events: &[ResultEvent]) -> Vec<Vec<Value>> {
    events
        .iter()
        .filter_map(|event| match event {
            ResultEvent::Rows(rows) => Some(rows.clone()),
            _ => None,
        })
        .flatten()
        .collect()
}

struct Keep(Arc<Mutex<Vec<ResultEvent>>>);

#[async_trait]
impl ResultSink for Keep {
    async fn accept(&mut self, event: ResultEvent) -> SinkFlow {
        self.0.lock().unwrap_or_else(PoisonError::into_inner).push(event);
        SinkFlow::Continue
    }
}
