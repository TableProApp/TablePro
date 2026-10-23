use std::future::Future;
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering};
use std::time::Duration;

use async_trait::async_trait;
use tablepro_core::column::ColumnInfo;
use tablepro_core::ddl::{InboundForeignKey, TableDefinition};
use tablepro_core::dialect::SqlDialect;
use tablepro_core::meta::{
    IndexInfo, ObjectInfo, ObjectScope, RowCountEstimate, RowIdentity, SchemaInfo, TableEstimate, TableRef,
};
use tablepro_core::statement::Statement;
use tablepro_core::{
    CallOptions, CommitResolution, CommitToken, Connection, DriverError, EditorSession, EditorSessionOptions,
    ErrorCategory, ForeignKeyInfo, LinkState, LinkWatch, LossPhase, OwnedCalls, QueryResult, ReadStatement, ResultSink,
    RowLimit, ServerInfo, ServerPage, ServerPageRequest, StopRequest, StreamSummary, TimeoutPhase, WorkspaceSettings,
    WriteAtomicity, WriteBatch, WriteLedger, WriteReport,
};
use tokio::time::Instant;
use tokio_util::sync::{CancellationToken, WaitForCancellationFutureOwned};

use crate::call::{CqlCall, CqlStop, stoppable};
use crate::catalog::{self, CatalogTable};
use crate::dialect::CqlDialect;
use crate::editor::CqlEditorSession;
use crate::rows::{ColumnsRead, MAX_PAGE_ROWS, next_state, page_size, server_page};
use crate::session::{CqlEndpoint, CqlLink, LinkSlot};
use crate::stream_read::stream;
use crate::write_batch::{perform, precheck};

/// A workspace's link to one Cassandra or ScyllaDB node: one scylla
/// session, whose connection carries every call at once.
pub(crate) struct CqlConnection {
    endpoint: Arc<CqlEndpoint>,
    link: LinkSlot,
    calls: OwnedCalls,
    settings: WorkspaceSettings,
    server: ServerInfo,
    dialect: Arc<CqlDialect>,
    watch: LinkWatch,
    closed: AtomicBool,
}

impl CqlConnection {
    pub(crate) fn new(
        endpoint: Arc<CqlEndpoint>,
        link: CqlLink,
        settings: WorkspaceSettings,
        server: ServerInfo,
    ) -> Self {
        let grace = endpoint.liveness().cancel_grace;
        let dialect = Arc::new(CqlDialect::new(&server));
        Self {
            endpoint,
            link: LinkSlot::new(link),
            calls: OwnedCalls::new(grace),
            settings,
            server,
            dialect,
            watch: LinkWatch::new(),
            closed: AtomicBool::new(false),
        }
    }

    fn ensure_open(&self) -> Result<(), DriverError> {
        match self.closed.load(Ordering::SeqCst) {
            true => Err(DriverError::ConnectionLost {
                during: LossPhase::Idle,
            }),
            false => Ok(()),
        }
    }

    fn catalog_table(&self, table: &TableRef) -> Result<CatalogTable, DriverError> {
        let keyspace = table
            .schema
            .clone()
            .filter(|schema| !schema.is_empty())
            .or_else(|| self.endpoint.keyspace().map(str::to_owned))
            .ok_or_else(|| DriverError::server(format!("no keyspace names table {}", table.name)))?;
        Ok(CatalogTable {
            keyspace,
            name: table.name.clone(),
        })
    }

    /// A workspace call: one task under `OwnedCalls`, bounded by the
    /// workspace statement timeout as well as its own deadline. A stop
    /// drops the request at once (`call.rs`).
    async fn read<T, W, Fut>(&self, options: CallOptions, work: W) -> Result<T, DriverError>
    where
        T: Send + 'static,
        W: FnOnce(Arc<CqlLink>, StopRequest) -> Fut + Send + 'static,
        Fut: Future<Output = Result<T, DriverError>> + Send + 'static,
    {
        self.ensure_open()?;
        let link = self.link.get()?;
        let bounded = bounded(options, self.settings.statement_timeout);
        let outcome = self
            .calls
            .run_read(
                bounded,
                CqlCall::new(),
                Arc::new(CqlStop),
                move |call, request| async move {
                    let result = stoppable(&request, work(link, request.clone())).await;
                    (call, result)
                },
            )
            .await;
        self.settle(outcome).await
    }

    /// Decide whether a failed call means the link is gone. A request
    /// of its own answers within the cancel grace, so a dead route is
    /// reported within the call's deadline plus that grace.
    async fn settle<T>(&self, outcome: Result<T, DriverError>) -> Result<T, DriverError> {
        let error = match outcome {
            Ok(value) => return Ok(value),
            Err(error) => self.explained(error).await,
        };
        // A save reports its outcome around what stopped it.
        if !suspects_link(error.cause()) {
            return Err(error);
        }
        let checked = self.check(self.endpoint.liveness().cancel_grace).await;
        if !checked.is_err_and(|failure| means_link_lost(&failure)) {
            return Err(error);
        }
        self.watch.mark_lost();
        Err(match error {
            DriverError::Timeout { .. } => DriverError::ConnectionLost {
                during: LossPhase::Statement,
            },
            other => other,
        })
    }

