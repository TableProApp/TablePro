//! What the integration modules share: the two servers as types, targets
//! over a fixture's port, one-line calls, and a sink that keeps what it
//! gets.

use std::net::SocketAddr;
use std::sync::{Arc, Mutex, PoisonError};
use std::time::Duration;

use async_trait::async_trait;
use futures_util::{StreamExt, TryStreamExt};
use scylla::client::session::Session;
use scylla::client::session_builder::SessionBuilder;
use scylla::errors::TranslationError;
use scylla::policies::address_translator::{AddressTranslator, UntranslatedPeer};
use scylla::statement::batch::{Batch, BatchType};
use secrecy::SecretString;
use tablepro_core::save::{ChangeSet, plan_save};
use tablepro_core::statement::{GuardedStatement, Statement, StatementBuilder};
use tablepro_core::{
    CallOptions, ConnectEnvironment, ConnectOptions, ConnectTarget, Connection, Credentials, DatabaseDriver,
    DriverError, EditorSession, EditorSessionOptions, ForeignKeyMode, LivenessPolicy, NetworkEndpoint, NetworkTarget,
    ResultEvent, ResultSink, RowLimit, RunEnd, RunOptions, RunSummary, SinkFlow, TableRef, TlsConfig, Transport,
    UserSql, Value, WorkspaceSettings, WriteBatch, WriteKind, WriteReport,
};
use tablepro_driver_cassandra::CassandraDriver;
use tablepro_net::DirectTcpTransport;
use tablepro_test_fixtures::{CassandraFixture, CassandraFlavour, FixtureCredentials};
use tablepro_test_support::conformance::test_liveness;
use tokio::time::Instant;
use tokio_util::sync::CancellationToken;

pub const CALL: Duration = Duration::from_secs(30);
pub const KEYSPACE: &str = "tablepro";

/// One of the two servers, so a test written once runs on both.
pub trait Server: Send + Sync + 'static {
    const FLAVOUR: CassandraFlavour;
}

pub struct CassandraServer;

impl Server for CassandraServer {
    const FLAVOUR: CassandraFlavour = CassandraFlavour::Cassandra;
}

pub struct ScyllaServer;

impl Server for ScyllaServer {
    const FLAVOUR: CassandraFlavour = CassandraFlavour::Scylla;
}

pub fn within(limit: Duration) -> CallOptions {
    CallOptions::new(Some(Instant::now() + limit), CancellationToken::new())
}

pub fn statement(sql: &str) -> Statement {
    let mut builder = StatementBuilder::new();
    builder.push_sql(sql);
    builder.finish()
}

pub fn quoted(name: &str) -> String {
    format!("\"{}\"", name.replace('"', "\"\""))
}

pub fn qualified(name: &str) -> String {
    format!("{}.{}", quoted(KEYSPACE), quoted(name))
}

pub fn table(name: &str) -> TableRef {
    TableRef::new(Some(KEYSPACE.to_owned()), name)
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
            database: Some(KEYSPACE.to_owned()),
            tls,
        }),
        workspace_settings: settings,
        liveness,
        environment: ConnectEnvironment::new("test"),
    }
}

pub fn fixture_options(fixture: &CassandraFixture, settings: WorkspaceSettings) -> ConnectOptions {
    let liveness = test_liveness();
    options_over(
        direct(fixture.host(), fixture.port(), &liveness),
        password(&fixture.password_credentials()),
        TlsConfig::disabled(),
        settings,
        liveness,
    )
}

pub async fn start<S: Server>() -> CassandraFixture {
    CassandraFixture::start(S::FLAVOUR).await.expect("a CQL container")
}

pub async fn connect_with(options: ConnectOptions) -> Arc<dyn Connection> {
    CassandraDriver
        .connect(options, CancellationToken::new())
        .await
        .expect("a connection")
}

pub async fn connect(fixture: &CassandraFixture, read_only: bool) -> Arc<dyn Connection> {
    connect_with(fixture_options(fixture, WorkspaceSettings::workspace(read_only))).await
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

/// Every node the server names is reached at the fixture's published
/// port, which is the only one the test can reach.
struct Published(SocketAddr);

#[async_trait]
impl AddressTranslator for Published {
    async fn translate_address(&self, _peer: &UntranslatedPeer) -> Result<SocketAddr, TranslationError> {
        Ok(self.0)
    }
}

/// A scylla session of the test's own, for setup the driver has no call
/// for: loading rows faster than one statement at a time.
pub async fn loader(fixture: &CassandraFixture) -> Session {
    let address = tokio::net::lookup_host((fixture.host(), fixture.port()))
        .await
        .expect("the fixture's address")
        .find(SocketAddr::is_ipv4)
        .expect("an IPv4 address");
    let credentials = fixture.password_credentials();
    SessionBuilder::new()
        .known_node_addr(address)
        .user(credentials.username, credentials.password)
        .address_translator(Arc::new(Published(address)))
        .disallow_shard_aware_port(true)
        .build()
        .await
        .expect("a loader session")
}

/// `table (bucket int, n int, PRIMARY KEY (bucket, n))` holding `n` from
/// 0 to `rows - 1`, a thousand to a partition. One partition's batch is
/// one write, so the rows land in seconds. A batch the server timed out
/// is sent again, which writes the same rows: a loaded host times out
/// a single node's writes.
pub async fn load_series(fixture: &CassandraFixture, table: &str, rows: u64) {
    const BUCKET: u64 = 1_000;
    const ATTEMPTS: u32 = 4;
    let session = loader(fixture).await;
    let name = qualified(table);
    session
        .query_unpaged(
            format!("CREATE TABLE {name} (bucket int, n int, PRIMARY KEY (bucket, n))"),
            (),
        )
        .await
        .expect("the series table");
    let insert = session
        .prepare(format!("INSERT INTO {name} (bucket, n) VALUES (?, ?)"))
        .await
        .expect("the series insert");
    let session = &session;
    futures_util::stream::iter((0..rows.div_ceil(BUCKET)).map(|bucket| {
        let mut batch = Batch::new(BatchType::Unlogged);
        let mut values = Vec::new();
        for n in bucket * BUCKET..rows.min((bucket + 1) * BUCKET) {
            batch.append_statement(insert.clone());
            values.push((to_int(bucket), to_int(n)));
        }
        async move {
            let mut attempt = 1;
            loop {
                match session.batch(&batch, values.clone()).await {
                    Ok(_) => return Ok(()),
                    Err(_) if attempt < ATTEMPTS => {
                        attempt += 1;
                        tokio::time::sleep(Duration::from_secs(1)).await;
                    }
                    Err(error) => return Err(error),
                }
            }
        }
    }))
    .buffer_unordered(16)
    .try_collect::<Vec<()>>()
    .await
    .expect("the series rows");
}

fn to_int(value: u64) -> i32 {
    i32::try_from(value).expect("an int")
}
