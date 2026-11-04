use std::future::Future;
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering};
use std::time::Duration;

use async_trait::async_trait;
use tablepro_core::column::ColumnInfo;
use tablepro_core::ddl::{InboundForeignKey, OutboundForeignKey, TableDefinition};
use tablepro_core::dialect::SqlDialect;
use tablepro_core::keyspace::{KeyListing, KeyPage, KeyScan, KeyWindow};
use tablepro_core::meta::{IndexInfo, ObjectInfo, ObjectScope, RowIdentity, SchemaInfo, TableEstimate, TableRef};
use tablepro_core::statement::Statement;
use tablepro_core::{
    CallOptions, CommitResolution, CommitToken, Connection, DriverError, EditorSession, EditorSessionOptions,
    ErrorCategory, ForeignKeyInfo, LinkState, LinkWatch, LossPhase, OwnedCalls, QueryResult, ReadStatement, ResultSink,
    RowLimit, ServerInfo, StopRequest, StreamSummary, TimeoutPhase, UnsupportedFeature, WorkspaceSettings, WriteBatch,
    WriteReport,
};
use tokio::time::Instant;
use tokio_util::sync::{CancellationToken, WaitForCancellationFutureOwned};

use crate::dialect::RedisDialect;
use crate::editor_session::RedisEditorSession;
use crate::endpoint::RedisEndpoint;
use crate::link::{Link, command, stoppable};
use crate::workspace_link::{BetweenCommands, OwnLink, WorkspaceCall, WorkspaceLink};
use crate::{key_read, key_scan, stream_read};

/// A workspace's link to one Redis server: one multiplexed link behind
/// the sidebar's listing and every key read.
pub(crate) struct RedisConnection {
    endpoint: Arc<RedisEndpoint>,
    calls: OwnedCalls,
    workspace: Arc<WorkspaceLink>,
    settings: WorkspaceSettings,
    server: ServerInfo,
    dialect: Arc<RedisDialect>,
    link: LinkWatch,
    closed: AtomicBool,
}

fn no_tables<T>() -> Result<T, DriverError> {
    Err(DriverError::Unsupported {
        feature: UnsupportedFeature::Tables,
    })
}

impl RedisConnection {
    pub(crate) fn new(
        endpoint: Arc<RedisEndpoint>,
        first: Link,
        settings: WorkspaceSettings,
        server: ServerInfo,
    ) -> Self {
        let grace = endpoint.liveness().cancel_grace;
        Self {
            workspace: WorkspaceLink::new(endpoint.clone(), first),
            endpoint,
            calls: OwnedCalls::new(grace),
            settings,
            server,
            dialect: Arc::new(RedisDialect),
            link: LinkWatch::new(),
            closed: AtomicBool::new(false),
        }
    }

    fn ensure_open(&self) -> Result<(), DriverError> {
        if self.closed.load(Ordering::SeqCst) {
            return Err(DriverError::ConnectionLost {
                during: LossPhase::Idle,
            });
        }
        Ok(())
    }

    /// Run one workspace read on the shared link, on a task that outlives
    /// the caller. The read stops between commands, each of which is
    /// bounded, so its stop needs nothing sent to the server.
    async fn read<T, W, Fut>(&self, options: CallOptions, work: W) -> Result<T, DriverError>
    where
        T: Send + 'static,
        W: FnOnce(Link, StopRequest) -> Fut + Send + 'static,
        Fut: Future<Output = Result<T, DriverError>> + Send + 'static,
    {
        self.ensure_open()?;
        let call = WorkspaceCall::new(self.workspace.clone());
        let outcome = self
            .calls
            .run_read(
                options,
                call,
                Arc::new(BetweenCommands),
                move |mut call, request| async move {
                    let link = match stoppable(&request, call.link()).await {
                        Ok(link) => link,
                        Err(error) => return (call, Err(error)),
                    };
                    let result = work(link, request).await;
                    (call, result)
                },
            )
            .await;
        self.settle(outcome).await
    }

