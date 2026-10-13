use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering};

use async_trait::async_trait;
use futures::future::BoxFuture;
use sqlx::sqlite::{SqliteConnectOptions, SqliteConnection as SqlxConnection, SqlitePool, SqlitePoolOptions};
use sqlx::{Connection as _, Executor as _};
use tablepro_core::ddl::TableDefinition;
use tablepro_core::dialect::SqlDialect;
use tablepro_core::meta::{IndexInfo, ObjectInfo, ObjectScope, RowIdentity, SchemaInfo, TableEstimate, TableRef};
use tablepro_core::statement::Statement;
use tablepro_core::{
    CallOptions, ColumnInfo, CommitResolution, CommitToken, Connection, DriverError, EditorSession,
    EditorSessionOptions, FileEndpoint, FileOpenMode, ForeignKeyInfo, LinkState, LinkWatch, LivenessPolicy, LossPhase,
    OwnedCalls, QueryResult, ReadOnlyRefusal, ReadStatement, ResultSink, RowLimit, ServerInfo, StreamSummary,
    TimeoutPhase, WorkspaceSettings, WriteAtomicity, WriteBatch, WriteKind, WriteLedger, WriteReport,
};
use tokio::time::Instant;
use tokio_util::sync::{CancellationToken, WaitForCancellationFutureOwned};

use crate::catalog::{SqliteVersion, check_runtime_version};
use crate::create_file::create_or_replace;
use crate::deadline;
use crate::dialect::SqliteDialect;
use crate::driver::WORKSPACE_POOL_MAX_SIZE;
use crate::editor_session::SqliteEditorSession;
use crate::errors::{map_error, map_open_error};
use crate::interrupt::{InterruptFlag, SqliteStop};
use crate::metadata;
use crate::open::connect_options;
use crate::result_stream::{collect, count, run_bound, run_script};
use crate::sqlite_pooled::SqlitePooled;
use crate::sqlite_standalone::SqliteStandalone;
use crate::write_batch;

/// The workspace's link to one database file.
///
/// Its pool holds one connection: SQLite takes one writer at a time
/// anyway, and a single connection keeps a temporary table or an
/// attached database where the next call can see it.
#[derive(Debug)]
pub(crate) struct SqliteConnection {
    pool: SqlitePool,
    path: PathBuf,
    settings: WorkspaceSettings,
    liveness: LivenessPolicy,
    server_info: ServerInfo,
    dialect: Arc<SqliteDialect>,
    calls: OwnedCalls,
    link: LinkWatch,
    closed: AtomicBool,
}

impl SqliteConnection {
    /// Open the file the endpoint names, creating it first when the
    /// user asked for a new database.
    pub(crate) async fn open(
        endpoint: &FileEndpoint,
        settings: WorkspaceSettings,
        liveness: LivenessPolicy,
    ) -> Result<Self, DriverError> {
        let path = endpoint.path().to_path_buf();
        if endpoint.mode() == FileOpenMode::CreateNew {
            let target = path.clone();
            tokio::task::spawn_blocking(move || create_or_replace(&target))
                .await
                .map_err(|error| DriverError::Protocol(format!("creating the database file stopped: {error}")))??;
        }
        let options = connect_options(&path, settings.read_only, settings.lock_timeout);
        let pool = SqlitePoolOptions::new()
            .max_connections(u32::try_from(WORKSPACE_POOL_MAX_SIZE).unwrap_or(1))
            .acquire_timeout(liveness.pool_wait)
            .connect_with(options)
            .await
            .map_err(|error| map_open_error(error, &path))?;

        let version = match check_file(&pool, &path).await {
            Ok(version) => version,
            Err(error) => {
                pool.close().await;
                return Err(error);
            }
        };
        let server_info = ServerInfo::new(
            "SQLite",
            version.to_string(),
            version.major,
            version.minor,
            version.patch,
        );
        Ok(Self {
            pool,
            path,
            settings,
            liveness,
            server_info,
            dialect: Arc::new(SqliteDialect::new(version)),
            calls: OwnedCalls::new(liveness.cancel_grace),
            link: LinkWatch::new(),
            closed: AtomicBool::new(false),
        })
    }

    fn options(&self, read_only: bool) -> SqliteConnectOptions {
        connect_options(&self.path, read_only, self.settings.lock_timeout)
    }

    fn ensure_open(&self) -> Result<(), DriverError> {
        match self.closed.load(Ordering::SeqCst) {
            true => Err(DriverError::ConnectionLost {
                during: LossPhase::Idle,
            }),
            false => Ok(()),
        }
    }

    /// SQLite has no statement timeout of its own, so the workspace's is
    /// a deadline the progress handler enforces.
    fn statement_bounded(&self, options: CallOptions) -> CallOptions {
        let bound = Instant::now() + self.settings.statement_timeout;
        CallOptions::new(
            deadline::earliest(options.deadline(), Some(bound)),
            options.cancel().clone(),
        )
    }

