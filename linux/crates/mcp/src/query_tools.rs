use std::sync::{Arc, Mutex, PoisonError};
use std::time::{Duration, Instant, SystemTime};

use serde::Serialize;
use tablepro_core::browse::{DeclaredPrecisionSink, ExportRequest, build_count, build_export};
use tablepro_core::meta::{ObjectScope, RowIdentity};
use tablepro_core::sql_syntax::script::{LexicalSettings, ScriptPlan};
use tablepro_core::sql_syntax::{SqlGrammar, changes_catalog, statement_access};
use tablepro_core::{
    CallOptions, ColumnInfo, EditorSessionOptions, ExternalGate, ExternalRefusal, ReadStatement, ResultSink, RowLimit,
    RunEnd, RunOptions, TableRef, TransactionState, UserSql,
};
use tablepro_session::{ConnectionLease, OperationError, OperationKind, Session};
use tablepro_storage::SavedConnection;
use tablepro_storage::query_history::{NewEntry, Outcome};
use tokio_util::sync::CancellationToken;

use crate::browse_request::{filter_set, sort_keys};
use crate::collected_results::{CollectedResults, ResultCollector};
use crate::connection_tools::to_json;
use crate::mcp_host::WriteApproval;
use crate::schema_tools::no_such_table;
use crate::tool_args::{BrowseArgs, CountArgs, QueryArgs};
use crate::tool_context::ToolContext;
use crate::tool_error::ToolError;

pub const DEFAULT_ROWS: u32 = 100;
pub const MAX_ROWS: u32 = 1_000;
pub const DEFAULT_TIMEOUT_SECONDS: u32 = 30;
pub const MAX_TIMEOUT_SECONDS: u32 = 300;
pub const MAX_QUERY_BYTES: usize = 100 * 1024;

const TRANSACTION_NOTE: &str =
    "The statement left a transaction open, and it was rolled back when the call's connection closed.";

pub async fn execute_query(
    context: &ToolContext,
    args: QueryArgs,
    cancel: CancellationToken,
) -> Result<String, ToolError> {
    let connection = context.connection(&args.connection_id)?;
    let limit = row_limit(args.max_rows, "max_rows")?;
    let timeout = timeout(args.timeout_seconds)?;
    if args.query.len() > MAX_QUERY_BYTES {
        return Err(ToolError::InvalidArgument(format!(
            "the query is {} bytes; the limit is {MAX_QUERY_BYTES}",
            args.query.len()
        )));
    }
    let session = context.session(&connection).await?;
    let dialect = session.current_dialect().ok_or_else(|| {
        ToolError::NotConnected(format!("“{}” has no connection right now", connection.name))
    })?;
    let grammar = dialect.grammar();
    let text = single_batch(&args.query, grammar)?;
    let access = statement_access(&text, grammar);
    let executed_at = SystemTime::now();
    let started = Instant::now();
    let ran = match connection.external_access.gate(session.safe_mode(), access) {
        ExternalGate::Refuse(reason) => return Err(refusal(&connection, reason)),
        ExternalGate::Run => run_read(&session, &text, limit, timeout, &cancel).await,
        ExternalGate::Confirm { destructive } => {
            let approval = WriteApproval {
                connection_id: connection.id,
                connection_name: connection.name.clone(),
                sql: text.clone(),
                destructive,
                cancel: cancel.clone(),
            };
            if !context.host.approve(approval).await {
                return Err(ToolError::UserCancelled(
                    "the user declined the statement in TablePro".to_owned(),
                ));
            }
            // A level the user changed while the question was open
            // applies to the answer.
            let now = context.connection(&args.connection_id)?;
            if let ExternalGate::Refuse(reason) = now.external_access.gate(session.safe_mode(), access) {
                return Err(refusal(&now, reason));
            }
            let ran = run_write(&session, &text, limit, timeout, &cancel).await;
            if ran.is_ok() && changes_catalog(&text, grammar) {
                refresh_catalog(&session).await;
            }
            ran
        }
    };
    let elapsed = started.elapsed();
    context
        .host
        .record(history_entry(&connection, &text, executed_at, elapsed, &ran), dialect)
        .await;
    let (collected, notes) = ran?;
    collected.to_json(elapsed, &notes)
}

