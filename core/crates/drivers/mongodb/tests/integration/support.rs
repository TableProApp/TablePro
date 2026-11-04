//! What the MongoDB integration modules share: targets over the fixture's
//! port, one-line runs, and a sink that keeps what it gets.

use std::sync::{Arc, Mutex, PoisonError};
use std::time::Duration;

use async_trait::async_trait;
use secrecy::SecretString;
use tablepro_core::{
    CallOptions, ConnectEnvironment, ConnectOptions, ConnectTarget, Connection, Credentials, DatabaseDriver,
    EditorSession, EditorSessionOptions, LivenessPolicy, NetworkEndpoint, NetworkOptions, NetworkTarget, ResultEvent,
    ResultSink, RunOptions, RunSummary, SinkFlow, TlsConfig, Transport, UserSql, Value, WorkspaceSettings,
};
use tablepro_driver_mongodb::MongoDriver;
use tablepro_net::DirectTcpTransport;
use tablepro_test_fixtures::{FixtureCredentials, MongoFixture};
use tablepro_test_support::conformance::test_liveness;
use tokio::time::Instant;
use tokio_util::sync::CancellationToken;

pub const CALL: Duration = Duration::from_secs(30);

/// The database the tests write in.
pub const DATABASE: &str = "tablepro";

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

/// The root user, who is defined in `admin`.
pub fn password(credentials: &FixtureCredentials) -> Credentials {
    Credentials::Password {
        username: credentials.username.clone(),
        password: SecretString::from(credentials.password.clone()),
    }
}

pub fn in_admin() -> NetworkOptions {
    NetworkOptions {
        auth_database: Some("admin".to_owned()),
        ..NetworkOptions::default()
    }
}

pub fn options_over(
    transport: Arc<dyn Transport>,
    credentials: Credentials,
    tls: TlsConfig,
    settings: WorkspaceSettings,
    liveness: LivenessPolicy,
) -> ConnectOptions {
    ConnectOptions {
        target: ConnectTarget::Network(NetworkTarget {
            transport,
            credentials,
            database: Some(DATABASE.to_owned()),
            tls,
            options: in_admin(),
        }),
        workspace_settings: settings,
        liveness,
        environment: ConnectEnvironment::new("test"),
    }
}

pub fn fixture_options(fixture: &MongoFixture, settings: WorkspaceSettings) -> ConnectOptions {
    let liveness = test_liveness();
    options_over(
        direct(fixture.host(), fixture.port(), &liveness),
        password(&fixture.password_credentials()),
        TlsConfig::disabled(),
        settings,
        liveness,
    )
}

pub async fn start() -> MongoFixture {
    MongoFixture::start().await.expect("a MongoDB container")
}

pub async fn connect(fixture: &MongoFixture) -> Arc<dyn Connection> {
    MongoDriver
        .connect(
            fixture_options(fixture, WorkspaceSettings::workspace(false)),
            CancellationToken::new(),
        )
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

/// The names of the columns of the run's last result set.
pub fn column_names(events: &[ResultEvent]) -> Vec<String> {
    let mut names = Vec::new();
    for event in events {
        match event {
            ResultEvent::ResultSetStarted { columns } | ResultEvent::ColumnsResolved { columns, .. } => {
                names = columns.iter().map(|column| column.name.clone()).collect();
            }
            _ => {}
        }
    }
    names
}

struct Keep(Arc<Mutex<Vec<ResultEvent>>>);

#[async_trait]
impl ResultSink for Keep {
    async fn accept(&mut self, event: ResultEvent) -> SinkFlow {
        self.0.lock().unwrap_or_else(PoisonError::into_inner).push(event);
        SinkFlow::Continue
    }
}
