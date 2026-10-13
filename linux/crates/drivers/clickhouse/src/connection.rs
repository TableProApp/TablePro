use std::future::Future;
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering};
use std::time::Duration;

use async_trait::async_trait;
use tablepro_core::column::ColumnInfo;
use tablepro_core::ddl::TableDefinition;
use tablepro_core::dialect::SqlDialect;
use tablepro_core::meta::{IndexInfo, ObjectInfo, ObjectScope, RowIdentity, SchemaInfo, TableEstimate, TableRef};
use tablepro_core::statement::Statement;
use tablepro_core::{
    CallOptions, CommitResolution, CommitToken, Connection, DriverError, EditorSession, EditorSessionOptions,
    ErrorCategory, ForeignKeyInfo, LinkState, LinkWatch, LivenessPolicy, LossPhase, OwnedCalls, QueryResult,
    ReadStatement, ResultSink, RowLimit, ServerInfo, StreamSummary, TimeoutPhase, WorkspaceSettings, WriteAtomicity,
    WriteBatch, WriteLedger, WriteReport,
};
use tokio::time::Instant;
use tokio_util::sync::{CancellationToken, WaitForCancellationFutureOwned};

use crate::call_client::{CallClient, read_bound, reading};
use crate::cancel::{ClickHouseStop, StopProgress};
use crate::catalog::{self, CatalogTable};
use crate::commit_resolution::resolve;
use crate::dialect::ClickHouseDialect;
use crate::editor_session::ClickHouseEditorSession;
use crate::endpoint::ClickHouseEndpoint;
use crate::http_call::HttpCall;
use crate::metadata;
use crate::result_reader::read_table;
use crate::stream_read::stream;
use crate::write_batch::{WritePlan, perform, precheck};

/// A workspace's link to one ClickHouse server: hyper's pool behind the
/// sidebar, the grid and every save.
pub(crate) struct ClickHouseConnection {
    endpoint: Arc<ClickHouseEndpoint>,
    calls: OwnedCalls,
    settings: WorkspaceSettings,
    server: ServerInfo,
    default_database: String,
    dialect: Arc<ClickHouseDialect>,
    link: LinkWatch,
    closed: AtomicBool,
}

/// Which client a call's queries go through.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Client {
    /// The workspace's own, held to reads.
    Reads,
    /// The control client, for the driver's own SYSTEM statements.
    Control,
}

impl ClickHouseConnection {
    pub(crate) fn new(
        endpoint: Arc<ClickHouseEndpoint>,
        settings: WorkspaceSettings,
        server: ServerInfo,
        default_database: String,
    ) -> Self {
        let grace = endpoint.liveness().cancel_grace;
        let dialect = Arc::new(ClickHouseDialect::new(&server));
        Self {
            endpoint,
            calls: OwnedCalls::new(grace),
            settings,
            server,
            default_database,
            dialect,
            link: LinkWatch::new(),
            closed: AtomicBool::new(false),
        }
    }

    fn liveness(&self) -> &LivenessPolicy {
        self.endpoint.liveness()
    }

    fn ensure_open(&self) -> Result<(), DriverError> {
        if self.closed.load(Ordering::SeqCst) {
            return Err(DriverError::ConnectionLost {
                during: LossPhase::Idle,
            });
        }
        Ok(())
    }

    fn catalog_table(&self, table: &TableRef) -> CatalogTable {
        CatalogTable {
            database: table
                .schema
                .clone()
                .filter(|schema| !schema.is_empty())
                .unwrap_or_else(|| self.default_database.clone()),
            name: table.name.clone(),
        }
    }