/// One statement per call, or one `GO` batch on SQL Server, so what the
/// user approves is all that runs and a refusal never leaves half a
/// script applied.
fn single_batch(query: &str, grammar: SqlGrammar) -> Result<String, ToolError> {
    let plan = ScriptPlan::build(query, grammar, LexicalSettings::default_for(grammar));
    if !plan.diagnostics().is_empty() {
        return Err(ToolError::InvalidArgument(
            "the query leaves a string, quoted name or comment open".to_owned(),
        ));
    }
    let batches: Vec<_> = plan
        .batches()
        .iter()
        .filter_map(|batch| {
            let text = query.get(batch.range.clone())?.trim();
            (!text.is_empty()).then_some((text, batch.repeat.get()))
        })
        .collect();
    match batches.as_slice() {
        [] => Err(ToolError::InvalidArgument("the query is empty".to_owned())),
        [(_, repeat)] if *repeat > 1 => Err(ToolError::InvalidArgument(
            "GO with a count runs the batch more than once; send it once per call".to_owned(),
        )),
        [(text, _)] => Ok((*text).to_owned()),
        _ => Err(ToolError::InvalidArgument(
            "send one statement per call, or one batch on SQL Server".to_owned(),
        )),
    }
}

fn refusal(connection: &SavedConnection, reason: ExternalRefusal) -> ToolError {
    match reason {
        ExternalRefusal::Blocked => ToolError::NotFound(format!("no connection has the id {}", connection.id)),
        ExternalRefusal::ReadOnlyAccess => ToolError::Denied(format!(
            "“{}” lets MCP clients read only; the user can allow writes under External Clients in the connection's settings",
            connection.name
        )),
        ExternalRefusal::SafeModeReadOnly => ToolError::Denied(format!(
            "Safe Mode on “{}” is Read-Only, which refuses every write",
            connection.name
        )),
    }
}

