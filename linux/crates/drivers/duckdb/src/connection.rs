use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex, PoisonError};

use async_trait::async_trait;
use tablepro_core::ddl::{InboundForeignKey, OutboundForeignKey, TableDefinition};
use tablepro_core::dialect::SqlDialect;
use tablepro_core::meta::{IndexInfo, ObjectInfo, ObjectScope, RowIdentity, SchemaInfo, TableEstimate, TableRef};
use tablepro_core::statement::Statement;
use tablepro_core::{
    CallOptions, ColumnInfo, CommitResolution, CommitToken, Connection, DriverError, EditorSession,
    EditorSessionOptions, FileEndpoint, ForeignKeyInfo, LinkState, LinkWatch, LivenessPolicy, LossPhase, OwnedCalls,
    QueryResult, ReadOnlyRefusal, ReadStatement, ResultSink, RowLimit, ServerInfo, SinkFlow, StopRequest,
    StreamSummary, TimeoutPhase, WorkspaceSettings, WriteAtomicity, WriteBatch, WriteKind, WriteLedger, WriteReport,
};
use tokio::time::Instant;
use tokio_util::sync::{CancellationToken, WaitForCancellationFutureOwned};

use crate::catalog;
use crate::dialect::DuckDbDialect;
use crate::editor_session::DuckDbEditorSession;
use crate::instance::{Instance, Link};
use crate::pool::{DuckCall, LinkPool, build_pool, probe_timeouts};
use crate::result_stream::{Events, StreamOutcome, batch, collect, controls_transaction, count, run_bound, run_script};
use crate::stop::DuckStop;
use crate::write_batch;

/// The workspace's link to one database file: a pool of connections to
/// the one database instance this process keeps for the file.
pub(crate) struct DuckDbConnection {
    /// Let go at close, so the file closes once no editor tab holds it.
    instance: Mutex<Option<Arc<Instance>>>,
    catalog: String,
    pool: LinkPool,
    settings: WorkspaceSettings,
    liveness: LivenessPolicy,
    server_info: ServerInfo,
    dialect: Arc<DuckDbDialect>,
    calls: OwnedCalls,
    link: LinkWatch,
    closed: AtomicBool,
}

impl DuckDbConnection {
    /// Open the file the endpoint names, creating it first when the user
    /// asked for a new database.
    pub(crate) async fn open(
        endpoint: &FileEndpoint,
        settings: WorkspaceSettings,
        liveness: LivenessPolicy,
        given_up: CancellationToken,
    ) -> Result<Self, DriverError> {
        let opening = endpoint.clone();
        let read_only = settings.read_only;
        let (instance, version) = blocking(move || {
            let instance = Instance::open(&opening, read_only, &given_up)?;
            let version = instance
                .link()?
                .connection
                .query_row("SELECT version()", [], |row| row.get::<_, String>(0))
                .map_err(crate::errors::map_error)?;
            Ok((instance, version))
        })
        .await?;
        let pool = build_pool(&instance, &liveness)?;
        Ok(Self {
            catalog: instance.catalog().to_owned(),
            instance: Mutex::new(Some(instance)),
            pool,
            settings,
            liveness,
            server_info: server_info(&version),
            dialect: Arc::new(DuckDbDialect::new()),
            calls: OwnedCalls::new(liveness.cancel_grace),
            link: LinkWatch::new(),
            closed: AtomicBool::new(false),
        })
    }

    fn ensure_open(&self) -> Result<(), DriverError> {
        self.instance().map(drop)
    }

    fn instance(&self) -> Result<Arc<Instance>, DriverError> {
        let held = self.instance.lock().unwrap_or_else(PoisonError::into_inner).clone();
        match (held, self.closed.load(Ordering::SeqCst)) {
            (Some(instance), false) => Ok(instance),
            _ => Err(DriverError::ConnectionLost {
                during: LossPhase::Idle,
            }),
        }
    }

    /// DuckDB has no statement timeout of its own, so the workspace's
    /// is a deadline its interrupt enforces.
    fn statement_bounded(&self, options: CallOptions) -> CallOptions {
        let bound = Instant::now() + self.settings.statement_timeout;
        let deadline = match options.deadline() {
            Some(deadline) => deadline.min(bound),
            None => bound,
        };
        CallOptions::new(Some(deadline), options.cancel().clone())
    }