    /// Run one read on a task that outlives the caller, with a KILL
    /// QUERY as its stop. `bound` is how long the server itself lets it
    /// run, on top of the call's deadline.
    async fn read<T, W, Fut>(
        &self,
        options: CallOptions,
        client: Client,
        bound: Option<Duration>,
        work: W,
    ) -> Result<T, DriverError>
    where
        T: Send + 'static,
        W: FnOnce(CallClient) -> Fut + Send + 'static,
        Fut: Future<Output = Result<T, DriverError>> + Send + 'static,
    {
        self.ensure_open()?;
        let stop = Arc::new(ClickHouseStop::new(self.endpoint.control().clone()));
        let base = match client {
            Client::Reads => reading(self.endpoint.workspace(), read_bound(options.deadline(), bound)),
            Client::Control => self.endpoint.control().clone(),
        };
        let work_stop = stop.clone();
        let outcome = self
            .calls
            .run_read(
                options,
                HttpCall::new(),
                stop.clone(),
                move |call, request| async move {
                    let result = work(CallClient::new(base, work_stop, request)).await;
                    (call, result)
                },
            )
            .await;
        self.settle(outcome, &stop).await
    }

    /// A workspace read, bounded by the workspace's statement timeout.
    async fn workspace_read<T, W, Fut>(&self, options: CallOptions, work: W) -> Result<T, DriverError>
    where
        T: Send + 'static,
        W: FnOnce(CallClient) -> Fut + Send + 'static,
        Fut: Future<Output = Result<T, DriverError>> + Send + 'static,
    {
        let bound = Some(self.settings.statement_timeout);
        self.read(options, Client::Reads, bound, work).await
    }

    /// Decide whether a failed call means the link itself is gone.
    ///
    /// The KILL already tried the route: if it never got an answer, the
    /// route is gone. Otherwise a request of its own answers the
    /// question within the cancel grace, so a dead route is reported
    /// within the call's deadline plus that grace.
    async fn settle<T>(&self, outcome: Result<T, DriverError>, stop: &ClickHouseStop) -> Result<T, DriverError> {
        let error = match outcome {
            Ok(value) => return Ok(value),
            Err(error) => self.endpoint.explain(error).await,
        };
        if !suspects_link(&error) {
            return Err(error);
        }
        let lost = match known_lost(stop.progress(), stop.withheld()) {
            Some(lost) => lost,
            None => {
                let checked = self.endpoint.check(self.liveness().cancel_grace).await;
                checked.is_err_and(|failure| means_link_lost(&failure))
            }
        };
        if !lost {
            return Err(error);
        }
        self.link.mark_lost();
        Err(match error {
            DriverError::Timeout { .. } => DriverError::ConnectionLost {
                during: LossPhase::Statement,
            },
            other => other,
        })
    }
}

/// A failure that may mean the route is gone rather than one statement.
fn suspects_link(error: &DriverError) -> bool {
    match error {
        DriverError::ConnectionLost { .. } | DriverError::Transport(_) => true,
        DriverError::Timeout {
            server_cancelled: false,
            phase,
        } => matches!(phase, TimeoutPhase::Statement | TimeoutPhase::Probe),
        _ => false,
    }
}

/// What the stop already says about the route, or `None` when only a
/// request of its own can tell.
///
/// A call that waits on its KILL and ends with it still out means the
/// route stopped answering. A call that ended by holding back its next
/// query waited on nothing, so a KILL still out says nothing yet.
fn known_lost(progress: StopProgress, withheld: bool) -> Option<bool> {
    match progress {
        StopProgress::Unreachable => Some(true),
        StopProgress::InFlight if !withheld => Some(true),
        StopProgress::Delivered => Some(false),
        StopProgress::InFlight | StopProgress::NotSent | StopProgress::NothingToStop => None,
    }
}

fn means_link_lost(error: &DriverError) -> bool {
    matches!(
        error.category(),
        ErrorCategory::Network | ErrorCategory::ConnectionLost | ErrorCategory::Timeout
    )
}

#[async_trait]
impl Connection for ClickHouseConnection {
    fn server_info(&self) -> &ServerInfo {
        &self.server
    }

    fn dialect(&self) -> Arc<dyn SqlDialect> {
        self.dialect.clone()
    }

    fn read_only(&self) -> bool {
        self.settings.read_only
    }

