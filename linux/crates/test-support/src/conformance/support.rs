//! What the cases share: connecting under a bound, building plain SQL
//! for the scratch table, and collecting what an editor run sends.

use std::sync::{Arc, Mutex};
use std::time::Duration;

use async_trait::async_trait;
use tablepro_core::dialect::SqlDialect;
use tablepro_core::statement::{GuardedStatement, Statement, StatementBuilder};
use tablepro_core::value::Value;
use tablepro_core::{
    CallOptions, ConnectOptions, Connection, DatabaseDriver, DriverError, EditorSession, ForeignKeyMode,
    LivenessPolicy, ResultEvent, ResultSink, RunEnd, RunOptions, RunSummary, SinkFlow, TableRef, Truncation, UserSql,
    WorkspaceSettings, WriteBatch, WriteKind, WriteReport,
};
use tokio::time::Instant;
use tokio_util::sync::CancellationToken;

use crate::conformance::{ConformanceEngine, ConformanceFailure, test_liveness};
use crate::lock;

/// How long a setup call may take. It is not what a case measures, so
/// it only has to be long enough for a loaded container.
pub(crate) const CALL_DEADLINE: Duration = Duration::from_secs(30);

/// Added to every bound a case measures. Timers fire a little after
/// they are due, so a driver that spends its whole cancel grace lands
/// just past the exact sum without breaking the contract.
pub(crate) const SCHEDULING_SLACK: Duration = Duration::from_millis(250);

pub(crate) fn writable() -> WorkspaceSettings {
    WorkspaceSettings::workspace(false)
}

pub(crate) fn within(limit: Duration) -> CallOptions {
    CallOptions::new(Some(Instant::now() + limit), CancellationToken::new())
}

pub(crate) fn no_deadline() -> CallOptions {
    CallOptions::new(None, CancellationToken::new())
}

pub(crate) fn statement(sql: &str) -> Statement {
    let mut builder = StatementBuilder::new();
    builder.push_sql(sql);
    builder.finish()
}

/// A lowercase name no other case uses, so cases sharing a server never
/// see each other's tables or statements.
pub(crate) fn unique(prefix: &str) -> String {
    let suffix = uuid::Uuid::new_v4().simple().to_string();
    format!("tp_{prefix}_{}", suffix.get(..12).unwrap_or(&suffix))
}

pub(crate) fn expect(
    case: &'static str,
    holds: bool,
    detail: impl FnOnce() -> String,
) -> Result<(), ConformanceFailure> {
    if holds { Ok(()) } else { Err(unexpected(case, detail())) }
}

pub(crate) fn unexpected(case: &'static str, detail: impl Into<String>) -> ConformanceFailure {
    ConformanceFailure::Expectation {
        case,
        detail: detail.into(),
    }
}

/// Connect, failing the case rather than hanging when the driver
/// overruns the bound its own liveness policy sets.
pub(crate) async fn dial(
    case: &'static str,
    driver: Arc<dyn DatabaseDriver>,
    options: ConnectOptions,
) -> Result<Result<Arc<dyn Connection>, DriverError>, ConformanceFailure> {
    let liveness = options.liveness;
    let bound = connect_bound(&liveness);
    let connecting = driver.connect(options, CancellationToken::new());
    tokio::time::timeout(bound, connecting)
        .await
        .map_err(|_| unexpected(case, format!("connect did not finish within {bound:?}")))
}

fn connect_bound(liveness: &LivenessPolicy) -> Duration {
    liveness.connect_timeout + liveness.login_timeout + liveness.cancel_grace
}

pub(crate) async fn connect<E: ConformanceEngine>(
    case: &'static str,
    engine: &E,
    settings: WorkspaceSettings,
) -> Result<Arc<dyn Connection>, ConformanceFailure> {
    let options = engine.connect_options(settings, test_liveness());
    Ok(dial(case, E::driver(), options).await??)
}

pub(crate) async fn apply(
    connection: &dyn Connection,
    table: &TableRef,
    kind: WriteKind,
    statements: Vec<String>,
) -> Result<WriteReport, DriverError> {
    let steps = statements
        .iter()
        .map(|sql| GuardedStatement::unguarded(statement(sql)))
        .collect();
    let batch = WriteBatch::new(kind, table.clone(), steps, ForeignKeyMode::Enforced);
    connection.write_batch(&batch, within(CALL_DEADLINE)).await
}

pub(crate) async fn create_scratch_table<E: ConformanceEngine>(
    engine: &E,
    connection: &dyn Connection,
    prefix: &str,
) -> Result<TableRef, ConformanceFailure> {
    let table = engine.scratch_table(&unique(prefix));
    let create = engine.create_scratch_table_sql(&table);
    apply(connection, &table, WriteKind::SchemaChanges, vec![create]).await?;
    Ok(table)
}