    /// A trivial read on the session's connection, bounded by `within`.
    /// The connection multiplexes requests, so it waits for no slot.
    async fn check(&self, within: Duration) -> Result<(), DriverError> {
        let link = self.link.get()?;
        let probe = link.catalogue("SELECT now() FROM system.local", ());
        match tokio::time::timeout(within, probe).await {
            Ok(Ok(_)) => Ok(()),
            Ok(Err(error)) => Err(error),
            Err(_) => Err(DriverError::Timeout {
                phase: TimeoutPhase::Probe,
                server_cancelled: false,
            }),
        }
    }
}

impl CqlConnection {
    /// The transport's own reason where it has one, as the relay or the
    /// SSH master saw it.
    async fn explained(&self, error: DriverError) -> DriverError {
        match self.link.get() {
            Ok(link) => self.endpoint.explain(link.relay(), error).await,
            Err(_) => error,
        }
    }
}

/// `options` with its deadline no later than `timeout` from now.
fn bounded(options: CallOptions, timeout: Duration) -> CallOptions {
    let limit = Instant::now() + timeout;
    let deadline = options.deadline().map_or(limit, |deadline| deadline.min(limit));
    CallOptions::new(Some(deadline), options.cancel().clone())
}

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

fn means_link_lost(error: &DriverError) -> bool {
    matches!(
        error.category(),
        ErrorCategory::Network | ErrorCategory::ConnectionLost | ErrorCategory::Timeout
    )
}

