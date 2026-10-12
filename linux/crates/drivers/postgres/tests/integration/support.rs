//! What the PostgreSQL integration modules share: targets over the
//! fixture's port, one-line calls, and a sink that keeps what it gets.

use std::sync::{Arc, Mutex, PoisonError};
use std::time::Duration;

use async_trait::async_trait;
use drivers_postgres::PgDriver;
use secrecy::SecretString;
use tablepro_core::statement::{GuardedStatement, Statement, StatementBuilder};
use tablepro_core::{
    CallOptions, ConnectEnvironment, ConnectOptions, ConnectTarget, Connection, Credentials, DatabaseDriver,
    EditorSession, EditorSessionOptions, ForeignKeyMode, LivenessPolicy, NetworkEndpoint, NetworkTarget, ResultEvent,
    ResultSink, RunEnd, RunOptions, RunSummary, SinkFlow, TableRef, TlsConfig, Transport, UserSql, Value,
    WorkspaceSettings, WriteBatch, WriteKind, WriteReport,
};
use tablepro_net::DirectTcpTransport;
use tablepro_test_fixtures::{FixtureCredentials, PostgresFixture};
use tablepro_test_support::conformance::test_liveness;
use tokio::time::Instant;
use tokio_util::sync::CancellationToken;

pub const CALL: Duration = Duration::from_secs(30);

pub fn within(limit: Duration) -> CallOptions {
    CallOptions::new(Some(Instant::now() + limit), CancellationToken::new())
}

pub fn statement(sql: &str) -> Statement {
    let mut builder = StatementBuilder::new();
    builder.push_sql(sql);
    builder.finish()
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
    database: &str,
    tls: TlsConfig,
    settings: WorkspaceSettings,
    liveness: LivenessPolicy,
) -> ConnectOptions {
    ConnectOptions {
        target: ConnectTarget::Network(NetworkTarget {
            transport,
            credentials,
            database: Some(database.to_owned()),
            tls,
        }),
        workspace_settings: settings,
        liveness,
        environment: ConnectEnvironment::new("test"),
    }
}

pub fn fixture_options(fixture: &PostgresFixture, settings: WorkspaceSettings) -> ConnectOptions {
    let liveness = test_liveness();
    options_over(
        direct(fixture.host(), fixture.port(), &liveness),
        password(&fixture.password_credentials()),
        fixture.database(),
        TlsConfig::disabled(),
        settings,
        liveness,
    )
}

pub async fn connect_with(options: ConnectOptions) -> Arc<dyn Connection> {
    PgDriver
        .connect(options, CancellationToken::new())
        .await
        .expect("a connection")
}

pub async fn connect(fixture: &PostgresFixture, read_only: bool) -> Arc<dyn Connection> {
    connect_with(fixture_options(fixture, WorkspaceSettings::workspace(read_only))).await
}

pub async fn start() -> PostgresFixture {
    PostgresFixture::start(tablepro_test_fixtures::HbaMode::Password)
        .await
        .expect("a PostgreSQL container")
}

/// Run statements as one schema-change batch, for setup.
pub async fn setup(connection: &dyn Connection, statements: &[&str]) {
    apply(connection, WriteKind::SchemaChanges, statements)
        .await
        .expect("the setup statements");
}

pub async fn apply(
    connection: &dyn Connection,
    kind: WriteKind,
    statements: &[&str],
) -> Result<WriteReport, tablepro_core::DriverError> {
    let mut batch = batch(statements);
    batch.kind = kind;
    connection.write_batch(&batch, within(CALL)).await
}

/// Row changes, each statement unguarded.
pub fn batch(statements: &[&str]) -> WriteBatch {
    let steps = statements
        .iter()
        .map(|sql| GuardedStatement::unguarded(statement(sql)))
        .collect();
    WriteBatch::new(
        WriteKind::RowChanges,
        TableRef::unqualified("t"),
        steps,
        ForeignKeyMode::Enforced,
    )
}

pub async fn rows(connection: &dyn Connection, sql: &str) -> Vec<Vec<Value>> {
    connection
        .query_bound(&statement(sql), tablepro_core::RowLimit::EDITOR_DEFAULT, within(CALL))
        .await
        .expect("a read")
        .rows
}

pub async fn scalar(connection: &dyn Connection, sql: &str) -> Value {
    rows(connection, sql)
        .await
        .into_iter()
        .next()
        .and_then(|row| row.into_iter().next())
        .expect("one value")
}

pub async fn session(connection: &dyn Connection) -> Arc<dyn EditorSession> {
    connection
        .open_editor_session(EditorSessionOptions::default(), CancellationToken::new())
        .await
        .expect("an editor session")
}

/// The events of one run, kept after the sink is gone.
#[derive(Debug, Clone, Default)]
pub struct Events(Arc<Mutex<Vec<ResultEvent>>>);

impl Events {
    pub fn all(&self) -> Vec<ResultEvent> {
        self.0.lock().unwrap_or_else(PoisonError::into_inner).clone()
    }

    pub fn rows(&self) -> Vec<Vec<Value>> {
        self.all()
            .into_iter()
            .filter_map(|event| match event {
                ResultEvent::Rows(rows) => Some(rows),
                _ => None,
            })
            .flatten()
            .collect()
    }

    pub fn finished(&self) -> Vec<ResultEvent> {
        self.all()
            .into_iter()
            .filter(|event| matches!(event, ResultEvent::ResultSetFinished { .. }))
            .collect()
    }
}

pub struct EventSink {
    events: Events,
    delay: Option<Duration>,
    gone_after_rows: Option<usize>,
    seen_rows: usize,
}

impl EventSink {
    pub fn new(events: &Events) -> Self {
        Self {
            events: events.clone(),
            delay: None,
            gone_after_rows: None,
            seen_rows: 0,
        }
    }

    pub fn slow(mut self, delay: Duration) -> Self {
        self.delay = Some(delay);
        self
    }

    pub fn gone_after(mut self, rows: usize) -> Self {
        self.gone_after_rows = Some(rows);
        self
    }
}

#[async_trait]
impl ResultSink for EventSink {
    async fn accept(&mut self, event: ResultEvent) -> SinkFlow {
        if let Some(delay) = self.delay {
            tokio::time::sleep(delay).await;
        }
        if let ResultEvent::Rows(rows) = &event {
            self.seen_rows += rows.len();
        }
        self.events.0.lock().unwrap_or_else(PoisonError::into_inner).push(event);
        match self.gone_after_rows {
            Some(limit) if self.seen_rows >= limit => SinkFlow::ConsumerGone,
            _ => SinkFlow::Continue,
        }
    }
}

pub async fn run_with(session: &dyn EditorSession, sql: &str, options: RunOptions) -> (RunSummary, Events) {
    let events = Events::default();
    let summary = session
        .run(UserSql::new(sql), options, Box::new(EventSink::new(&events)))
        .await
        .expect("the session ran the script");
    (summary, events)
}

pub async fn run(session: &dyn EditorSession, sql: &str) -> (RunSummary, Events) {
    run_with(session, sql, RunOptions::new(CancellationToken::new())).await
}

pub async fn run_ok(session: &dyn EditorSession, sql: &str) -> Events {
    let (summary, events) = run(session, sql).await;
    assert_eq!(summary.end, RunEnd::Completed, "`{sql}` did not complete");
    events
}

pub fn text(value: &Value) -> String {
    match value {
        Value::Text(text) => text.clone(),
        other => tablepro_core::export::value_to_text(other).unwrap_or_default(),
    }
}
