//! What the ClickHouse integration modules share: targets over the
//! fixture's ports, one-line calls, and a sink that keeps what it gets.

use std::sync::{Arc, Mutex, PoisonError};
use std::time::Duration;

use async_trait::async_trait;
use drivers_clickhouse::ClickhouseDriver;
use secrecy::SecretString;
use tablepro_core::save::{ChangeSet, plan_save};
use tablepro_core::statement::{GuardedStatement, Statement, StatementBuilder};
use tablepro_core::{
    CallOptions, ConnectEnvironment, ConnectOptions, ConnectTarget, Connection, Credentials, DatabaseDriver,
    DriverError, EditorSession, EditorSessionOptions, ForeignKeyMode, LivenessPolicy, NetworkEndpoint, NetworkTarget,
    ResultEvent, ResultSink, RowLimit, RunEnd, RunOptions, RunSummary, SinkFlow, TableRef, TlsConfig, Transport,
    UserSql, Value, WorkspaceSettings, WriteBatch, WriteKind, WriteReport,
};
use tablepro_net::DirectTcpTransport;
use tablepro_test_fixtures::{ClickHouseFixture, FixtureCredentials};
use tablepro_test_support::conformance::test_liveness;
use tokio::time::Instant;
use tokio_util::sync::CancellationToken;

pub const CALL: Duration = Duration::from_secs(30);
pub const DATABASE: &str = "tablepro";

pub fn within(limit: Duration) -> CallOptions {
    CallOptions::new(Some(Instant::now() + limit), CancellationToken::new())
}

pub fn statement(sql: &str) -> Statement {
    let mut builder = StatementBuilder::new();
    builder.push_sql(sql);
    builder.finish()
}

/// A name no other test uses, so tests sharing a server never meet.
pub fn unique(prefix: &str) -> String {
    let suffix = uuid::Uuid::new_v4().simple().to_string();
    format!("tp_{prefix}_{}", &suffix[..12])
}

pub fn quoted(name: &str) -> String {
    let mut quoted = String::from("`");
    for character in name.chars() {
        if matches!(character, '\\' | '\'' | '`' | '\t' | '\n') {
            quoted.push('\\');
        }
        quoted.push(character);
    }
    quoted.push('`');
    quoted
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

pub fn fixture_options(fixture: &ClickHouseFixture, settings: WorkspaceSettings) -> ConnectOptions {
    let liveness = test_liveness();
    options_over(
        direct(fixture.host(), fixture.http_port(), &liveness),
        password(&fixture.password_credentials()),
        TlsConfig::disabled(),
        settings,
        liveness,
    )
}

pub async fn start() -> ClickHouseFixture {
    ClickHouseFixture::start().await.expect("a ClickHouse container")
}

pub async fn connect_with(options: ConnectOptions) -> Arc<dyn Connection> {
    ClickhouseDriver
        .connect(options, CancellationToken::new())
        .await
        .expect("a connection")
}

pub async fn connect(fixture: &ClickHouseFixture, read_only: bool) -> Arc<dyn Connection> {
    connect_with(fixture_options(fixture, WorkspaceSettings::workspace(read_only))).await
}

pub fn table(name: &str) -> TableRef {
    TableRef::new(Some(DATABASE.to_owned()), name)
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

/// The save the grid would plan for `changes` on `table`.
pub async fn planned(connection: &dyn Connection, table: &TableRef, changes: &ChangeSet) -> WriteBatch {
    let columns = connection
        .fetch_columns(table, within(CALL))
        .await
        .expect("the columns");
    let identity = connection
        .row_identity(table, within(CALL))
        .await
        .expect("the identity");
    let dialect = connection.dialect();
    plan_save(dialect.as_ref(), table, &columns, &identity, changes)
        .expect("a planned save")
        .batch
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

pub async fn count(connection: &dyn Connection, sql: &str) -> u64 {
    scalar(connection, sql).await.as_exact_u64().expect("a count")
}

/// Run on the server's own control path, for what the tests check
/// behind the driver's back (query_log, mutations, KILL).
pub async fn admin(connection: &dyn Connection, sql: &str) -> Events {
    let session = session(connection).await;
    let events = run_ok(session.as_ref(), sql).await;
    session.close().await;
    events
}

pub async fn flush_logs(connection: &dyn Connection) {
    admin(connection, "SYSTEM FLUSH LOGS").await;
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

struct EventSink(Events);

#[async_trait]
impl ResultSink for EventSink {
    async fn accept(&mut self, event: ResultEvent) -> SinkFlow {
        self.0.0.lock().unwrap_or_else(PoisonError::into_inner).push(event);
        SinkFlow::Continue
    }
}

pub async fn run_with(session: &dyn EditorSession, sql: &str, options: RunOptions) -> (RunSummary, Events) {
    let events = Events::default();
    let summary = session
        .run(UserSql::new(sql), options, Box::new(EventSink(events.clone())))
        .await
        .expect("the session ran the statement");
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