    /// Run one workspace read on a pool slot, under the call's own stop.
    async fn read<T, W>(&self, options: CallOptions, work: W) -> Result<T, DriverError>
    where
        T: Send + 'static,
        W: FnOnce(&Link, &str) -> Result<T, DriverError> + Send + 'static,
    {
        self.ensure_open()?;
        let options = self.statement_bounded(options);
        let stop = Arc::new(DuckStop::new());
        let armed = stop.clone();
        let pool = self.pool.clone();
        let timeouts = pool.timeouts();
        let catalog = self.catalog.clone();
        let read = self
            .calls
            .run_read(options, DuckCall::new(), stop, move |mut call, request| async move {
                if let Err(error) = call.acquire(&pool, &timeouts, &request).await {
                    return (call, Err(error));
                }
                armed.arm(call.stop_handle());
                let result = call.run(Some(&request), move |link| work(link, &catalog)).await;
                (call, result)
            })
            .await;
        self.watch(read).await
    }

    /// A database that hit a fatal error refuses everything after it, so
    /// the link is gone for good. A call that lost its connection says so
    /// only when a connection of its own confirms it: one given up after a
    /// stop that did not settle leaves the database as it was.
    async fn watch<T>(&self, result: Result<T, DriverError>) -> Result<T, DriverError> {
        if matches!(result, Err(DriverError::ConnectionLost { .. }))
            && !self.closed.load(Ordering::SeqCst)
            && self.database_failed().await
        {
            self.link.mark_lost();
        }
        result
    }

    /// Whether the database refuses a new connection's `SELECT 1`, as it
    /// does after a fatal error. A check that gets no answer within the
    /// probe timeout proves nothing, and the caller is not held past it.
    async fn database_failed(&self) -> bool {
        let Ok(instance) = self.instance() else {
            return false;
        };
        let checking = blocking(move || batch(&instance.link()?, "SELECT 1"));
        matches!(
            tokio::time::timeout(self.liveness.probe_timeout, checking).await,
            Ok(Err(DriverError::ConnectionLost { .. }))
        )
    }

    /// A connection of the call's own, for a probe that found every slot
    /// busy and for a streamed read.
    async fn own_call(&self) -> Result<DuckCall, DriverError> {
        let instance = self.instance()?;
        blocking(move || instance.workspace_link()).await.map(DuckCall::own)
    }
}

fn server_info(version: &str) -> ServerInfo {
    let numbers: Vec<u32> = version
        .trim_start_matches('v')
        .split(|c: char| !c.is_ascii_digit())
        .filter_map(|part| part.parse().ok())
        .collect();
    let part = |index: usize| numbers.get(index).copied().unwrap_or(0);
    ServerInfo::new("DuckDB", version, part(0), part(1), part(2))
}

/// Run DuckDB work that blocks, off the async threads.
pub(crate) async fn blocking<T, W>(work: W) -> Result<T, DriverError>
where
    T: Send + 'static,
    W: FnOnce() -> Result<T, DriverError> + Send + 'static,
{
    tokio::task::spawn_blocking(work)
        .await
        .map_err(|error| DriverError::Protocol(format!("DuckDB work stopped: {error}")))?
}

/// Hand a run's events to `sink` while `produce` makes them on the
/// connection the call holds. A sink that goes stops the run.
pub(crate) async fn stream_into<P>(
    call: &mut DuckCall,
    request: Option<&StopRequest>,
    sink: &mut dyn ResultSink,
    produce: P,
) -> Result<StreamOutcome, DriverError>
where
    P: FnOnce(&Link, &mut Events) -> Result<StreamOutcome, DriverError> + Send + 'static,
{
    let (sender, mut receiver) = tokio::sync::mpsc::channel(2);
    let running = call.run(request, move |link| produce(link, &mut Events::new(sender)));
    let forwarding = async move {
        while let Some(event) = receiver.recv().await {
            if sink.accept(event).await == SinkFlow::ConsumerGone {
                return true;
            }
        }
        false
    };
    let (outcome, gone) = tokio::join!(running, forwarding);
    let mut outcome = outcome?;
    outcome.consumer_gone |= gone;
    Ok(outcome)
}