pub(crate) fn insert_sql(dialect: &dyn SqlDialect, table: &TableRef, id: i64, label: &str) -> String {
    format!(
        "INSERT INTO {} ({}, {}) VALUES ({id}, '{label}')",
        dialect.qualify(table),
        dialect.quote_identifier("id"),
        dialect.quote_identifier("label"),
    )
}

/// The rows in `table`, through the same `count_rows` the browse tab
/// uses.
pub(crate) async fn count(connection: &dyn Connection, table: &TableRef) -> Result<u64, ConformanceFailure> {
    let dialect = connection.dialect();
    let sql = format!("SELECT {} FROM {}", dialect.count_all(), dialect.qualify(table));
    Ok(connection.count_rows(&statement(&sql), within(CALL_DEADLINE)).await?)
}

/// The events one editor run sent, kept after the sink is gone.
#[derive(Debug, Clone, Default)]
pub(crate) struct Collected(Arc<Mutex<Vec<ResultEvent>>>);

impl Collected {
    fn sink(&self) -> Box<dyn ResultSink> {
        Box::new(CollectingSink(self.clone()))
    }

    pub(crate) fn rows(&self) -> Vec<Vec<Value>> {
        lock(&self.0)
            .iter()
            .filter_map(|event| match event {
                ResultEvent::Rows(rows) => Some(rows.clone()),
                _ => None,
            })
            .flatten()
            .collect()
    }

    pub(crate) fn truncations(&self) -> Vec<Truncation> {
        lock(&self.0)
            .iter()
            .filter_map(|event| match event {
                ResultEvent::ResultSetFinished { truncation, .. } => Some(*truncation),
                _ => None,
            })
            .collect()
    }
}

struct CollectingSink(Collected);

#[async_trait]
impl ResultSink for CollectingSink {
    async fn accept(&mut self, event: ResultEvent) -> SinkFlow {
        lock(&self.0.0).push(event);
        SinkFlow::Continue
    }
}

pub(crate) async fn run_editor(
    session: &dyn EditorSession,
    sql: &str,
    options: RunOptions,
) -> Result<(RunSummary, Collected), DriverError> {
    let collected = Collected::default();
    let summary = session.run(UserSql::new(sql), options, collected.sink()).await?;
    Ok((summary, collected))
}

pub(crate) fn run_options() -> RunOptions {
    RunOptions::new(CancellationToken::new())
}

/// Run `sql` and require it to complete.
pub(crate) async fn run_completed(
    case: &'static str,
    session: &dyn EditorSession,
    sql: &str,
    options: RunOptions,
) -> Result<Collected, ConformanceFailure> {
    let (summary, collected) = run_editor(session, sql, options).await?;
    expect(case, summary.end == RunEnd::Completed, || {
        format!("`{sql}` ended {:?}", summary.end)
    })?;
    Ok(collected)
}

/// The single integer a count query returned.
pub(crate) fn single_count(rows: &[Vec<Value>]) -> Option<u64> {
    match rows.first()?.first()? {
        Value::Int(count) => u64::try_from(*count).ok(),
        Value::UInt(count) => Some(*count),
        Value::Text(count) => count.trim().parse().ok(),
        _ => None,
    }
}

/// Ask the server, through an editor session, how many statements are
/// running, until `done` holds or `limit` passes. `limit` is checked
/// between counts, so each count carries its own deadline.
pub(crate) async fn wait_for_running(
    case: &'static str,
    monitor: &dyn EditorSession,
    count_sql: &str,
    done: impl Fn(u64) -> bool,
    limit: Duration,
) -> Result<u64, ConformanceFailure> {
    let give_up = Instant::now() + limit;
    loop {
        let counting = run_options().with_deadline(Some(CALL_DEADLINE));
        let rows = run_completed(case, monitor, count_sql, counting).await?.rows();
        let Some(running) = single_count(&rows) else {
            return Err(ConformanceFailure::setup(format!(
                "the running-statement count returned {rows:?}, not one integer"
            )));
        };
        if done(running) {
            return Ok(running);
        }
        if Instant::now() >= give_up {
            return Err(unexpected(
                case,
                format!("{running} statements were still running after {limit:?}"),
            ));
        }
        tokio::time::sleep(Duration::from_millis(100)).await;
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::{FakeEditorSession, FakeRun, Replies};

    #[tokio::test(start_paused = true)]
    async fn wait_for_running_fails_when_a_count_never_answers() {
        let mut runs = Replies::default();
        runs.always(FakeRun::until_stopped());
        let monitor = FakeEditorSession::new(runs);

        let waited = tokio::time::timeout(
            CALL_DEADLINE * 2,
            wait_for_running("case", &monitor, "SELECT count", |_| true, Duration::from_secs(1)),
        )
        .await;

        assert!(
            matches!(&waited, Ok(Err(ConformanceFailure::Expectation { case: "case", detail })) if detail.contains("TimedOut")),
            "{waited:?}"
        );
    }
}
