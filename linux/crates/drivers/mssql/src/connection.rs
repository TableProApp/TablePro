use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering};
use std::time::Duration;

use async_trait::async_trait;
use deadpool::managed::{PoolError, TimeoutType};
use tablepro_core::column::ColumnInfo;
use tablepro_core::ddl::TableDefinition;
use tablepro_core::dialect::SqlDialect;
use tablepro_core::meta::{IndexInfo, ObjectInfo, ObjectScope, RowIdentity, SchemaInfo, TableEstimate, TableRef};
use tablepro_core::statement::Statement;
use tablepro_core::{
    CallOptions, CommitResolution, CommitToken, Connection, DriverError, EditorSession, EditorSessionOptions,
    ErrorCategory, ForeignKeyInfo, LinkState, LinkWatch, LivenessPolicy, LossPhase, OwnedCalls, QueryResult,
    ReadStatement, ResultSink, RowLimit, ServerInfo, SessionFate, StreamSummary, TimeoutPhase, WorkspaceSettings,
    WriteAtomicity, WriteBatch, WriteKind, WriteLedger, WriteReport,
};
use tokio::time::Instant;
use tokio_util::sync::{CancellationToken, WaitForCancellationFutureOwned};

use crate::cancel::{MssqlStop, StopProgress};
use crate::dialect::MssqlDialect;
use crate::editor_session::MssqlEditorSession;
use crate::endpoint::MssqlEndpoint;
use crate::errors::map_pool_error;
use crate::in_band_request::{StopPolicy, Watch, conclude};
use crate::metadata;
use crate::mssql_manager::{MssqlPool, probe_timeouts, workspace_timeouts};
use crate::mssql_pooled::MssqlPooled;
use crate::standalone::Standalone;
use crate::stream_read::stream;
use crate::workspace_call::{Guard, ReadOp, count_op, query_bound_op, read_op};
use crate::write_batch::{WritePlan, perform, precheck};

/// A workspace's link to one SQL Server: a pool of four connections
/// behind the sidebar, the grid and every save.
pub(crate) struct MssqlConnection {
    endpoint: Arc<MssqlEndpoint>,
    pool: MssqlPool,
    calls: OwnedCalls,
    settings: WorkspaceSettings,
    server: ServerInfo,
    dialect: Arc<MssqlDialect>,
    policy: StopPolicy,
    link: LinkWatch,
    closed: AtomicBool,
}