    fn link_state(&self) -> LinkState {
        self.link.state()
    }

    fn lost(&self) -> WaitForCancellationFutureOwned {
        self.link.lost()
    }

    /// A fresh request: HTTP has no pool slot to wait for, so a busy
    /// workspace never holds the probe up.
    async fn probe(&self, options: CallOptions) -> Result<(), DriverError> {
        self.ensure_open()?;
        let deadline = options
            .deadline()
            .unwrap_or_else(|| Instant::now() + self.liveness().probe_timeout);
        let bound = deadline.saturating_duration_since(Instant::now());
        let outcome = tokio::select! {
            () = options.cancel().cancelled() => Err(DriverError::Cancelled),
            outcome = self.endpoint.check(bound) => outcome,
        };
        let outcome = match outcome {
            Err(error) => Err(self.endpoint.explain(error).await),
            ok => ok,
        };
        if let Err(error) = &outcome
            && means_link_lost(error)
        {
            self.link.mark_lost();
        }
        outcome
    }

    async fn list_schemas(&self, options: CallOptions) -> Result<Vec<SchemaInfo>, DriverError> {
        self.workspace_read(options, |calls| async move { metadata::list_schemas(&calls).await })
            .await
    }

    async fn list_objects(&self, scope: &ObjectScope, options: CallOptions) -> Result<Vec<ObjectInfo>, DriverError> {
        let scope = scope.clone();
        let database = self.default_database.clone();
        self.workspace_read(options, move |calls| async move {
            metadata::list_objects(&calls, &scope, &database).await
        })
        .await
    }

    async fn fetch_columns(&self, table: &TableRef, options: CallOptions) -> Result<Vec<ColumnInfo>, DriverError> {
        let table = self.catalog_table(table);
        self.workspace_read(options, move |calls| async move {
            let rows = catalog::column_rows(&calls, &table).await?;
            Ok(rows.iter().map(catalog::ClickHouseColumnRow::info).collect())
        })
        .await
    }

    async fn fetch_indexes(&self, table: &TableRef, options: CallOptions) -> Result<Vec<IndexInfo>, DriverError> {
        let table = self.catalog_table(table);
        self.workspace_read(options, move |calls| async move {
            catalog::fetch_indexes(&calls, &table).await
        })
        .await
    }

    /// ClickHouse has no foreign keys.
    async fn fetch_foreign_keys(
        &self,
        _table: &TableRef,
        _options: CallOptions,
    ) -> Result<Vec<ForeignKeyInfo>, DriverError> {
        self.ensure_open()?;
        Ok(Vec::new())
    }

    async fn fetch_table_definition(
        &self,
        table: &TableRef,
        options: CallOptions,
    ) -> Result<TableDefinition, DriverError> {
        let catalog_table = self.catalog_table(table);
        let table = table.clone();
        self.workspace_read(options, move |calls| async move {
            catalog::fetch_table_definition(&calls, &table, &catalog_table).await
        })
        .await
    }

    async fn row_identity(&self, table: &TableRef, options: CallOptions) -> Result<RowIdentity, DriverError> {
        let table = self.catalog_table(table);
        self.workspace_read(options, move |calls| async move {
            catalog::row_identity(&calls, &table).await
        })
        .await
    }

    async fn table_estimate(&self, table: &TableRef, options: CallOptions) -> Result<TableEstimate, DriverError> {
        let table = self.catalog_table(table);
        self.workspace_read(options, move |calls| async move {
            catalog::table_estimate(&calls, &table).await
        })
        .await
    }

    async fn query_bound(
        &self,
        statement: &Statement,
        limit: RowLimit,
        options: CallOptions,
    ) -> Result<QueryResult, DriverError> {
        let statement = statement.clone();
        self.workspace_read(options, move |calls| async move {
            let table = read_table(calls.statement(&statement)?, Some(limit.get())).await?;
            Ok(QueryResult::new(table.columns, table.rows).truncated(table.truncated))
        })
        .await
    }

