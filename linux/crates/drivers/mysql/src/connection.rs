use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering};

use async_trait::async_trait;
use deadpool::managed::{PoolError, TimeoutType};
use sqlx::Executor as _;
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

use crate::cancel::{ControlLink, MySqlStop, StopProgress};
use crate::dialect::MySqlDialect;
use crate::editor_session::MysqlEditorSession;
use crate::errors::{map_error, map_pool_error};
use crate::flavour::MySqlFlavour;
use crate::metadata;
use crate::mysql_call::MysqlCall;
use crate::mysql_manager::{MysqlPool, probe_timeouts, workspace_timeouts};
use crate::physical::MysqlEndpoint;
use crate::session_statements::SessionLimits;
use crate::standalone::Standalone;
use crate::stream_read::stream;
use crate::table_engine;
use crate::workspace_call::{ReadOp, count_op, query_bound_op, read_op};
use crate::write_batch::{WriteContext, WritePlan, perform, precheck};

/// A workspace's link to one MySQL or MariaDB server: a pool of four
/// connections behind the sidebar, the grid and every save.
pub(crate) struct MysqlConnection {
    endpoint: Arc<MysqlEndpoint>,
    pool: MysqlPool,
    control: Arc<ControlLink>,
    calls: OwnedCalls,
    settings: WorkspaceSettings,
    server: ServerInfo,
    dialect: Arc<MySqlDialect>,
    link: LinkWatch,
    closed: AtomicBool,
}

