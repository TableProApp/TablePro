use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering};

use async_trait::async_trait;
use deadpool_postgres::{Pool, PoolError, TimeoutType, Timeouts};
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
use tokio_util::task::TaskTracker;

use crate::cancel::{PgStop, StopProgress};
use crate::commit_resolution::resolve_op;
use crate::dialect::PgDialect;
use crate::editor::PgEditorSession;
use crate::errors::{map_error, map_pool_error};
use crate::metadata;
use crate::pg_call::PgCall;
use crate::physical::PgEndpoint;
use crate::pool::{probe_timeouts, workspace_timeouts};
use crate::standalone::Standalone;
use crate::stream_read::stream;
use crate::workspace_call::{Access, ReadOp, count_op, flight, preamble, query_bound_op, read_op, statement_bound};
use crate::write_batch::{WritePlan, perform, precheck};

/// A workspace's link to one PostgreSQL server: a pool of four
/// connections behind the sidebar, the grid and every save.
pub(crate) struct PgConnection {
    endpoint: Arc<PgEndpoint>,
    pool: Pool,
    calls: OwnedCalls,
    tracker: TaskTracker,
    settings: WorkspaceSettings,
    server: ServerInfo,
    dialect: Arc<PgDialect>,
    link: LinkWatch,
    closed: AtomicBool,
}