    /// Decide whether a failed call means the link itself is gone: a link
    /// of its own answers within the cancel grace, or the route is gone.
    async fn settle<T>(&self, outcome: Result<T, DriverError>) -> Result<T, DriverError> {
        let error = match outcome {
            Ok(value) => return Ok(value),
            Err(error) => self.endpoint.explain(error).await,
        };
        if !suspects_link(&error) {
            return Err(error);
        }
        let checked = self.check(self.endpoint.liveness().cancel_grace).await;
        if !checked.is_err_and(|failure| means_link_lost(&failure)) {
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

    /// A `PING` on a link of its own, which never waits behind the
    /// workspace's commands. Any reply is the server answering, a
    /// `NOPERM` from an ACL that grants reads but not `PING` included.
    async fn check(&self, bound: Duration) -> Result<(), DriverError> {
        let ping = async {
            let link = self.endpoint.open().await?;
            link.send(&command(&["PING"])).await.map(|_| ())
        };
        match tokio::time::timeout(bound, ping).await {
            Ok(outcome) => outcome,
            Err(_) => Err(DriverError::Timeout {
                phase: TimeoutPhase::Probe,
                server_cancelled: false,
            }),
        }
    }
}

/// A failure that may mean the route is gone rather than one command.
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
impl Connection for RedisConnection {
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
            .unwrap_or_else(|| Instant::now() + self.endpoint.liveness().probe_timeout);
        let bound = deadline.saturating_duration_since(Instant::now());
        let outcome = tokio::select! {
            () = options.cancel().cancelled() => Err(DriverError::Cancelled),
            outcome = self.check(bound) => outcome,
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

    /// A key-value engine has no schemas: its keys come from `scan_keys`.
    async fn list_schemas(&self, _options: CallOptions) -> Result<Vec<SchemaInfo>, DriverError> {
        self.ensure_open()?;
        Ok(Vec::new())
    }

    async fn list_objects(&self, _scope: &ObjectScope, _options: CallOptions) -> Result<Vec<ObjectInfo>, DriverError> {
        self.ensure_open()?;
        Ok(Vec::new())
    }

    async fn fetch_columns(&self, _table: &TableRef, _options: CallOptions) -> Result<Vec<ColumnInfo>, DriverError> {
        no_tables()
    }

    async fn fetch_indexes(&self, _table: &TableRef, _options: CallOptions) -> Result<Vec<IndexInfo>, DriverError> {
        no_tables()
    }

    async fn fetch_foreign_keys(
        &self,
        _table: &TableRef,
        _options: CallOptions,
    ) -> Result<Vec<ForeignKeyInfo>, DriverError> {
        no_tables()
    }

    async fn fetch_outbound_foreign_keys(
        &self,
        _table: &TableRef,
        _options: CallOptions,
    ) -> Result<Vec<OutboundForeignKey>, DriverError> {
        no_tables()
    }

    async fn fetch_inbound_foreign_keys(
        &self,
        _table: &TableRef,
        _options: CallOptions,
    ) -> Result<Vec<InboundForeignKey>, DriverError> {
        no_tables()
    }

    async fn fetch_table_definition(
        &self,
        _table: &TableRef,
        _options: CallOptions,
    ) -> Result<TableDefinition, DriverError> {
        no_tables()
    }

    async fn row_identity(&self, _table: &TableRef, _options: CallOptions) -> Result<RowIdentity, DriverError> {
        no_tables()
    }

    async fn table_estimate(&self, _table: &TableRef, _options: CallOptions) -> Result<TableEstimate, DriverError> {
        no_tables()
    }

    async fn query_bound(
        &self,
        _statement: &Statement,
        _limit: RowLimit,
        _options: CallOptions,
    ) -> Result<QueryResult, DriverError> {
        no_tables()
    }

    async fn count_rows(&self, _statement: &Statement, _options: CallOptions) -> Result<u64, DriverError> {
        no_tables()
    }

    /// On a link of its own, so a long export holds up nothing else.
    async fn stream_read(
        &self,
        read: &ReadStatement,
        mut sink: Box<dyn ResultSink>,
        options: CallOptions,
    ) -> Result<StreamSummary, DriverError> {
        self.ensure_open()?;
        let read = read.clone();
        let endpoint = self.endpoint.clone();
        let outcome = self
            .calls
            .run_read(
                options,
                OwnLink::new(),
                Arc::new(BetweenCommands),
                move |call, request| async move {
                    let result = stream_read::stream(&endpoint, &read, sink.as_mut(), &request).await;
                    (call, result)
                },
            )
            .await;
        self.settle(outcome).await
    }

    /// The app saves nothing to a key-value engine but what the editor
    /// sends.
    async fn write_batch(&self, _batch: &WriteBatch, _options: CallOptions) -> Result<WriteReport, DriverError> {
        no_tables()
    }

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
        let opened = RedisEditorSession::open(self.endpoint.clone(), self.settings.read_only, options, cancel).await;
        match opened {
            Ok(session) => Ok(session),
            Err(error) => Err(self.endpoint.explain(error).await),
        }
    }

    async fn close(&self) -> Result<(), DriverError> {
        if self.closed.swap(true, Ordering::SeqCst) {
            return Ok(());
        }
        self.calls.shutdown().await;
        self.workspace.close().await;
        Ok(())
    }

    async fn scan_keys(&self, scan: &KeyScan, options: CallOptions) -> Result<KeyListing, DriverError> {
        let scan = scan.clone();
        self.read(options, move |link, stop| async move {
            key_scan::scan_keys(&link, &scan, &stop).await
        })
        .await
    }

    async fn read_key(
        &self,
        key: &str,
        window: &KeyWindow,
        options: CallOptions,
    ) -> Result<Option<KeyPage>, DriverError> {
        let (key, window) = (key.to_owned(), window.clone());
        self.read(options, move |link, stop| async move {
            key_read::read_key(&link, &key, &window, &stop).await
        })
        .await
    }
}