#[async_trait]
impl Connection for CqlConnection {
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
        self.watch.state()
    }

    fn lost(&self) -> WaitForCancellationFutureOwned {
        self.watch.lost()
    }

    async fn probe(&self, options: CallOptions) -> Result<(), DriverError> {
        self.ensure_open()?;
        let deadline = options
            .deadline()
            .unwrap_or_else(|| Instant::now() + self.endpoint.liveness().probe_timeout);
        let within = deadline.saturating_duration_since(Instant::now());
        let outcome = tokio::select! {
            () = options.cancel().cancelled() => Err(DriverError::Cancelled),
            outcome = self.check(within) => outcome,
        };
        let outcome = match outcome {
            Err(error) => Err(self.explained(error).await),
            ok => ok,
        };
        if let Err(error) = &outcome
            && means_link_lost(error)
        {
            self.watch.mark_lost();
        }
        outcome
    }

    async fn list_schemas(&self, options: CallOptions) -> Result<Vec<SchemaInfo>, DriverError> {
        let default = self.endpoint.keyspace().map(str::to_owned);
        self.read(options, move |link, _| async move {
            catalog::list_schemas(&link, default.as_deref()).await
        })
        .await
    }

    async fn list_objects(&self, scope: &ObjectScope, options: CallOptions) -> Result<Vec<ObjectInfo>, DriverError> {
        let scope = scope.clone();
        let default = self.endpoint.keyspace().map(str::to_owned);
        self.read(options, move |link, _| async move {
            catalog::list_objects(&link, &scope, default.as_deref()).await
        })
        .await
    }

    async fn fetch_columns(&self, table: &TableRef, options: CallOptions) -> Result<Vec<ColumnInfo>, DriverError> {
        let table = self.catalog_table(table)?;
        self.read(options, move |link, _| async move {
            catalog::fetch_columns(&link, &table).await
        })
        .await
    }

    async fn fetch_indexes(&self, table: &TableRef, options: CallOptions) -> Result<Vec<IndexInfo>, DriverError> {
        let table = self.catalog_table(table)?;
        self.read(options, move |link, _| async move {
            catalog::fetch_indexes(&link, &table).await
        })
        .await
    }

    /// CQL has no foreign keys.
    async fn fetch_foreign_keys(
        &self,
        _table: &TableRef,
        _options: CallOptions,
    ) -> Result<Vec<ForeignKeyInfo>, DriverError> {
        self.ensure_open()?;
        Ok(Vec::new())
    }

    async fn fetch_inbound_foreign_keys(
        &self,
        _table: &TableRef,
        _options: CallOptions,
    ) -> Result<Vec<InboundForeignKey>, DriverError> {
        self.ensure_open()?;
        Ok(Vec::new())
    }

    async fn fetch_table_definition(
        &self,
        table: &TableRef,
        options: CallOptions,
    ) -> Result<TableDefinition, DriverError> {
        let catalog_table = self.catalog_table(table)?;
        let table = table.clone();
        let scylla = self.dialect.is_scylla();
        self.read(options, move |link, _| async move {
            catalog::fetch_table_definition(&link, &table, &catalog_table, scylla).await
        })
        .await
    }

    async fn row_identity(&self, table: &TableRef, options: CallOptions) -> Result<RowIdentity, DriverError> {
        let table = self.catalog_table(table)?;
        self.read(options, move |link, _| async move {
            catalog::row_identity(&link, &table).await
        })
        .await
    }

    /// CQL keeps no row count: `system.size_estimates` counts partitions,
    /// which say nothing of the rows in them.
    async fn table_estimate(&self, _table: &TableRef, _options: CallOptions) -> Result<TableEstimate, DriverError> {
        self.ensure_open()?;
        Ok(TableEstimate {
            rows: RowCountEstimate::Unknown,
            heap_blocks: None,
        })
    }

    async fn query_bound(
        &self,
        statement: &Statement,
        limit: RowLimit,
        options: CallOptions,
    ) -> Result<QueryResult, DriverError> {
        let statement = statement.clone();
        self.read(options, move |link, _| async move {
            bounded_read(&link, &statement, limit).await
        })
        .await
    }

    async fn query_server_page(
        &self,
        statement: &Statement,
        request: ServerPageRequest,
        options: CallOptions,
    ) -> Result<ServerPage, DriverError> {
        let statement = statement.clone();
        self.read(options, move |link, stop| async move {
            server_page(&link, &statement, request, &stop).await
        })
        .await
    }

    async fn count_rows(&self, statement: &Statement, options: CallOptions) -> Result<u64, DriverError> {
        let statement = statement.clone();
        self.read(options, move |link, _| async move {
            let rows = link
                .execute(&statement)
                .await?
                .into_rows_result()
                .map_err(|error| DriverError::Protocol(error.to_string()))?;
            let (count,): (i64,) = rows
                .single_row()
                .map_err(|error| DriverError::Protocol(error.to_string()))?;
            u64::try_from(count).map_err(|_| DriverError::Protocol(format!("the count returned {count}")))
        })
        .await
    }

    /// An export can take minutes, so only the caller's deadline and
    /// cancel bound it.
    async fn stream_read(
        &self,
        read: &ReadStatement,
        mut sink: Box<dyn ResultSink>,
        options: CallOptions,
    ) -> Result<StreamSummary, DriverError> {
        self.ensure_open()?;
        let read = read.clone();
        let link = self.link.get()?;
        let outcome = self
            .calls
            .run_read(
                options,
                CqlCall::new(),
                Arc::new(CqlStop),
                move |call, request| async move {
                    let result = stream(&link, &read, sink.as_mut(), &request).await;
                    (call, result)
                },
            )
            .await;
        self.settle(outcome).await
    }

    async fn write_batch(&self, batch: &WriteBatch, options: CallOptions) -> Result<WriteReport, DriverError> {
        self.ensure_open()?;
        precheck(batch, self.settings.read_only)?;
        let ledger = Arc::new(WriteLedger::new(WriteAtomicity::StatementByStatement));
        let batch = batch.clone();
        let link = self.link.get()?;
        let work_ledger = ledger.clone();
        let outcome = self
            .calls
            .run_write(
                options,
                CqlCall::new(),
                Arc::new(CqlStop),
                ledger,
                move |call, request| async move {
                    let result = perform(&link, &batch, &work_ledger, &request).await;
                    (call, result)
                },
            )
            .await;
        self.settle(outcome).await
    }

    /// CQL keeps no record of a write: there is no commit to ask about.
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
        let link = self.endpoint.open(self.endpoint.keyspace(), &cancel).await?;
        Ok(Arc::new(CqlEditorSession::new(
            link,
            self.settings.read_only,
            options.statement_timeout,
        )))
    }

    async fn close(&self) -> Result<(), DriverError> {
        if self.closed.swap(true, Ordering::SeqCst) {
            return Ok(());
        }
        self.calls.shutdown().await;
        self.link.release();
        Ok(())
    }
}

/// At most `limit` rows of a generated read, reading one more to say
/// whether there were more.
async fn bounded_read(link: &CqlLink, statement: &Statement, limit: RowLimit) -> Result<QueryResult, DriverError> {
    let wanted = limit.get().saturating_add(1);
    let mut paging = scylla::response::PagingState::start();
    let mut read: Option<ColumnsRead> = None;
    let mut rows = Vec::new();
    loop {
        let remaining = wanted - rows.len() as u64;
        let (result, response) = link
            .page(statement, page_size(remaining.min(MAX_PAGE_ROWS)), paging)
            .await?;
        let page = result
            .into_rows_result()
            .map_err(|error| DriverError::Protocol(error.to_string()))?;
        let columns = read.get_or_insert_with(|| ColumnsRead::of(page.column_specs()));
        rows.extend(columns.decode(&page)?);
        match next_state(response) {
            Some(next) if (rows.len() as u64) < wanted => paging = next,
            _ => break,
        }
    }
    let truncated = rows.len() as u64 > limit.get();
    rows.truncate(usize::try_from(limit.get()).unwrap_or(usize::MAX));
    let columns = read.map_or_else(|| Arc::from([]), |read| read.columns);
    Ok(QueryResult::new(columns, rows).truncated(truncated))
}