    /// Wait for the workspace connection, for as long as the pool wait
    /// and the call's own bounds allow.
    async fn acquire(&self, options: &CallOptions) -> Result<SqlitePooled, DriverError> {
        self.ensure_open()?;
        tokio::select! {
            biased;
            () = options.cancel().cancelled() => Err(DriverError::Cancelled),
            () = deadline::elapsed(options.deadline()) => Err(DriverError::Timeout {
                phase: TimeoutPhase::Statement,
                server_cancelled: false,
            }),
            acquired = self.pool.acquire() => acquired.map(SqlitePooled::new).map_err(map_error),
        }
    }

    async fn read<T, W>(&self, options: CallOptions, work: W) -> Result<T, DriverError>
    where
        T: Send + 'static,
        W: for<'c> FnOnce(&'c mut SqlxConnection) -> BoxFuture<'c, Result<T, DriverError>> + Send + 'static,
    {
        let options = self.statement_bounded(options);
        let pooled = self.acquire(&options).await?;
        self.run_on(options, pooled, work).await
    }

    /// Run one call's work on a connection the call holds, under the
    /// call's own stop.
    async fn run_on<T, W>(&self, options: CallOptions, pooled: SqlitePooled, work: W) -> Result<T, DriverError>
    where
        T: Send + 'static,
        W: for<'c> FnOnce(&'c mut SqlxConnection) -> BoxFuture<'c, Result<T, DriverError>> + Send + 'static,
    {
        let flag = InterruptFlag::new();
        let stop = Arc::new(SqliteStop::new(flag.clone()));
        let lock_timeout = self.settings.lock_timeout;
        self.calls
            .run_read(options, pooled, stop, move |mut pooled, _request| async move {
                let result = match flag.install(pooled.connection(), lock_timeout).await {
                    Ok(()) => work(pooled.connection()).await,
                    Err(error) => Err(error),
                };
                (pooled, result)
            })
            .await
    }

    /// With the workspace connection busy, the file is asked on a
    /// connection of the probe's own, which needs no lock to answer.
    async fn probe_standalone(&self, options: &CallOptions) -> Result<(), DriverError> {
        let options_for_probe = self.options(true);
        let probing = async {
            let mut connection = SqlxConnection::connect_with(&options_for_probe)
                .await
                .map_err(|error| map_open_error(error, &self.path))?;
            connection.execute("SELECT 1").await.map_err(map_error)?;
            connection.close().await.map_err(map_error)
        };
        tokio::select! {
            biased;
            () = options.cancel().cancelled() => Err(DriverError::Cancelled),
            () = deadline::elapsed(options.deadline()) => Err(DriverError::Timeout {
                phase: TimeoutPhase::Probe,
                server_cancelled: false,
            }),
            probed = probing => probed,
        }
    }

    async fn open_standalone(&self, options: &CallOptions) -> Result<SqlxConnection, DriverError> {
        let read_only = self.options(true);
        tokio::select! {
            biased;
            () = options.cancel().cancelled() => Err(DriverError::Cancelled),
            () = deadline::elapsed(options.deadline()) => Err(DriverError::Timeout {
                phase: TimeoutPhase::Statement,
                server_cancelled: false,
            }),
            opened = SqlxConnection::connect_with(&read_only) => opened.map_err(|error| map_open_error(error, &self.path)),
        }
    }
}

/// Read the file once, so a file that is not a database fails the
/// connect rather than the first browse, and refuse a library older
/// than the catalogue queries need.
async fn check_file(pool: &SqlitePool, path: &Path) -> Result<SqliteVersion, DriverError> {
    let version: String = sqlx::query_scalar("SELECT sqlite_version()")
        .fetch_one(pool)
        .await
        .map_err(map_error)?;
    let version = SqliteVersion::parse(&version)
        .ok_or_else(|| DriverError::Protocol(format!("SQLite reported version {version:?}")))?;
    check_runtime_version(&version)?;
    sqlx::query("SELECT count(*) FROM sqlite_schema")
        .execute(pool)
        .await
        .map_err(|error| map_open_error(error, path))?;
    Ok(version)
}

#[async_trait]
impl Connection for SqliteConnection {
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

    async fn probe(&self, options: CallOptions) -> Result<(), DriverError> {
        self.ensure_open()?;
        let probed = match self.pool.try_acquire() {
            Some(connection) => {
                let pooled = SqlitePooled::new(connection);
                self.run_on(options, pooled, |connection| {
                    Box::pin(async move { connection.execute("SELECT 1").await.map(|_| ()).map_err(map_error) })
                })
                .await
            }
            None => self.probe_standalone(&options).await,
        };
        // The connection's worker thread is gone, so nothing on this
        // link will answer again.
        if matches!(probed, Err(DriverError::ConnectionLost { .. })) {
            self.link.mark_lost();
        }
        probed
    }

    async fn list_schemas(&self, options: CallOptions) -> Result<Vec<SchemaInfo>, DriverError> {
        self.read(options, |connection| Box::pin(metadata::list_schemas(connection)))
            .await
    }

