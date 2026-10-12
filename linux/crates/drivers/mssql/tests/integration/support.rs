//! What the SQL Server integration modules share: targets over the
//! fixture's port, one-line calls, and a sink that keeps what it gets.
//!
//! The fixture forces encryption, so every target asks for TLS unless a
//! case is about TLS itself.

use std::sync::{Arc, Mutex, PoisonError};
use std::time::Duration;

use async_trait::async_trait;
use drivers_mssql::MssqlDriver;
use secrecy::SecretString;
use tablepro_core::column::ColumnInfo;
use tablepro_core::dialect::{BindTarget, SqlDialect};
use tablepro_core::statement::{GuardedStatement, Statement, StatementBuilder};
use tablepro_core::{
    CallOptions, ConnectEnvironment, ConnectOptions, ConnectTarget, Connection, Credentials, DatabaseDriver,
    DriverError, EditorSession, EditorSessionOptions, ForeignKeyMode, LivenessPolicy, NetworkEndpoint, NetworkTarget,
    ResultEvent, ResultSink, RowLimit, RunEnd, RunOptions, RunSummary, SinkFlow, TableRef, TlsConfig, TlsMode,
    Transport, UserSql, Value, WorkspaceSettings, WriteBatch, WriteKind, WriteReport,
};
use tablepro_net::DirectTcpTransport;
use tablepro_test_fixtures::{FixtureCredentials, MssqlFixture};
use tablepro_test_support::conformance::test_liveness;
use tokio::time::Instant;
use tokio_util::sync::CancellationToken;

pub const CALL: Duration = Duration::from_secs(30);
pub const DATABASE: &str = "master";

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

/// TLS without verification, which a server that forces encryption
/// needs and the test CA is not involved in.
pub fn require() -> TlsConfig {
    TlsConfig {
        mode: TlsMode::Require,
        ..TlsConfig::disabled()
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
        }),
        workspace_settings: settings,
        liveness,
        environment: ConnectEnvironment::new("test"),
    }
}

pub fn fixture_options(fixture: &MssqlFixture, tls: TlsConfig, settings: WorkspaceSettings) -> ConnectOptions {
    let liveness = test_liveness();
    options_over(
        direct(fixture.host(), fixture.port(), &liveness),
        password(&fixture.password_credentials()),
        tls,
        settings,
        liveness,
    )
}

pub async fn dial(options: ConnectOptions) -> Result<Arc<dyn Connection>, DriverError> {
    MssqlDriver.connect(options, CancellationToken::new()).await
}

pub async fn connect(fixture: &MssqlFixture, read_only: bool) -> Arc<dyn Connection> {
    dial(fixture_options(
        fixture,
        require(),
        WorkspaceSettings::workspace(read_only),
    ))
    .await
    .expect("a connection")
}

pub async fn start() -> MssqlFixture {
    MssqlFixture::start().await.expect("a SQL Server container")
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
        .query_bound(&statement(sql), RowLimit::EDITOR_DEFAULT, within(CALL))
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

pub fn dbo(name: &str) -> TableRef {
    TableRef::new(Some("dbo".to_owned()), name)
}

pub async fn columns(connection: &dyn Connection, table: &TableRef) -> Vec<ColumnInfo> {
    connection
        .fetch_columns(table, within(CALL))
        .await
        .expect("the table's columns")
}

/// Read a table the way browse does: every column through the dialect's
/// projection.
pub async fn browse(connection: &dyn Connection, table: &TableRef) -> Vec<Vec<Value>> {
    let dialect = connection.dialect();
    let projections: Vec<String> = columns(connection, table)
        .await
        .iter()
        .map(|column| dialect.projection(column))
        .collect();
    let sql = format!("SELECT {} FROM {}", projections.join(", "), dialect.qualify(table));
    rows(connection, &sql).await
}

/// `INSERT INTO table (column) VALUES (<value bound for that column>)`.
pub fn insert_one(dialect: &dyn SqlDialect, table: &TableRef, column: &ColumnInfo, value: Value) -> Statement {
    let mut builder = StatementBuilder::new();
    builder.push_sql(&format!(
        "INSERT INTO {} ({}) VALUES (",
        dialect.qualify(table),
        dialect.quote_identifier(&column.name)
    ));
    builder
        .push_value(dialect, value, BindTarget::Column(column))
        .expect("the value binds");
    builder.push_sql(")");
    builder.finish()
}

pub async fn write(connection: &dyn Connection, statements: Vec<Statement>) -> Result<WriteReport, DriverError> {
    let steps = statements.into_iter().map(GuardedStatement::unguarded).collect();
    let batch = WriteBatch::new(
        WriteKind::RowChanges,
        TableRef::unqualified("t"),
        steps,
        ForeignKeyMode::Enforced,
    );
    connection.write_batch(&batch, within(CALL)).await
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

#[async_trait]
impl ResultSink for Events {
    async fn accept(&mut self, event: ResultEvent) -> SinkFlow {
        self.0.lock().unwrap_or_else(PoisonError::into_inner).push(event);
        SinkFlow::Continue
    }
}

pub async fn run_with(session: &dyn EditorSession, sql: &str, options: RunOptions) -> (RunSummary, Events) {
    let events = Events::default();
    let summary = session
        .run(UserSql::new(sql), options, Box::new(events.clone()))
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

pub fn quoted(name: &str) -> String {
    format!("[{}]", name.replace(']', "]]"))
}

/// The `hh:mm:ss.fff` WAITFOR DELAY takes.
pub fn delay(hold: Duration) -> String {
    let millis = hold.as_millis();
    format!(
        "{:02}:{:02}:{:02}.{:03}",
        millis / 3_600_000,
        millis / 60_000 % 60,
        millis / 1_000 % 60,
        millis % 1_000
    )
}