#[async_trait]
impl Connection for DuckDbConnection {
    fn server_info(&self) -> &ServerInfo {
        &self.server_info
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

    /// With every slot busy, the probe asks on a connection of its own.
    async fn probe(&self, options: CallOptions) -> Result<(), DriverError> {
        self.ensure_open()?;
        let call = match self.pool.timeout_get(&probe_timeouts(&self.liveness)).await {
            Ok(object) => DuckCall::pooled(object),
            Err(_) => self.own_call().await?,
        };
        let stop = Arc::new(DuckStop::new());
        stop.arm(call.stop_handle());
        let probed = self
            .calls
            .run_read(options, call, stop, |mut call, request| async move {
                let result = call.run(Some(&request), |link| batch(link, "SELECT 1")).await;
                (call, result)
            })
            .await;
        let probed = match probed {
            Err(DriverError::Timeout { .. }) => Err(DriverError::Timeout {
                phase: TimeoutPhase::Probe,
                server_cancelled: false,
            }),
            other => other,
        };
        self.watch(probed).await
    }

    async fn list_schemas(&self, options: CallOptions) -> Result<Vec<SchemaInfo>, DriverError> {
        self.read(options, catalog::list_schemas).await
    }

    async fn list_objects(&self, scope: &ObjectScope, options: CallOptions) -> Result<Vec<ObjectInfo>, DriverError> {
        let scope = scope.clone();
        self.read(options, move |link, catalog| {
            catalog::list_objects(link, catalog, &scope)
        })
        .await
    }

    async fn fetch_columns(&self, table: &TableRef, options: CallOptions) -> Result<Vec<ColumnInfo>, DriverError> {
        let table = table.clone();
        self.read(options, move |link, catalog| {
            catalog::fetch_columns(link, catalog, &table)
        })
        .await
    }

    async fn fetch_indexes(&self, table: &TableRef, options: CallOptions) -> Result<Vec<IndexInfo>, DriverError> {
        let table = table.clone();
        self.read(options, move |link, catalog| {
            catalog::fetch_indexes(link, catalog, &table)
        })
        .await
    }

    async fn fetch_foreign_keys(
        &self,
        table: &TableRef,
        options: CallOptions,
    ) -> Result<Vec<ForeignKeyInfo>, DriverError> {
        let table = table.clone();
        self.read(options, move |link, catalog| {
            catalog::fetch_foreign_keys(link, catalog, &table)
        })
        .await
    }

    async fn fetch_outbound_foreign_keys(
        &self,
        table: &TableRef,
        options: CallOptions,
    ) -> Result<Vec<OutboundForeignKey>, DriverError> {
        let table = table.clone();
        self.read(options, move |link, catalog| {
            catalog::outbound_foreign_keys(link, catalog, &table)
        })
        .await
    }

    async fn fetch_inbound_foreign_keys(
        &self,
        table: &TableRef,
        options: CallOptions,
    ) -> Result<Vec<InboundForeignKey>, DriverError> {
        let table = table.clone();
        self.read(options, move |link, catalog| {
            catalog::inbound_foreign_keys(link, catalog, &table)
        })
        .await
    }

    async fn fetch_table_definition(
        &self,
        table: &TableRef,
        options: CallOptions,
    ) -> Result<TableDefinition, DriverError> {
        let table = table.clone();
        // One transaction, so the parts come from the same moment.
        self.read(options, move |link, catalog| {
            batch(link, "BEGIN TRANSACTION READ ONLY")?;
            let definition = catalog::fetch_table_definition(link, catalog, &table);
            link.hold_stops();
            batch(link, "ROLLBACK")?;
            definition
        })
        .await
    }

    async fn row_identity(&self, table: &TableRef, options: CallOptions) -> Result<RowIdentity, DriverError> {
        let table = table.clone();
        self.read(options, move |link, catalog| {
            catalog::row_identity(link, catalog, &table)
        })
        .await
    }

    async fn table_estimate(&self, table: &TableRef, options: CallOptions) -> Result<TableEstimate, DriverError> {
        let table = table.clone();
        self.read(options, move |link, catalog| {
            catalog::table_estimate(link, catalog, &table)
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
        self.read(options, move |link, _| collect(link, &statement, Some(limit)))
            .await
    }

    async fn count_rows(&self, statement: &Statement, options: CallOptions) -> Result<u64, DriverError> {
        let statement = statement.clone();
        self.read(options, move |link, _| count(link, &statement)).await
    }

    /// Every row, on a connection of the read's own, inside a read-only
    /// transaction, so user SQL that writes is refused by DuckDB itself.
    async fn stream_read(
        &self,
        read: &ReadStatement,
        sink: Box<dyn ResultSink>,
        options: CallOptions,
    ) -> Result<StreamSummary, DriverError> {
        self.ensure_open()?;
        if let ReadStatement::User(sql) = read
            && controls_transaction(sql.as_str())
        {
            return Err(DriverError::ReadOnly(ReadOnlyRefusal::ClientGuard));
        }
        let call = self.own_call().await?;
        let stop = Arc::new(DuckStop::new());
        stop.arm(call.stop_handle());
        let read = read.clone();
        let streamed = self
            .calls
            .run_read(options, call, stop, move |mut call, request| async move {
                let mut sink = sink;
                let result = stream_into(&mut call, Some(&request), sink.as_mut(), move |link, events| {
                    batch(link, "BEGIN TRANSACTION READ ONLY")?;
                    let streamed = match &read {
                        ReadStatement::Generated(statement) => run_bound(link, statement, events),
                        ReadStatement::User(sql) => run_script(link, sql.as_str(), None, events, &|| false),
                    };
                    link.hold_stops();
                    let _ = batch(link, "ROLLBACK");
                    streamed
                })
                .await;
                (call, result)
            })
            .await;
        let streamed = self.watch(streamed).await?;
        // The sink stopped reading, so the read did not run to its end.
        if streamed.consumer_gone {
            return Err(DriverError::Cancelled);
        }
        Ok(StreamSummary::new(streamed.rows))
    }

    async fn write_batch(&self, batch: &WriteBatch, options: CallOptions) -> Result<WriteReport, DriverError> {
        if self.settings.read_only {
            return Err(DriverError::ReadOnly(ReadOnlyRefusal::ClientGuard));
        }
        if batch.is_empty() {
            return Ok(WriteReport::default());
        }
        batch.foreign_keys.require_enforced()?;
        self.ensure_open()?;
        // A schema change runs as long as it takes: one stopped halfway
        // by the statement timeout would only roll back.
        let options = match batch.kind {
            WriteKind::RowChanges => self.statement_bounded(options),
            WriteKind::SchemaChanges => options,
        };
        let ledger = Arc::new(WriteLedger::new(WriteAtomicity::Transactional));
        let recorded = ledger.clone();
        let stop = Arc::new(DuckStop::new());
        let armed = stop.clone();
        let pool = self.pool.clone();
        let timeouts = pool.timeouts();
        let batch = batch.clone();
        let written = self
            .calls
            .run_write(
                options,
                DuckCall::new(),
                stop,
                ledger,
                move |mut call, request| async move {
                    if let Err(error) = call.acquire(&pool, &timeouts, &request).await {
                        return (call, Err(error));
                    }
                    armed.arm(call.stop_handle());
                    let stopping = request.clone();
                    let outcome = call
                        .run(Some(&request), move |link| {
                            Ok(write_batch::run(link, &batch, &recorded, &stopping))
                        })
                        .await;
                    let result = match outcome {
                        Ok((result, reusable)) => {
                            if !reusable {
                                call.taint();
                            }
                            result
                        }
                        Err(error) => Err(error),
                    };
                    (call, result)
                },
            )
            .await;
        self.watch(written).await
    }

    /// DuckDB commits on the local file, so a COMMIT never goes out over
    /// a link that can fail, and there is no token to ask about.
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
        let session = DuckDbEditorSession::open(self.instance()?, options, &self.liveness, cancel).await?;
        Ok(Arc::new(session))
    }

    async fn close(&self) -> Result<(), DriverError> {
        self.closed.store(true, Ordering::SeqCst);
        self.calls.shutdown().await;
        self.pool.close();
        let instance = self.instance.lock().unwrap_or_else(PoisonError::into_inner).take();
        // DuckDB closes the file as the last connection to it goes, which
        // checkpoints it: not on an async thread.
        if let Some(instance) = instance {
            let _ = blocking(move || {
                drop(instance);
                Ok(())
            })
            .await;
        }
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// A call given up after a stop that did not settle synthesizes a
    /// lost connection, which leaves a healthy database's link live.
    #[tokio::test(flavor = "multi_thread", worker_threads = 2)]
    async fn a_lost_call_on_a_healthy_database_keeps_the_link() {
        let directory = tempfile::tempdir().unwrap();
        let endpoint = FileEndpoint::create_new(directory.path().join("live.duckdb")).unwrap();
        let liveness = tablepro_test_support::conformance::test_liveness();
        let connection = DuckDbConnection::open(
            &endpoint,
            WorkspaceSettings::workspace(false),
            liveness,
            CancellationToken::new(),
        )
        .await
        .unwrap();

        let lost: Result<(), DriverError> = Err(DriverError::ConnectionLost {
            during: LossPhase::Statement,
        });
        let _ = connection.watch(lost).await;

        assert_eq!(connection.link_state(), LinkState::Live);
        connection.close().await.unwrap();
    }

    #[test]
    fn the_version_reads_as_its_parts() {
        let info = server_info("v1.5.6");

        assert_eq!(info, ServerInfo::new("DuckDB", "v1.5.6", 1, 5, 6));
    }
}
