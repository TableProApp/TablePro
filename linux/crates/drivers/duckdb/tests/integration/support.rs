//! What the DuckDB integration cases share: a database file that exists
//! before the driver opens it, connecting, and running plain SQL.

use std::path::PathBuf;
use std::sync::{Arc, Mutex, PoisonError};
use std::time::Duration;

use async_trait::async_trait;
use tablepro_core::meta::TableRef;
use tablepro_core::statement::{GuardedStatement, Statement, StatementBuilder};
use tablepro_core::{
    CallOptions, ConnectEnvironment, ConnectOptions, ConnectTarget, Connection, DatabaseDriver, DriverError,
    EditorSession, EditorSessionOptions, FileEndpoint, ForeignKeyMode, QueryResult, ResultEvent, ResultSink, RowLimit,
    RunOptions, RunSummary, SinkFlow, UserSql, Value, WorkspaceSettings, WriteBatch, WriteKind, WriteReport,
};
use tablepro_driver_duckdb::DuckDbDriver;
use tablepro_test_support::conformance::test_liveness;
use tempfile::TempDir;
use tokio::time::Instant;
use tokio_util::sync::CancellationToken;

use crate::duckdb_engine::create_database;

/// A database file in a directory of its own, removed with it.
pub struct TestFile {
    _directory: TempDir,
    pub path: PathBuf,
}

impl TestFile {
    pub fn new() -> Self {
        let directory = tempfile::tempdir().unwrap();
        let path = directory.path().join("test.duckdb");
        create_database(&path).unwrap();
        Self {
            _directory: directory,
            path,
        }
    }

    pub fn endpoint(&self) -> FileEndpoint {
        FileEndpoint::open_existing(self.path.clone()).unwrap()
    }

    pub async fn open(&self) -> Arc<dyn Connection> {
        connect(self.endpoint(), writable()).await.unwrap()
    }
}

pub fn writable() -> WorkspaceSettings {
    WorkspaceSettings::workspace(false)
}

pub fn options(endpoint: FileEndpoint, settings: WorkspaceSettings) -> ConnectOptions {
    ConnectOptions {
        target: ConnectTarget::File(endpoint),
        workspace_settings: settings,
        liveness: test_liveness(),
        environment: ConnectEnvironment::new("test"),
    }
}

pub async fn connect(endpoint: FileEndpoint, settings: WorkspaceSettings) -> Result<Arc<dyn Connection>, DriverError> {
    DuckDbDriver
        .connect(options(endpoint, settings), CancellationToken::new())
        .await
}

/// A call bound loose enough for a loaded machine.
pub fn call() -> CallOptions {
    CallOptions::new(Some(Instant::now() + Duration::from_secs(30)), CancellationToken::new())
}

pub fn statement(sql: &str) -> Statement {
    let mut builder = StatementBuilder::new();
    builder.push_sql(sql);
    builder.finish()
}

pub fn batch(kind: WriteKind, statements: &[&str]) -> WriteBatch {
    let steps = statements
        .iter()
        .map(|sql| GuardedStatement::unguarded(statement(sql)))
        .collect();
    WriteBatch::new(kind, TableRef::unqualified("t"), steps, ForeignKeyMode::Enforced)
}

/// Run DDL and data changes through the save path.
pub async fn apply(connection: &dyn Connection, statements: &[&str]) -> Result<WriteReport, DriverError> {
    connection
        .write_batch(&batch(WriteKind::SchemaChanges, statements), call())
        .await
}

pub async fn query(connection: &dyn Connection, sql: &str) -> QueryResult {
    connection
        .query_bound(&statement(sql), RowLimit::EDITOR_DEFAULT, call())
        .await
        .unwrap()
}

/// The events one editor run sent.
#[derive(Debug, Clone, Default)]
pub struct Collected(Arc<Mutex<Vec<ResultEvent>>>);

impl Collected {
    pub fn sink(&self) -> Box<dyn ResultSink> {
        Box::new(CollectingSink(self.clone()))
    }

    pub fn events(&self) -> Vec<ResultEvent> {
        self.0.lock().unwrap_or_else(PoisonError::into_inner).clone()
    }

    pub fn rows(&self) -> Vec<Vec<Value>> {
        self.events()
            .into_iter()
            .filter_map(|event| match event {
                ResultEvent::Rows(rows) => Some(rows),
                _ => None,
            })
            .flatten()
            .collect()
    }
}

struct CollectingSink(Collected);

#[async_trait]
impl ResultSink for CollectingSink {
    async fn accept(&mut self, event: ResultEvent) -> SinkFlow {
        self.0.0.lock().unwrap_or_else(PoisonError::into_inner).push(event);
        SinkFlow::Continue
    }
}

pub async fn session(connection: &dyn Connection) -> Arc<dyn EditorSession> {
    connection
        .open_editor_session(EditorSessionOptions::default(), CancellationToken::new())
        .await
        .unwrap()
}

pub async fn run(session: &dyn EditorSession, sql: &str) -> (RunSummary, Collected) {
    run_with(session, sql, RunOptions::new(CancellationToken::new())).await
}

pub async fn run_with(session: &dyn EditorSession, sql: &str, options: RunOptions) -> (RunSummary, Collected) {
    let collected = Collected::default();
    let summary = session.run(UserSql::new(sql), options, collected.sink()).await.unwrap();
    (summary, collected)
}