    async fn count_rows(&self, statement: &Statement, options: CallOptions) -> Result<u64, DriverError> {
        let statement = statement.clone();
        self.workspace_read(options, move |calls| async move {
            let table = read_table(calls.statement(&statement)?, Some(1)).await?;
            let value = table
                .rows
                .first()
                .and_then(|row| row.first())
                .ok_or_else(|| DriverError::Protocol("the count returned no row".to_owned()))?;
            value
                .as_exact_u64()
                .ok_or_else(|| DriverError::Protocol(format!("the count returned {value:?}")))
        })
        .await
    }

    /// An export can take minutes, so the server sets no bound of its
    /// own; the caller's deadline and cancel still stop it.
    async fn stream_read(
        &self,
        read: &ReadStatement,
        mut sink: Box<dyn ResultSink>,
        options: CallOptions,
    ) -> Result<StreamSummary, DriverError> {
        let read = read.clone();
        self.read(options, Client::Reads, None, move |calls| async move {
            stream(&calls, &read, sink.as_mut()).await
        })
        .await
    }

    async fn write_batch(&self, batch: &WriteBatch, options: CallOptions) -> Result<WriteReport, DriverError> {
        self.ensure_open()?;
        precheck(batch, self.settings.read_only)?;
        let stop = Arc::new(ClickHouseStop::new(self.endpoint.control().clone()));
        let ledger = Arc::new(WriteLedger::new(WriteAtomicity::StatementByStatement));
        let probe_bound = read_bound(options.deadline(), Some(self.settings.statement_timeout));
        let written = self.catalog_table(&batch.table);
        let plan = WritePlan {
            batch: batch.clone(),
            table: TableRef::new(Some(written.database), written.name),
            ledger: ledger.clone(),
            probes: reading(self.endpoint.workspace(), probe_bound),
            writes: self
                .endpoint
                .workspace()
                .clone()
                .with_setting("wait_end_of_query", "1")
                .with_setting("max_execution_time", "0"),
        };
        let work_stop = stop.clone();
        let outcome = self
            .calls
            .run_write(
                options,
                HttpCall::new(),
                stop.clone(),
                ledger,
                move |call, request| async move {
                    let result = perform(&plan, &request, &work_stop).await;
                    (call, result)
                },
            )
            .await;
        self.settle(outcome, &stop).await
    }

    async fn resolve_commit(&self, token: &CommitToken, options: CallOptions) -> Result<CommitResolution, DriverError> {
        let token = token.clone();
        let bound = Some(self.settings.statement_timeout);
        self.read(options, Client::Control, bound, move |calls| async move {
            resolve(&calls, &token).await
        })
        .await
    }

    async fn open_editor_session(
        &self,
        options: EditorSessionOptions,
        cancel: CancellationToken,
    ) -> Result<Arc<dyn EditorSession>, DriverError> {
        self.ensure_open()?;
        let session = ClickHouseEditorSession::open(&self.endpoint, options, cancel).await?;
        Ok(session)
    }

    async fn close(&self) -> Result<(), DriverError> {
        if self.closed.swap(true, Ordering::SeqCst) {
            return Ok(());
        }
        self.calls.shutdown().await;
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_kill_still_out_after_a_held_back_query_is_not_a_lost_route() {
        assert_eq!(known_lost(StopProgress::InFlight, true), None);
        assert_eq!(known_lost(StopProgress::Unreachable, true), Some(true));
        assert_eq!(known_lost(StopProgress::Delivered, true), Some(false));
        assert_eq!(known_lost(StopProgress::InFlight, false), Some(true));
        assert_eq!(known_lost(StopProgress::Unreachable, false), Some(true));
        assert_eq!(known_lost(StopProgress::Delivered, false), Some(false));
        assert_eq!(known_lost(StopProgress::NotSent, false), None);
        assert_eq!(known_lost(StopProgress::NothingToStop, false), None);
    }
}