    async fn list_objects(&self, scope: &ObjectScope, options: CallOptions) -> Result<Vec<ObjectInfo>, DriverError> {
        let scope = scope.clone();
        self.read(options, move |connection| {
            Box::pin(async move { metadata::list_objects(connection, &scope).await })
        })
        .await
    }

    async fn fetch_columns(&self, table: &TableRef, options: CallOptions) -> Result<Vec<ColumnInfo>, DriverError> {
        let table = table.clone();
        self.read(options, move |connection| {
            Box::pin(async move { metadata::fetch_columns(connection, &table).await })
        })
        .await
    }

    async fn fetch_indexes(&self, table: &TableRef, options: CallOptions) -> Result<Vec<IndexInfo>, DriverError> {
        let table = table.clone();
        self.read(options, move |connection| {
            Box::pin(async move { metadata::fetch_indexes(connection, &table).await })
        })
        .await
    }

    async fn fetch_foreign_keys(
        &self,
        table: &TableRef,
        options: CallOptions,
    ) -> Result<Vec<ForeignKeyInfo>, DriverError> {
        let table = table.clone();
        self.read(options, move |connection| {
            Box::pin(async move { metadata::fetch_foreign_keys(connection, &table).await })
        })
        .await
    }

    async fn fetch_table_definition(
        &self,
        table: &TableRef,
        options: CallOptions,
    ) -> Result<TableDefinition, DriverError> {
        let table = table.clone();
        self.read(options, move |connection| {
            Box::pin(async move { metadata::fetch_table_definition(connection, &table).await })
        })
        .await
    }

    async fn row_identity(&self, table: &TableRef, options: CallOptions) -> Result<RowIdentity, DriverError> {
        let table = table.clone();
        self.read(options, move |connection| {
            Box::pin(async move { metadata::row_identity(connection, &table).await })
        })
        .await
    }

    async fn table_estimate(&self, table: &TableRef, options: CallOptions) -> Result<TableEstimate, DriverError> {
        let table = table.clone();
        self.read(options, move |connection| {
            Box::pin(async move { metadata::table_estimate(connection, &table).await })
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
        self.read(options, move |connection| {
            Box::pin(async move { collect(connection, &statement, Some(limit)).await })
        })
        .await
    }

    async fn count_rows(&self, statement: &Statement, options: CallOptions) -> Result<u64, DriverError> {
        let statement = statement.clone();
        self.read(options, move |connection| {
            Box::pin(async move { count(connection, &statement).await })
        })
        .await
    }

    async fn stream_read(
        &self,
        read: &ReadStatement,
        sink: Box<dyn ResultSink>,
        options: CallOptions,
    ) -> Result<StreamSummary, DriverError> {
        self.ensure_open()?;
        // Read-only at open, so user SQL that writes is refused by
        // SQLite itself for the whole read.
        let connection = self.open_standalone(&options).await?;
        let flag = InterruptFlag::new();
        let stop = Arc::new(SqliteStop::new(flag.clone()));
        let lock_timeout = self.settings.lock_timeout;
        let read = read.clone();
        let streamed = self
            .calls
            .run_read(
                options,
                SqliteStandalone::new(connection),
                stop,
                move |mut held, _request| async move {
                    let mut sink = sink;
                    let result = match flag.install(held.connection(), lock_timeout).await {
                        Ok(()) => match &read {
                            ReadStatement::Generated(statement) => {
                                run_bound(held.connection(), statement, sink.as_mut()).await
                            }
                            ReadStatement::User(sql) => {
                                run_script(held.connection(), sql.as_str(), None, sink.as_mut()).await
                            }
                        },
                        Err(error) => Err(error),
                    };
                    (held, result)
                },
            )
            .await?;
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
        // A schema change runs as long as it takes: a rebuild stopped
        // halfway by the statement timeout would only roll back.
        let options = match batch.kind {
            WriteKind::RowChanges => self.statement_bounded(options),
            WriteKind::SchemaChanges => options,
        };
        let pooled = self.acquire(&options).await?;
        let ledger = Arc::new(WriteLedger::new(WriteAtomicity::Transactional));
        let flag = InterruptFlag::new();
        let stop = Arc::new(SqliteStop::new(flag.clone()));
        let lock_timeout = self.settings.lock_timeout;
        let batch = batch.clone();
        let recorded = ledger.clone();
        self.calls
            .run_write(options, pooled, stop, ledger, move |mut pooled, request| async move {
                let result = write_batch::run(&mut pooled, &batch, &recorded, &flag, &request, lock_timeout).await;
                (pooled, result)
            })
            .await
    }

    /// SQLite commits on the local file, so a COMMIT never goes out over
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
        self.ensure_open()?;
        let session = SqliteEditorSession::open(
            &self.options(self.settings.read_only),
            &self.path,
            options,
            &self.liveness,
            self.settings.lock_timeout,
            cancel,
        )
        .await?;
        Ok(Arc::new(session))
    }

    async fn close(&self) -> Result<(), DriverError> {
        self.closed.store(true, Ordering::SeqCst);
        self.calls.shutdown().await;
        let _ = tokio::time::timeout(self.liveness.close_timeout, self.pool.close()).await;
        Ok(())
    }
}