type Ran = Result<(CollectedResults, Vec<&'static str>), ToolError>;

/// A read runs on a connection of its own that the engine holds
/// read-only, so a write the statement gate did not see still fails.
async fn run_read(
    session: &Session,
    text: &str,
    limit: usize,
    timeout: Duration,
    cancel: &CancellationToken,
) -> Ran {
    let read = ReadStatement::User(UserSql::new(text));
    let collected = stream(session, limit, timeout, cancel, None, move |_| Ok(read.clone())).await?;
    Ok((collected, Vec::new()))
}

/// A write runs on an editor session of its own, opened for the one
/// statement and closed after it, as an editor tab would run it.
async fn run_write(
    session: &Session,
    text: &str,
    limit: usize,
    timeout: Duration,
    cancel: &CancellationToken,
) -> Ran {
    let options = EditorSessionOptions {
        statement_timeout: Some(timeout),
    };
    let editor = session
        .open_editor_session(options, cancel)
        .await
        .map_err(|error| ToolError::from_operation(&error))?;
    let state = Arc::new(Mutex::new(CollectedResults::default()));
    let sink = ResultCollector::new(state.clone(), limit, false);
    let row_limit = RowLimit::new(limit as u64).unwrap_or(RowLimit::EDITOR_DEFAULT);
    let run = RunOptions::new(cancel.child_token())
        .with_row_limit(row_limit)
        .with_deadline(Some(timeout));
    let summary = editor.run(UserSql::new(text), run, Box::new(sink)).await;
    editor.close().await;
    let collected = std::mem::take(&mut *state.lock().unwrap_or_else(PoisonError::into_inner));
    let summary = summary.map_err(|error| ToolError::from_driver(&error))?;
    match summary.end {
        RunEnd::Completed => {
            let notes = match summary.transaction_state {
                TransactionState::InTransaction | TransactionState::Failed => vec![TRANSACTION_NOTE],
                TransactionState::Idle | TransactionState::Unknown => Vec::new(),
            };
            Ok((collected, notes))
        }
        RunEnd::Failed(error) => Err(ToolError::QueryFailed(error.to_string())),
        RunEnd::Cancelled => Err(ToolError::UserCancelled("the request was cancelled".to_owned())),
        RunEnd::TimedOut { .. } => Err(timed_out(timeout)),
    }
}

/// Stream the read `build` makes from the lease that runs it, keeping
/// `limit` rows of each result set and stopping at the row past them.
/// A table's rows pass through `precision`, so a decimal keeps the scale
/// its column declares, as in an export.
async fn stream<F>(
    session: &Session,
    limit: usize,
    timeout: Duration,
    cancel: &CancellationToken,
    precision: Option<Arc<[ColumnInfo]>>,
    build: F,
) -> Result<CollectedResults, ToolError>
where
    F: Fn(&ConnectionLease) -> Result<ReadStatement, OperationError> + Send + Sync,
{
    let state = Arc::new(Mutex::new(CollectedResults::default()));
    let deadline = tokio::time::Instant::now() + timeout;
    let build = &build;
    let result = session
        .run_cancellable(OperationKind::Export, cancel, |lease, call| {
            let state = state.clone();
            let precision = precision.clone();
            async move {
                *state.lock().unwrap_or_else(PoisonError::into_inner) = CollectedResults::default();
                let read = build(&lease)?;
                let collector: Box<dyn ResultSink> = Box::new(ResultCollector::new(state, limit, true));
                let sink: Box<dyn ResultSink> = match precision {
                    Some(catalog) => Box::new(DeclaredPrecisionSink::new(collector, catalog)),
                    None => collector,
                };
                let options = CallOptions::new(Some(deadline), call.cancel().clone());
                Ok(lease.stream_read(&read, sink, options).await?)
            }
        })
        .await;
    let collected = std::mem::take(&mut *state.lock().unwrap_or_else(PoisonError::into_inner));
    match result {
        Ok(_) => Ok(collected),
        // The sink ended the read at the limit, which the driver reports
        // as a stop.
        Err(_) if collected.stopped_at_limit => Ok(collected),
        Err(OperationError::Driver(tablepro_core::DriverError::Timeout { .. })) => Err(timed_out(timeout)),
        Err(error) => Err(ToolError::from_operation(&error)),
    }
}

pub async fn browse_table(
    context: &ToolContext,
    args: BrowseArgs,
    cancel: CancellationToken,
) -> Result<String, ToolError> {
    let connection = context.connection(&args.connection_id)?;
    let limit = row_limit(args.limit, "limit")?;
    let filter = filter_set(&args.filters, args.logic)?;
    let session = context.session(&connection).await?;
    let table = TableRef::new(args.schema, args.table);
    let (columns, identity) = table_shape(&session, &table).await?;
    let sort = sort_keys(&args.sort, &columns)?;
    let catalog: Arc<[ColumnInfo]> = columns.into();
    let started = Instant::now();
    let collected = stream(
        &session,
        limit,
        Duration::from_secs(u64::from(DEFAULT_TIMEOUT_SECONDS)),
        &cancel,
        Some(catalog.clone()),
        move |lease| {
            let request = ExportRequest {
                table: &table,
                columns: &catalog,
                filter: &filter,
                sort: &sort,
                identity: &identity,
            };
            Ok(ReadStatement::Generated(build_export(&*lease.dialect(), &request)?))
        },
    )
    .await;
    collected?.to_json(started.elapsed(), &[])
}

/// The table's columns and how its rows are told apart, read together.
async fn table_shape(session: &Session, table: &TableRef) -> Result<(Vec<ColumnInfo>, RowIdentity), ToolError> {
    let read = session
        .run(OperationKind::Metadata, |lease, call| {
            let table = table.clone();
            async move {
                let columns = lease.fetch_columns(&table, call.clone()).await?;
                if columns.is_empty() {
                    return Ok((columns, None));
                }
                let identity = lease.row_identity(&table, call).await?;
                Ok((columns, Some(identity)))
            }
        })
        .await
        .map_err(|error| ToolError::from_operation(&error))?;
    match read {
        (columns, Some(identity)) => Ok((columns, identity)),
        (_, None) => Err(no_such_table(table)),
    }
}

#[derive(Serialize)]
struct RowCount {
    table: String,
    row_count: u64,
}

pub async fn count_rows(context: &ToolContext, args: CountArgs) -> Result<String, ToolError> {
    let connection = context.connection(&args.connection_id)?;
    let filter = filter_set(&args.filters, args.logic)?;
    let session = context.session(&connection).await?;
    let table = TableRef::new(args.schema, args.table);
    let (columns, _) = table_shape(&session, &table).await?;
    let count = session
        .run(OperationKind::Count, |lease, call| {
            let (table, columns, filter) = (&table, &columns, &filter);
            async move {
                let statement = build_count(&*lease.dialect(), table, columns, filter)?;
                Ok(lease.count_rows(&statement, call).await?)
            }
        })
        .await
        .map_err(|error| ToolError::from_operation(&error))?;
    to_json(&RowCount {
        table: table.name,
        row_count: count,
    })
}

fn row_limit(asked: Option<u32>, name: &str) -> Result<usize, ToolError> {
    match asked.unwrap_or(DEFAULT_ROWS) {
        rows @ 1..=MAX_ROWS => Ok(rows as usize),
        rows => Err(ToolError::InvalidArgument(format!(
            "{name} must be 1 to {MAX_ROWS}, not {rows}"
        ))),
    }
}

fn timeout(asked: Option<u32>) -> Result<Duration, ToolError> {
    match asked.unwrap_or(DEFAULT_TIMEOUT_SECONDS) {
        seconds @ 1..=MAX_TIMEOUT_SECONDS => Ok(Duration::from_secs(u64::from(seconds))),
        seconds => Err(ToolError::InvalidArgument(format!(
            "timeout_seconds must be 1 to {MAX_TIMEOUT_SECONDS}, not {seconds}"
        ))),
    }
}

fn timed_out(timeout: Duration) -> ToolError {
    ToolError::Timeout(format!(
        "the statement ran past {} seconds and was stopped",
        timeout.as_secs()
    ))
}

/// The sidebar and completion read the catalog again, as after DDL the
/// editor runs.
async fn refresh_catalog(session: &Session) {
    session.invalidate_columns();
    for scope in [ObjectScope::AllSchemas, ObjectScope::DefaultSchema] {
        if let Err(error) = session.refresh_objects(scope).await {
            tracing::debug!(%error, "the catalog was not read again after a client's DDL");
        }
    }
}

fn history_entry(
    connection: &SavedConnection,
    text: &str,
    executed_at: SystemTime,
    elapsed: Duration,
    ran: &Ran,
) -> NewEntry {
    let (rows_affected, outcome) = match ran {
        Ok((collected, _)) => (
            collected.rows_affected.and_then(|rows| i64::try_from(rows).ok()),
            Outcome::Success,
        ),
        Err(ToolError::UserCancelled(_)) => (None, Outcome::Cancelled),
        Err(error) => (None, Outcome::Error(error.message().to_owned())),
    };
    NewEntry {
        query: text.to_owned(),
        driver_id: connection.driver_id.clone(),
        connection_id: connection.id,
        connection_name: connection.name.clone(),
        executed_at,
        duration_ms: i64::try_from(elapsed.as_millis()).ok(),
        rows_affected,
        outcome,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn one_statement_passes_and_two_are_refused() {
        assert_eq!(
            single_batch("  SELECT 1;  ", SqlGrammar::PostgreSql).ok().as_deref(),
            Some("SELECT 1")
        );
        assert!(single_batch("SELECT 1; SELECT 2", SqlGrammar::PostgreSql).is_err());
        assert!(single_batch("", SqlGrammar::PostgreSql).is_err());
        assert!(single_batch("SELECT 'open", SqlGrammar::PostgreSql).is_err());
    }

    #[test]
    fn a_sql_server_batch_is_one_unit_and_a_repeated_one_is_refused() {
        assert_eq!(
            single_batch("DECLARE @n int = 1\nSELECT @n", SqlGrammar::MsSql).ok().as_deref(),
            Some("DECLARE @n int = 1\nSELECT @n")
        );
        assert!(single_batch("SELECT 1\nGO\nSELECT 2", SqlGrammar::MsSql).is_err());
        assert!(single_batch("UPDATE t SET n = n + 1 WHERE id = 1\nGO 5", SqlGrammar::MsSql).is_err());
    }

    #[test]
    fn limits_outside_their_range_are_refused() {
        assert_eq!(row_limit(None, "limit").ok(), Some(100));
        assert!(row_limit(Some(0), "limit").is_err());
        assert!(row_limit(Some(MAX_ROWS + 1), "limit").is_err());
        assert_eq!(timeout(Some(300)).ok(), Some(Duration::from_secs(300)));
        assert!(timeout(Some(301)).is_err());
    }
}