impl MssqlConnection {
    pub(crate) fn new(
        endpoint: Arc<MssqlEndpoint>,
        pool: MssqlPool,
        settings: WorkspaceSettings,
        server: ServerInfo,
    ) -> Self {
        let grace = endpoint.liveness().cancel_grace;
        let dialect = Arc::new(MssqlDialect::new(server.major));
        Self {
            endpoint,
            pool,
            calls: OwnedCalls::new(grace),
            settings,
            server,
            dialect,
            policy: StopPolicy::within(grace),
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

    /// The table's name as `OBJECT_ID` resolves it.
    fn relation(&self, table: &TableRef) -> String {
        self.dialect.qualify(table)
    }

    fn guard(&self) -> Guard {
        Guard::for_connection(self.settings.read_only)
    }

    /// Run one read on a pooled connection, owned by a task that
    /// outlives the caller. SQL Server has no statement timeout of its
    /// own, so the workspace's is the call's deadline when it is nearer.
    async fn read<T: Send + 'static>(&self, options: CallOptions, op: ReadOp<T>) -> Result<T, DriverError> {
        self.ensure_open()?;
        let options = bounded(&options, Some(self.settings.statement_timeout));
        let stop = Arc::new(MssqlStop::new());
        let pool = self.pool.clone();
        let timeouts = workspace_timeouts(self.liveness());
        let policy = self.policy;
        let work_stop = stop.clone();
        let outcome = self
            .calls
            .run_read(
                options,
                MssqlPooled::new(),
                stop.clone(),
                move |mut call, request| async move {
                    if let Err(error) = call.acquire(&pool, &timeouts, &request).await {
                        return (call, Err(error));
                    }
                    let result = call.read(&request, policy, &work_stop, op).await;
                    (call, result)
                },
            )
            .await;
        self.settle(outcome, &stop).await
    }

    /// Decide whether a failed call means the link itself is gone.
    ///
    /// An attention nobody answered already says the route is in doubt.
    /// Otherwise a connection of its own answers the question within the
    /// cancel grace, so a dead route is reported within the call's
    /// deadline plus that grace.
    async fn settle<T>(&self, outcome: Result<T, DriverError>, stop: &MssqlStop) -> Result<T, DriverError> {
        let error = match outcome {
            Ok(value) => return Ok(value),
            Err(error) => self.endpoint.explain(error).await,
        };
        if !suspects_link(&error) {
            return Err(error);
        }
        let lost = match stop.progress() {
            StopProgress::Failed => true,
            StopProgress::Delivered => false,
            StopProgress::NotSent => {
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

    /// The probe of a busy pool: a connection of its own, asked one
    /// trivial question within the probe's deadline.
    async fn probe_standalone(&self, deadline: Instant) -> Result<(), DriverError> {
        let bound = deadline.saturating_duration_since(Instant::now());
        self.endpoint.check(bound).await
    }
}

/// The call's options with its deadline no later than `limit` from now.
fn bounded(options: &CallOptions, limit: Option<Duration>) -> CallOptions {
    let capped = limit.map(|limit| Instant::now() + limit);
    let deadline = match (options.deadline(), capped) {
        (Some(deadline), Some(capped)) => Some(deadline.min(capped)),
        (deadline, capped) => deadline.or(capped),
    };
    CallOptions::new(deadline, options.cancel().clone())
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
impl Connection for MssqlConnection {
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
            match self.pool.timeout_get(&probe_timeouts(self.liveness())).await {
                Ok(object) => MssqlPooled::hold(object).ping().await,
                // Every slot is busy, which is not the server being gone.
                Err(PoolError::Timeout(TimeoutType::Wait)) => self.probe_standalone(deadline).await,
                Err(error) => Err(map_pool_error(error)),
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
        self.read(
            options,
            read_op(|client, watch| Box::pin(metadata::list_schemas(client, watch))),
        )
        .await
    }

    async fn list_objects(&self, scope: &ObjectScope, options: CallOptions) -> Result<Vec<ObjectInfo>, DriverError> {
        let scope = scope.clone();
        self.read(
            options,
            read_op(move |client, watch| Box::pin(async move { metadata::list_objects(client, watch, &scope).await })),
        )
        .await
    }

    async fn fetch_columns(&self, table: &TableRef, options: CallOptions) -> Result<Vec<ColumnInfo>, DriverError> {
        let relation = self.relation(table);
        self.read(
            options,
            read_op(move |client, watch| {
                Box::pin(async move { metadata::fetch_columns(client, watch, &relation).await })
            }),
        )
        .await
    }

    async fn fetch_indexes(&self, table: &TableRef, options: CallOptions) -> Result<Vec<IndexInfo>, DriverError> {
        let relation = self.relation(table);
        self.read(
            options,
            read_op(move |client, watch| {
                Box::pin(async move { metadata::fetch_indexes(client, watch, &relation).await })
            }),
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
            read_op(move |client, watch| {
                Box::pin(async move { metadata::fetch_foreign_keys(client, watch, &relation).await })
            }),
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
            read_op(move |client, watch| {
                Box::pin(async move { metadata::fetch_table_definition(client, watch, &table, &relation).await })
            }),
        )
        .await
    }

    async fn row_identity(&self, table: &TableRef, options: CallOptions) -> Result<RowIdentity, DriverError> {
        let relation = self.relation(table);
        self.read(
            options,
            read_op(move |client, watch| {
                Box::pin(async move { metadata::row_identity(client, watch, &relation).await })
            }),
        )
        .await
    }

    async fn table_estimate(&self, table: &TableRef, options: CallOptions) -> Result<TableEstimate, DriverError> {
        let relation = self.relation(table);
        self.read(
            options,
            read_op(move |client, watch| {
                Box::pin(async move { metadata::table_estimate(client, watch, &relation).await })
            }),
        )
        .await
    }

    async fn query_bound(
        &self,
        statement: &Statement,
        limit: RowLimit,
        options: CallOptions,
    ) -> Result<QueryResult, DriverError> {
        self.read(options, query_bound_op(statement.clone(), limit, self.guard()))
            .await
    }

    async fn count_rows(&self, statement: &Statement, options: CallOptions) -> Result<u64, DriverError> {
        self.read(options, count_op(statement.clone(), self.guard())).await
    }

    async fn stream_read(
        &self,
        read: &ReadStatement,
        mut sink: Box<dyn ResultSink>,
        options: CallOptions,
    ) -> Result<StreamSummary, DriverError> {
        self.ensure_open()?;
        let stop = Arc::new(MssqlStop::new());
        let endpoint = self.endpoint.clone();
        let read = read.clone();
        let policy = self.policy;
        let work_stop = stop.clone();
        let outcome = self
            .calls
            .run_read(
                options,
                Standalone::new(),
                stop.clone(),
                move |mut standalone, request| async move {
                    if let Err(error) = standalone.open(&endpoint, &request).await {
                        return (standalone, Err(error));
                    }
                    let result = match standalone.link() {
                        Ok(link) => {
                            let watch = Watch::new(request.clone(), link.tally(), policy);
                            let outcome = stream(&mut link.client, &watch, &read, sink.as_mut()).await;
                            conclude(&mut link.client, &watch, outcome, &work_stop, false)
                                .await
                                .result
                        }
                        Err(error) => Err(error),
                    };
                    (standalone, result)
                },
            )
            .await;
        self.settle(outcome, &stop).await
    }

    async fn write_batch(&self, batch: &WriteBatch, options: CallOptions) -> Result<WriteReport, DriverError> {
        self.ensure_open()?;
        precheck(batch, self.settings.read_only)?;
        // A schema change may legitimately run long; the call's own
        // deadline and cancel still bound it.
        let options = match batch.kind {
            WriteKind::RowChanges => bounded(&options, Some(self.settings.statement_timeout)),
            WriteKind::SchemaChanges => options,
        };
        let stop = Arc::new(MssqlStop::new());
        let ledger = Arc::new(WriteLedger::new(WriteAtomicity::Transactional));
        let pool = self.pool.clone();
        let timeouts = workspace_timeouts(self.liveness());
        let plan = WritePlan {
            batch: batch.clone(),
            ledger: ledger.clone(),
            policy: self.policy,
        };
        let work_stop = stop.clone();
        let outcome = self
            .calls
            .run_write(
                options,
                MssqlPooled::new(),
                stop.clone(),
                ledger,
                move |mut call, request| async move {
                    if let Err(error) = call.acquire(&pool, &timeouts, &request).await {
                        let error = match request.is_requested() {
                            true => plan.ledger.interrupted(error, SessionFate::RolledBack),
                            false => error,
                        };
                        return (call, Err(error));
                    }
                    let result = perform(&mut call, &plan, &request, &work_stop).await;
                    (call, result)
                },
            )
            .await;
        self.settle(outcome, &stop).await
    }

    /// SQL Server keeps no record a lost COMMIT could be looked up by
    /// afterwards, so the question has no answer.
    async fn resolve_commit(
        &self,
        _token: &CommitToken,
        _options: CallOptions,
    ) -> Result<CommitResolution, DriverError> {
        self.ensure_open()?;
        Ok(CommitResolution::Unresolvable)
    }

    async fn open_editor_session(
        &self,
        options: EditorSessionOptions,
        cancel: CancellationToken,
    ) -> Result<Arc<dyn EditorSession>, DriverError> {
        self.ensure_open()?;
        let session = MssqlEditorSession::open(&self.endpoint, options, cancel).await?;
        Ok(session)
    }

    async fn close(&self) -> Result<(), DriverError> {
        if self.closed.swap(true, Ordering::SeqCst) {
            return Ok(());
        }
        self.calls.shutdown().await;
        self.pool.close();
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[tokio::test(start_paused = true)]
    async fn a_near_deadline_tightens_the_bound_and_none_takes_the_limit() {
        let near = Instant::now() + Duration::from_secs(2);
        let options = CallOptions::new(Some(near), CancellationToken::new());

        assert_eq!(bounded(&options, Some(Duration::from_secs(60))).deadline(), Some(near));
        let open = CallOptions::new(None, CancellationToken::new());
        assert_eq!(
            bounded(&open, Some(Duration::from_secs(60))).deadline(),
            Some(Instant::now() + Duration::from_secs(60))
        );
        assert_eq!(bounded(&open, None).deadline(), None);
    }

    #[test]
    fn only_an_unanswered_failure_suspects_the_link() {
        assert!(suspects_link(&DriverError::ConnectionLost {
            during: LossPhase::Statement
        }));
        assert!(suspects_link(&DriverError::Timeout {
            phase: TimeoutPhase::Statement,
            server_cancelled: false
        }));
        assert!(!suspects_link(&DriverError::Timeout {
            phase: TimeoutPhase::Statement,
            server_cancelled: true
        }));
        assert!(!suspects_link(&DriverError::Cancelled));
        assert!(!suspects_link(&DriverError::server("Invalid object name")));
    }
}