impl PgConnection {
    pub(crate) fn new(
        endpoint: Arc<PgEndpoint>,
        pool: Pool,
        tracker: TaskTracker,
        settings: WorkspaceSettings,
        server: ServerInfo,
    ) -> Self {
        let grace = endpoint.liveness().cancel_grace;
        let dialect = Arc::new(PgDialect::new(&server));
        Self {
            endpoint,
            pool,
            calls: OwnedCalls::new(grace),
            tracker,
            settings,
            server,
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

    /// The table's name as `::regclass` resolves it.
    fn relation(&self, table: &TableRef) -> String {
        self.dialect.qualify(table)
    }

    /// Run one read in its own read-only transaction on a pooled
    /// connection, owned by a task that outlives the caller.
    async fn read<T: Send + 'static>(&self, options: CallOptions, op: ReadOp<T>) -> Result<T, DriverError> {
        self.ensure_open()?;
        let stop = Arc::new(PgStop::new(self.endpoint.clone()));
        let pool = self.pool.clone();
        let timeouts = workspace_timeouts(self.liveness());
        let begin = self.read_preamble(&options);
        let work_stop = stop.clone();
        let outcome = self
            .calls
            .run_read(
                options,
                PgCall::new(),
                stop.clone(),
                move |mut call, request| async move {
                    if let Err(error) = call.acquire(&pool, &timeouts, &request, &work_stop).await {
                        return (call, Err(error));
                    }
                    let result = flight(&call, &begin, op).await;
                    (call, result)
                },
            )
            .await;
        self.settle(outcome, &stop).await
    }

    fn read_preamble(&self, options: &CallOptions) -> String {
        preamble(
            Access::ReadOnly,
            Some(statement_bound(&self.settings, options.deadline())),
            self.settings.lock_timeout,
        )
    }

    /// Decide whether a failed call means the link itself is gone.
    ///
    /// A call that timed out or lost its connection may have met a dead
    /// route or only a dead backend. The cancel request already tried a
    /// fresh stream: if even that never settled, the route is gone.
    /// Otherwise a connection of its own answers the question, within
    /// the cancel grace, so a dead route is reported within the call's
    /// deadline plus that grace.
    async fn settle<T>(&self, outcome: Result<T, DriverError>, stop: &PgStop) -> Result<T, DriverError> {
        let error = match outcome {
            Ok(value) => return Ok(value),
            Err(error) => self.endpoint.explain(error).await,
        };
        if !suspects_link(&error) {
            return Err(error);
        }
        let lost = match stop.progress() {
            StopProgress::InFlight | StopProgress::Failed => true,
            StopProgress::Delivered => false,
            StopProgress::NotSent | StopProgress::NothingToStop => {
                let checked = self.endpoint.check(self.liveness().cancel_grace, &self.tracker).await;
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

    /// The probe of a busy pool: a connection of its own, asked one
    /// trivial question within the probe's deadline.
    async fn probe_standalone(&self, deadline: Instant) -> Result<(), DriverError> {
        let bound = deadline.saturating_duration_since(Instant::now());
        self.endpoint.check(bound, &self.tracker).await
    }
}

/// A failure that may mean the route is gone rather than one statement:
/// a lost connection, a transport error, or a timeout the server never
/// acknowledged.
fn suspects_link(error: &DriverError) -> bool {
    match error {
        DriverError::ConnectionLost { .. } | DriverError::Transport(_) => true,
        DriverError::Timeout {
            server_cancelled: false,
            phase,
        } => matches!(
            phase,
            TimeoutPhase::Statement | TimeoutPhase::Probe | TimeoutPhase::Login
        ),
        _ => false,
    }
}

fn means_link_lost(error: &DriverError) -> bool {
    matches!(
        error.category(),
        ErrorCategory::Network | ErrorCategory::ConnectionLost | ErrorCategory::Timeout
    )
}

#[async_trait]
impl Connection for PgConnection {
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

    async fn probe(&self, options: CallOptions) -> Result<(), DriverError> {
        self.ensure_open()?;
        let deadline = options
            .deadline()
            .unwrap_or_else(|| Instant::now() + self.liveness().probe_timeout);
        let probing = async {
            let quick: Timeouts = probe_timeouts(self.liveness());
            match self.pool.timeout_get(&quick).await {
                Ok(object) => object
                    .simple_query("SELECT 1")
                    .await
                    .map(|_| ())
                    .map_err(|error| map_error(&error)),
                // Every slot is busy, which is not the server being gone.
                Err(PoolError::Timeout(TimeoutType::Wait)) => self.probe_standalone(deadline).await,
                Err(error) => Err(map_pool_error(&error)),
            }
        };
        let outcome = tokio::select! {
            () = options.cancel().cancelled() => Err(DriverError::Cancelled),
            outcome = tokio::time::timeout_at(deadline, probing) => outcome.unwrap_or(Err(DriverError::Timeout {
                phase: TimeoutPhase::Probe,
                server_cancelled: false,
            })),
        };
        if let Err(error) = &outcome
            && matches!(error.category(), ErrorCategory::Network | ErrorCategory::ConnectionLost)
        {
            self.link.mark_lost();
        }
        outcome
    }

    async fn list_schemas(&self, options: CallOptions) -> Result<Vec<SchemaInfo>, DriverError> {
        self.read(options, read_op(|client| Box::pin(metadata::list_schemas(client))))
            .await
    }

    async fn list_objects(&self, scope: &ObjectScope, options: CallOptions) -> Result<Vec<ObjectInfo>, DriverError> {
        let scope = scope.clone();
        self.read(
            options,
            read_op(move |client| Box::pin(async move { metadata::list_objects(client, &scope).await })),
        )
        .await
    }

    async fn fetch_columns(&self, table: &TableRef, options: CallOptions) -> Result<Vec<ColumnInfo>, DriverError> {
        let relation = self.relation(table);
        self.read(
            options,
            read_op(move |client| Box::pin(async move { metadata::fetch_columns(client, &relation).await })),
        )
        .await
    }

    async fn fetch_indexes(&self, table: &TableRef, options: CallOptions) -> Result<Vec<IndexInfo>, DriverError> {
        let relation = self.relation(table);
        self.read(
            options,
            read_op(move |client| Box::pin(async move { metadata::fetch_indexes(client, &relation).await })),
        )
        .await
    }

    async fn fetch_foreign_keys(
        &self,
        table: &TableRef,
        options: CallOptions,
    ) -> Result<Vec<ForeignKeyInfo>, DriverError> {
        let relation = self.relation(table);
        self.read(
            options,
            read_op(move |client| Box::pin(async move { metadata::fetch_foreign_keys(client, &relation).await })),
        )
        .await
    }

    async fn fetch_table_definition(
        &self,
        table: &TableRef,
        options: CallOptions,
    ) -> Result<TableDefinition, DriverError> {
        let relation = self.relation(table);
        let table = table.clone();
        self.read(
            options,
            read_op(move |client| {
                Box::pin(async move { metadata::fetch_table_definition(client, &table, &relation).await })
            }),
        )
        .await
    }

    async fn row_identity(&self, table: &TableRef, options: CallOptions) -> Result<RowIdentity, DriverError> {
        let relation = self.relation(table);
        self.read(
            options,
            read_op(move |client| Box::pin(async move { metadata::row_identity(client, &relation).await })),
        )
        .await
    }

    async fn table_estimate(&self, table: &TableRef, options: CallOptions) -> Result<TableEstimate, DriverError> {
        let relation = self.relation(table);
        self.read(
            options,
            read_op(move |client| Box::pin(async move { metadata::table_estimate(client, &relation).await })),
        )
        .await
    }

    async fn query_bound(
        &self,
        statement: &Statement,
        limit: RowLimit,
        options: CallOptions,
    ) -> Result<QueryResult, DriverError> {
        let begin = self.read_preamble(&options);
        self.read(options, query_bound_op(statement.clone(), limit, begin))
            .await
    }

    async fn count_rows(&self, statement: &Statement, options: CallOptions) -> Result<u64, DriverError> {
        self.read(options, count_op(statement.clone())).await
    }

    async fn stream_read(
        &self,
        read: &ReadStatement,
        mut sink: Box<dyn ResultSink>,
        options: CallOptions,
    ) -> Result<StreamSummary, DriverError> {
        self.ensure_open()?;
        let stop = Arc::new(PgStop::new(self.endpoint.clone()));
        let endpoint = self.endpoint.clone();
        let tracker = self.tracker.clone();
        let read = read.clone();
        let work_stop = stop.clone();
        let outcome = self
            .calls
            .run_read(
                options,
                Standalone::new(),
                stop.clone(),
                move |mut link, request| async move {
                    if let Err(error) = link.open(&endpoint, &tracker, &request, &work_stop).await {
                        return (link, Err(error));
                    }
                    let result = match link.client() {
                        Ok(client) => stream(client, &read, sink.as_mut()).await,
                        Err(error) => Err(error),
                    };
                    (link, result)
                },
            )
            .await;
        self.settle(outcome, &stop).await
    }

    async fn write_batch(&self, batch: &WriteBatch, options: CallOptions) -> Result<WriteReport, DriverError> {
        self.ensure_open()?;
        precheck(batch, self.settings.read_only)?;
        let stop = Arc::new(PgStop::new(self.endpoint.clone()));
        let ledger = Arc::new(WriteLedger::new(WriteAtomicity::Transactional));
        let pool = self.pool.clone();
        let timeouts = workspace_timeouts(self.liveness());
        let plan = WritePlan {
            batch: batch.clone(),
            settings: self.settings,
            ledger: ledger.clone(),
            legacy_txid: !self.server.at_least(13, 0, 0),
        };
        let work_stop = stop.clone();
        let outcome = self
            .calls
            .run_write(
                options,
                PgCall::new(),
                stop.clone(),
                ledger,
                move |mut call, request| async move {
                    if let Err(error) = call.acquire(&pool, &timeouts, &request, &work_stop).await {
                        let error = match request.is_requested() {
                            true => plan.ledger.interrupted(error, tablepro_core::SessionFate::RolledBack),
                            false => error,
                        };
                        return (call, Err(error));
                    }
                    let result = perform(&call, &plan, &request, &work_stop).await;
                    (call, result)
                },
            )
            .await;
        self.settle(outcome, &stop).await
    }

    async fn resolve_commit(&self, token: &CommitToken, options: CallOptions) -> Result<CommitResolution, DriverError> {
        self.read(options, resolve_op(token)?).await
    }

    async fn open_editor_session(
        &self,
        options: EditorSessionOptions,
        cancel: CancellationToken,
    ) -> Result<Arc<dyn EditorSession>, DriverError> {
        self.ensure_open()?;
        let session = PgEditorSession::open(self.endpoint.clone(), self.settings.read_only, options, cancel).await?;
        Ok(session)
    }

    async fn close(&self) -> Result<(), DriverError> {
        if self.closed.swap(true, Ordering::SeqCst) {
            return Ok(());
        }
        self.calls.shutdown().await;
        self.pool.close();
        self.tracker.close();
        let _ = tokio::time::timeout(self.liveness().close_timeout, self.tracker.wait()).await;
        Ok(())
    }
}
