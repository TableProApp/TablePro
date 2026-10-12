//! What the MySQL integration modules share: fixtures for both servers,
//! targets over their ports, one-line calls, and a sink that keeps what
//! it gets.

use std::sync::{Arc, Mutex, PoisonError};
use std::time::Duration;

use async_trait::async_trait;
use drivers_mysql::MysqlDriver;
use secrecy::SecretString;
use tablepro_core::statement::{GuardedStatement, Statement, StatementBuilder};
use tablepro_core::{
    CallOptions, ConnectEnvironment, ConnectOptions, ConnectTarget, Connection, Credentials, DatabaseDriver,
    DriverError, EditorSession, EditorSessionOptions, ForeignKeyMode, LivenessPolicy, NetworkEndpoint, NetworkTarget,
    ResultEvent, ResultSink, RunEnd, RunOptions, RunSummary, SinkFlow, TableRef, TlsConfig, Transport, Truncation,
    UserSql, Value, WorkspaceSettings, WriteBatch, WriteKind, WriteReport,
};
use tablepro_net::DirectTcpTransport;
use tablepro_test_fixtures::{FixtureCredentials, MysqlFixture, MysqlFlavour, MysqlOptions};
use tablepro_test_support::conformance::test_liveness;
use tokio::time::Instant;
use tokio_util::sync::CancellationToken;

pub const CALL: Duration = Duration::from_secs(30);

pub const FLAVOURS: [MysqlFlavour; 2] = [MysqlFlavour::Mysql, MysqlFlavour::Mariadb];

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

/// A server that takes plaintext logins, which every test but the TLS
/// ones uses.
/// The password user may create triggers and routines, so a test
/// needs root only for what only root may do.
pub async fn start(flavour: MysqlFlavour) -> MysqlFixture {
    start_with(
        MysqlOptions::new(flavour)
            .allowing_plaintext()
            .trusting_function_creators(),
    )
    .await
}

pub async fn start_with(options: MysqlOptions) -> MysqlFixture {
    MysqlFixture::start_with(options, None)
        .await
        .expect("a MySQL container")
}

pub fn fixture_options(
    fixture: &MysqlFixture,
    credentials: &FixtureCredentials,
    settings: WorkspaceSettings,
) -> ConnectOptions {
    let liveness = test_liveness();
    options_over(
        direct(fixture.host(), fixture.port(), &liveness),
        password(credentials),
        fixture.database(),
        TlsConfig::disabled(),
        settings,
        liveness,
    )
}

pub async fn connect_with(options: ConnectOptions) -> Arc<dyn Connection> {
    MysqlDriver
        .connect(options, CancellationToken::new())
        .await
        .expect("a connection")
}

pub async fn connect_settings(fixture: &MysqlFixture, settings: WorkspaceSettings) -> Arc<dyn Connection> {
    connect_with(fixture_options(fixture, &fixture.password_credentials(), settings)).await
}

pub async fn connect(fixture: &MysqlFixture, read_only: bool) -> Arc<dyn Connection> {
    connect_settings(fixture, WorkspaceSettings::workspace(read_only)).await
}

/// The image's root, for a test that changes a global or reads another
/// session's transaction.
pub async fn connect_root(fixture: &MysqlFixture) -> Arc<dyn Connection> {
    connect_with(fixture_options(
        fixture,
        &fixture.root_credentials(),
        WorkspaceSettings::workspace(false),
    ))
    .await
}

pub fn table(name: &str) -> TableRef {
    TableRef::new(Some("tablepro".to_owned()), name)
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
) -> Result<WriteReport, DriverError> {
    apply_on(connection, kind, &TableRef::unqualified("t"), statements).await
}

pub async fn apply_on(
    connection: &dyn Connection,
    kind: WriteKind,
    table: &TableRef,
    statements: &[&str],
) -> Result<WriteReport, DriverError> {
    let mut batch = batch(table, statements);
    batch.kind = kind;
    connection.write_batch(&batch, within(CALL)).await
}

/// Row changes on `table`, each statement unguarded.
pub fn batch(table: &TableRef, statements: &[&str]) -> WriteBatch {
    let steps = statements
        .iter()
        .map(|sql| GuardedStatement::unguarded(statement(sql)))
        .collect();
    WriteBatch::new(WriteKind::RowChanges, table.clone(), steps, ForeignKeyMode::Enforced)
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

pub async fn count(connection: &dyn Connection, sql: &str) -> u64 {
    connection
        .count_rows(&statement(sql), within(CALL))
        .await
        .expect("a count")
}

pub async fn session(connection: &dyn Connection) -> Arc<dyn EditorSession> {
    session_with(connection, EditorSessionOptions::default()).await
}

pub async fn session_with(connection: &dyn Connection, options: EditorSessionOptions) -> Arc<dyn EditorSession> {
    connection
        .open_editor_session(options, CancellationToken::new())
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

    pub fn started(&self) -> usize {
        self.all()
            .iter()
            .filter(|event| matches!(event, ResultEvent::ResultSetStarted { .. }))
            .count()
    }

    /// Each finished set's retained rows, total and truncation.
    pub fn finished(&self) -> Vec<(u64, Option<u64>, Truncation)> {
        self.all()
            .into_iter()
            .filter_map(|event| match event {
                ResultEvent::ResultSetFinished {
                    retained,
                    total_rows,
                    truncation,
                } => Some((retained, total_rows, truncation)),
                _ => None,
            })
            .collect()
    }

    pub fn affected(&self) -> Vec<Option<u64>> {
        self.all()
            .into_iter()
            .filter_map(|event| match event {
                ResultEvent::CommandCompleted { rows_affected } => Some(rows_affected),
                _ => None,
            })
            .collect()
    }
}

pub struct EventSink {
    events: Events,
}

impl EventSink {
    pub fn new(events: &Events) -> Self {
        Self { events: events.clone() }
    }
}

#[async_trait]
impl ResultSink for EventSink {
    async fn accept(&mut self, event: ResultEvent) -> SinkFlow {
        self.events.0.lock().unwrap_or_else(PoisonError::into_inner).push(event);
        SinkFlow::Continue
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

/// The first value of the only row an editor run returned, as text.
pub async fn session_scalar(session: &dyn EditorSession, sql: &str) -> String {
    let events = run_ok(session, sql).await;
    events
        .rows()
        .first()
        .and_then(|row| row.first())
        .map(text)
        .expect("one value")
}