impl MysqlConnection {
    pub(crate) fn new(
        endpoint: Arc<MysqlEndpoint>,
        pool: MysqlPool,
        settings: WorkspaceSettings,
        flavour: MySqlFlavour,
        server: ServerInfo,
    ) -> Self {
        let grace = endpoint.liveness().cancel_grace;
        let dialect = Arc::new(MySqlDialect::new(flavour, &server));
        Self {
            control: Arc::new(ControlLink::new(endpoint.clone())),
            endpoint,
            pool,
            calls: OwnedCalls::new(grace),
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

    fn flavour(&self) -> MySqlFlavour {
        self.dialect.flavour()
    }

    fn ensure_open(&self) -> Result<(), DriverError> {
        if self.closed.load(Ordering::SeqCst) {
            return Err(DriverError::ConnectionLost {
                during: LossPhase::Idle,
            });
        }
        Ok(())
    }

    /// Run one read on a pooled connection, owned by a task that outlives
    /// the caller.
    async fn read<T: Send + 'static>(&self, options: CallOptions, op: ReadOp<T>) -> Result<T, DriverError> {
        self.ensure_open()?;
        let stop = Arc::new(MySqlStop::new(self.control.clone()));
        let pool = self.pool.clone();
        let timeouts = workspace_timeouts(self.liveness());
        let work_stop = stop.clone();
        let outcome = self
            .calls
            .run_read(
                options,
                MysqlCall::new(),
                stop.clone(),
                move |mut call, request| async move {
                    if let Err(error) = call.acquire(&pool, &timeouts, &request, &work_stop).await {
                        return (call, Err(error));
                    }
                    let result = match call.connection() {
                        Ok((connection, flavour)) => op(connection, flavour).await,
                        Err(error) => Err(error),
                    };
                    (call, result)
                },
            )
            .await;
        self.settle(outcome, &stop).await
    }

    /// Decide whether a failed call means the link itself is gone.
    ///
    /// sqlx has no keepalive on a direct route, so a dead peer shows up
    /// only as a call that times out or loses its connection. A KILL
    /// that never got through already says the route is gone; otherwise
    /// a login of its own answers the question within the cancel grace.
    async fn settle<T>(&self, outcome: Result<T, DriverError>, stop: &MySqlStop) -> Result<T, DriverError> {
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
            StopProgress::NotSent | StopProgress::NothingToStop => self
                .endpoint
                .check(self.liveness().cancel_grace)
                .await
                .is_err_and(|failure| means_link_lost(&failure)),
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

    /// Whether the table's engine can roll back, read before the write
    /// so the ledger knows what an interruption leaves behind.
    async fn atomicity(&self, batch: &WriteBatch, options: &CallOptions) -> Result<WriteAtomicity, DriverError> {
        if batch.kind == WriteKind::SchemaChanges {
            return Ok(WriteAtomicity::StatementByStatement);
        }
        let table = batch.table.clone();
        // A call cancels its token when it returns, so the lookup gets a
        // child: the write that follows still answers to the caller.
        let lookup = CallOptions::new(options.deadline(), options.cancel().child_token());
        let engine = self
            .read(
                lookup,
                read_op(move |connection, flavour| {
                    Box::pin(async move { table_engine::lookup(connection, flavour, &table).await })
                }),
            )
            .await?;
        Ok(engine.atomicity())
    }

    fn stream_limits(&self) -> SessionLimits {
        SessionLimits {
            statement_timeout: None,
            ..SessionLimits::workspace(&self.settings)
        }
    }
}

/// A failure that may mean the route is gone rather than one statement.
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
impl Connection for MysqlConnection {
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
        let flavour = self.flavour();
        let probing = async {
            match self.pool.timeout_get(&probe_timeouts(self.liveness())).await {
                Ok(mut object) => object
                    .connection
                    .execute("SELECT 1")
                    .await
                    .map(|_| ())
                    .map_err(|error| map_error(&error, flavour)),
                // Every slot is busy, which is not the server being gone.
                Err(PoolError::Timeout(TimeoutType::Wait)) => {
                    let bound = deadline.saturating_duration_since(Instant::now());
                    self.endpoint.check(bound).await
                }
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
        self.read(
            options,
            read_op(|connection, flavour| Box::pin(metadata::list_schemas(connection, flavour))),
        )
        .await
    }

    async fn list_objects(&self, scope: &ObjectScope, options: CallOptions) -> Result<Vec<ObjectInfo>, DriverError> {
        let scope = scope.clone();
        self.read(
            options,
            read_op(move |connection, flavour| {
                Box::pin(async move { metadata::list_objects(connection, flavour, &scope).await })
            }),
        )
        .await
    }

    async fn fetch_columns(&self, table: &TableRef, options: CallOptions) -> Result<Vec<ColumnInfo>, DriverError> {
        let table = table.clone();
        self.read(
            options,
            read_op(move |connection, flavour| {
                Box::pin(async move { metadata::fetch_columns(connection, flavour, &table).await })
            }),
        )
        .await
    }

    async fn fetch_indexes(&self, table: &TableRef, options: CallOptions) -> Result<Vec<IndexInfo>, DriverError> {
        let table = table.clone();
        let dialect = *self.dialect;
        self.read(
            options,
            read_op(move |connection, _| {
                Box::pin(async move { metadata::fetch_indexes(connection, &dialect, &table).await })
            }),
        )
        .await
    }

    async fn fetch_foreign_keys(
        &self,
        table: &TableRef,
        options: CallOptions,
    ) -> Result<Vec<ForeignKeyInfo>, DriverError> {
        let table = table.clone();
        self.read(
            options,
            read_op(move |connection, flavour| {
                Box::pin(async move { metadata::fetch_foreign_keys(connection, flavour, &table).await })
            }),
        )
        .await
    }

    async fn fetch_table_definition(
        &self,
        table: &TableRef,
        options: CallOptions,
    ) -> Result<TableDefinition, DriverError> {
        let table = table.clone();
        let dialect = *self.dialect;
        self.read(
            options,
            read_op(move |connection, _| {
                Box::pin(async move { metadata::fetch_table_definition(connection, &dialect, &table).await })
            }),
        )
        .await
    }

    async fn row_identity(&self, table: &TableRef, options: CallOptions) -> Result<RowIdentity, DriverError> {
        let table = table.clone();
        let dialect = *self.dialect;
        self.read(
            options,
            read_op(move |connection, _| {
                Box::pin(async move { metadata::row_identity(connection, &dialect, &table).await })
            }),
        )
        .await
    }

    async fn table_estimate(&self, table: &TableRef, options: CallOptions) -> Result<TableEstimate, DriverError> {
        let table = table.clone();
        self.read(
            options,
            read_op(move |connection, flavour| {
                Box::pin(async move { metadata::table_estimate(connection, flavour, &table).await })
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
        self.read(options, query_bound_op(statement.clone(), limit)).await
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
        let stop = Arc::new(MySqlStop::new(self.control.clone()));
        let endpoint = self.endpoint.clone();
        let limits = self.stream_limits();
        let read = read.clone();
        let work_stop = stop.clone();
        let outcome = self
            .calls
            .run_read(
                options,
                Standalone::new(),
                stop.clone(),
                move |mut link, request| async move {
                    if let Err(error) = link.open(&endpoint, &limits, &request, &work_stop).await {
                        return (link, Err(error));
                    }
                    let result = match link.connection() {
                        Ok((connection, flavour)) => stream(connection, flavour, &read, sink.as_mut()).await,
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
        if batch.is_empty() {
            return Ok(WriteReport::default());
        }
        let atomicity = self.atomicity(batch, &options).await?;
        let stop = Arc::new(MySqlStop::new(self.control.clone()));
        let ledger = Arc::new(WriteLedger::new(atomicity));
        let pool = self.pool.clone();
        let timeouts = workspace_timeouts(self.liveness());
        let plan = WritePlan {
            batch: batch.clone(),
            atomicity,
            ledger: ledger.clone(),
            settings: self.settings,
        };
        let work_stop = stop.clone();
        let outcome = self
            .calls
            .run_write(
                options,
                MysqlCall::new(),
                stop.clone(),
                ledger,
                move |mut call, request| async move {
                    if let Err(error) = call.acquire(&pool, &timeouts, &request, &work_stop).await {
                        let error = match request.is_requested() {
                            true => plan.ledger.interrupted(error, SessionFate::RolledBack),
                            false => error,
                        };
                        return (call, Err(error));
                    }
                    let tainter = call.tainter();
                    let result = match call.connection() {
                        Ok((connection, flavour)) => {
                            let mut context = WriteContext {
                                connection,
                                flavour,
                                tainter,
                                request: &request,
                                stop: &work_stop,
                            };
                            perform(&mut context, &plan).await
                        }
                        Err(error) => Err(error),
                    };
                    (call, result)
                },
            )
            .await;
        self.settle(outcome, &stop).await
    }

    /// No COMMIT outcome can be asked about after the fact: MySQL keeps
    /// no record of a transaction once its session is gone.
    async fn resolve_commit(
        &self,
        _token: &CommitToken,
        _options: CallOptions,
    ) -> Result<CommitResolution, DriverError> {
        Err(DriverError::Unsupported {
            feature: "commit resolution",
        })
    }

    async fn open_editor_session(
        &self,
        options: EditorSessionOptions,
        cancel: CancellationToken,
    ) -> Result<Arc<dyn EditorSession>, DriverError> {
        self.ensure_open()?;
        let limits = SessionLimits::workspace(&self.settings);
        let session = MysqlEditorSession::open(self.endpoint.clone(), limits, options, cancel).await?;
        Ok(session)
    }

    async fn close(&self) -> Result<(), DriverError> {
        if self.closed.swap(true, Ordering::SeqCst) {
            return Ok(());
        }
        self.calls.shutdown().await;
        self.pool.close();
        self.control.close().await;
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn only_route_failures_are_suspected() {
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
        assert!(!suspects_link(&DriverError::server("syntax error")));
    }
}
