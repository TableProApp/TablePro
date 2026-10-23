use std::collections::{BTreeMap, BTreeSet};
use std::future::Future;
use std::pin::Pin;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex, PoisonError};
use std::time::Duration;

use async_trait::async_trait;
use bson::doc;
use mongodb::{Client, ClientSession};
use tablepro_core::column::{ColumnInfo, ColumnKind};
use tablepro_core::ddl::{
    ColumnAttributes, ColumnDefinition, InboundForeignKey, OutboundForeignKey, PrimaryKeyConstraint, TableDefinition,
};
use tablepro_core::dialect::SqlDialect;
use tablepro_core::meta::{IndexInfo, ObjectInfo, ObjectScope, RowIdentity, SchemaInfo, TableEstimate, TableRef};
use tablepro_core::sql_syntax::StatementAccess;
use tablepro_core::sql_syntax::mongo::access_of;
use tablepro_core::statement::Statement;
use tablepro_core::{
    CallOptions, CommitResolution, CommitToken, Connection, DriverError, EditorSession, EditorSessionOptions,
    ErrorCategory, ForeignKeyInfo, LinkState, LinkWatch, LossPhase, OwnedCalls, QueryResult, ReadOnlyRefusal,
    ReadStatement, ResultSink, RowLimit, ServerInfo, StopRequest, StreamSummary, TimeoutPhase, WorkspaceSettings,
    WriteAtomicity, WriteBatch, WriteLedger, WriteReport,
};
use tokio::time::Instant;
use tokio_util::sync::{CancellationToken, WaitForCancellationFutureOwned};

use crate::call::{ClientCall, KillState, SessionKill, generated, release, remaining_millis, session};
use crate::catalog::{CollectionType, Reader};
use crate::dialect::MongoDialect;
use crate::editor_session::MongoEditorSession;
use crate::endpoint::MongoEndpoint;
use crate::execute::{Source, start};
use crate::rows::collect;
use crate::write_batch::{WritePlan, perform, precheck};

/// A workspace call's work, which borrows the call's session.
type Work<'s, T> = Pin<Box<dyn Future<Output = Result<T, DriverError>> + Send + 's>>;

/// What a workspace call works with: the client, the endpoint that
/// explains its failures, and the server's time limit for the call.
pub(crate) struct CallContext {
    pub(crate) endpoint: Arc<MongoEndpoint>,
    pub(crate) client: Client,
    pub(crate) max_time: Option<i64>,
}

/// A workspace's link to one server: a client whose pool serves the
/// sidebar, the grid and every save, and a client of one connection that
/// the health probe owns.
pub(crate) struct MongoConnection {
    endpoint: Arc<MongoEndpoint>,
    client: Client,
    probe: Client,
    calls: OwnedCalls,
    settings: WorkspaceSettings,
    server: ServerInfo,
    database: String,
    dialect: Arc<MongoDialect>,
    link: LinkWatch,
    closed: AtomicBool,
    /// Each collection's fields that its columns show as JSON, from the
    /// last read of its fields, so a page or an export of it shows them
    /// as Extended JSON straight from the BSON, which keeps an `int`
    /// apart from a `long`.
    json_fields: Mutex<BTreeMap<(String, String), BTreeSet<String>>>,
}

impl MongoConnection {
    pub(crate) fn new(
        endpoint: Arc<MongoEndpoint>,
        client: Client,
        probe: Client,
        settings: WorkspaceSettings,
        server: ServerInfo,
        database: String,
    ) -> Self {
        Self {
            calls: OwnedCalls::new(endpoint.cancel_grace()),
            endpoint,
            client,
            probe,
            settings,
            server,
            database,
            dialect: Arc::new(MongoDialect),
            link: LinkWatch::new(),
            closed: AtomicBool::new(false),
            json_fields: Mutex::new(BTreeMap::new()),
        }
    }

    fn remember_json_fields(&self, database: String, collection: String, columns: &[ColumnInfo]) {
        let fields = columns
            .iter()
            .filter(|column| matches!(column.column_type.kind, ColumnKind::Json { .. }))
            .map(|column| column.name.clone())
            .collect();
        self.json_fields
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .insert((database, collection), fields);
    }

    /// The JSON fields of the collection a plan reads.
    fn json_fields_of(&self, planned: &crate::shell_command::Plan) -> BTreeSet<String> {
        let Some((database, collection)) = planned.collection() else {
            return BTreeSet::new();
        };
        self.json_fields
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .get(&(database.to_owned(), collection.to_owned()))
            .cloned()
            .unwrap_or_default()
    }

    fn ensure_open(&self) -> Result<(), DriverError> {
        if self.closed.load(Ordering::SeqCst) {
            return Err(DriverError::ConnectionLost {
                during: LossPhase::Idle,
            });
        }
        Ok(())
    }

    fn database_of(&self, table: &TableRef) -> String {
        table.schema.clone().unwrap_or_else(|| self.database.clone())
    }

    /// Run one workspace read on a task that outlives the caller, in a
    /// logical session of its own that the stop ends.
    async fn read<T, W>(&self, options: CallOptions, work: W) -> Result<T, DriverError>
    where
        T: Send + 'static,
        W: for<'s> FnOnce(CallContext, &'s mut ClientSession) -> Work<'s, T> + Send + 'static,
    {
        self.ensure_open()?;
        let kill = SessionKill::new();
        let context = CallContext {
            endpoint: self.endpoint.clone(),
            client: self.client.clone(),
            max_time: remaining_millis(options.deadline()),
        };
        let armed = kill.clone();
        let stop = kill.clone();
        let outcome = self
            .calls
            .run_read(options, ClientCall::new(), kill, move |call, request| async move {
                let mut session = match session(&context.endpoint, &context.client, &armed).await {
                    Ok(session) => session,
                    Err(error) => return (call, Err(error)),
                };
                let result = match request.is_requested() {
                    true => Err(DriverError::Cancelled),
                    false => work(context, &mut session).await,
                };
                release(session, &armed);
                (call, result)
            })
            .await;
        self.settle(outcome, &stop).await
    }

    /// Decide whether a failed call means the link itself is gone. A kill
    /// that never came back means the route is gone, and one the server
    /// answered means it is not; with no kill sent, the probe's own
    /// connection answers within the cancel grace, or the route is gone.
    async fn settle<T>(&self, outcome: Result<T, DriverError>, stop: &SessionKill) -> Result<T, DriverError> {
        let error = match outcome {
            Ok(value) => return Ok(value),
            Err(error) => error,
        };
        if !suspects_link(&error) {
            return Err(error);
        }
        let lost = match stop.state() {
            KillState::Unanswered => true,
            KillState::Answered => false,
            KillState::NotSent => self
                .check(self.endpoint.cancel_grace())
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

    /// A `ping` on the probe's own connection, which never waits behind
    /// the workspace's calls.
    async fn check(&self, bound: Duration) -> Result<(), DriverError> {
        let admin = self.probe.database("admin");
        let ping = admin.run_command(doc! { "ping": 1_i32 });
        match tokio::time::timeout(bound, ping).await {
            Ok(Ok(_)) => Ok(()),
            Ok(Err(error)) => Err(self.endpoint.explain(&error, LossPhase::Idle).await),
            Err(_) => Err(DriverError::Timeout {
                phase: TimeoutPhase::Probe,
                server_cancelled: false,
            }),
        }
    }

    /// A generated statement's plan, refused when it is not a read on a
    /// connection held read-only.
    fn generated_read(&self, statement: &Statement) -> Result<crate::shell_command::Plan, DriverError> {
        let (parsed, mut planned) = generated(statement, &self.database)?;
        if self.settings.read_only && access_of(&parsed) != StatementAccess::Read {
            return Err(DriverError::ReadOnly(ReadOnlyRefusal::ClientGuard));
        }
        let json_fields = self.json_fields_of(&planned);
        planned.show_as_json(&json_fields);
        Ok(planned)
    }
}

/// A failure that may mean the route is gone rather than one call.
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
impl Connection for MongoConnection {
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
        if let Err(error) = &outcome
            && means_link_lost(error)
        {
            self.link.mark_lost();
        }
        outcome
    }

    async fn list_schemas(&self, options: CallOptions) -> Result<Vec<SchemaInfo>, DriverError> {
        let default = self.database.clone();
        self.read(options, move |context, session| {
            Box::pin(async move { reader(&context, session).databases(&default).await })
        })
        .await
    }

    async fn list_objects(&self, scope: &ObjectScope, options: CallOptions) -> Result<Vec<ObjectInfo>, DriverError> {
        let databases = match scope {
            ObjectScope::DefaultSchema => vec![self.database.clone()],
            ObjectScope::Schema(name) => vec![name.clone()],
            ObjectScope::AllSchemas => Vec::new(),
        };
        let default = self.database.clone();
        self.read(options, move |context, session| {
            Box::pin(async move {
                let mut reader = reader(&context, session);
                let databases = match databases.is_empty() {
                    true => reader
                        .databases(&default)
                        .await?
                        .into_iter()
                        .map(|schema| schema.name)
                        .collect(),
                    false => databases,
                };
                let mut objects = Vec::new();
                for database in databases {
                    objects.extend(reader.collections(&database).await?);
                }
                Ok(objects)
            })
        })
        .await
    }

    async fn fetch_columns(&self, table: &TableRef, options: CallOptions) -> Result<Vec<ColumnInfo>, DriverError> {
        let (database, collection) = (self.database_of(table), table.name.clone());
        let key = (database.clone(), collection.clone());
        let columns = self
            .read(options, move |context, session| {
                Box::pin(async move {
                    let mut reader = reader(&context, session);
                    let mut columns = reader.fields(&database, &collection).await?;
                    // A view takes no writes, and a time-series collection keeps
                    // no `_id` unique, so nothing names a document a save could
                    // reach.
                    if !reader.collection_type(&database, &collection).await?.keyed() {
                        for column in &mut columns {
                            column.primary_key = false;
                            column.default = tablepro_core::column::ColumnDefault::None;
                        }
                    }
                    Ok(columns)
                })
            })
            .await?;
        self.remember_json_fields(key.0, key.1, &columns);
        Ok(columns)
    }

    async fn fetch_indexes(&self, table: &TableRef, options: CallOptions) -> Result<Vec<IndexInfo>, DriverError> {
        let (database, collection) = (self.database_of(table), table.name.clone());
        self.read(options, move |context, session| {
            Box::pin(async move {
                let mut reader = reader(&context, session);
                match reader.collection_type(&database, &collection).await? {
                    CollectionType::View => Ok(Vec::new()),
                    CollectionType::Collection | CollectionType::TimeSeries => {
                        reader.indexes(&database, &collection).await
                    }
                }
            })
        })
        .await
    }

    /// MongoDB has no foreign keys.
    async fn fetch_foreign_keys(
        &self,
        _table: &TableRef,
        _options: CallOptions,
    ) -> Result<Vec<ForeignKeyInfo>, DriverError> {
        self.ensure_open()?;
        Ok(Vec::new())
    }

    async fn fetch_outbound_foreign_keys(
        &self,
        _table: &TableRef,
        _options: CallOptions,
    ) -> Result<Vec<OutboundForeignKey>, DriverError> {
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
        let (database, collection, table) = (self.database_of(table), table.name.clone(), table.clone());
        self.read(options, move |context, session| {
            Box::pin(async move {
                let mut reader = reader(&context, session);
                let mut columns = reader.fields(&database, &collection).await?;
                let kind = reader.collection_type(&database, &collection).await?;
                if !kind.keyed() {
                    for column in &mut columns {
                        column.primary_key = false;
                        column.default = tablepro_core::column::ColumnDefault::None;
                    }
                }
                let indexes = match kind {
                    CollectionType::View => Vec::new(),
                    CollectionType::Collection | CollectionType::TimeSeries => {
                        reader.indexes(&database, &collection).await?
                    }
                };
                Ok(TableDefinition {
                    table,
                    columns: columns
                        .into_iter()
                        .map(|info| ColumnDefinition::new(info, ColumnAttributes::default()))
                        .collect(),
                    primary_key: kind.keyed().then(|| PrimaryKeyConstraint {
                        name: Some("_id_".to_owned()),
                        columns: vec!["_id".to_owned()],
                    }),
                    indexes,
                    foreign_keys: Vec::new(),
                    inbound_foreign_keys: Vec::new(),
                    source: None,
                })
            })
        })
        .await
    }

    /// A document is named by its `_id`. A view's documents are named by
    /// nothing a write could reach, and a time-series collection keeps no
    /// `_id` unique, so their rows are read-only.
    async fn row_identity(&self, table: &TableRef, options: CallOptions) -> Result<RowIdentity, DriverError> {
        let (database, collection) = (self.database_of(table), table.name.clone());
        self.read(options, move |context, session| {
            Box::pin(async move {
                match reader(&context, session)
                    .collection_type(&database, &collection)
                    .await?
                    .keyed()
                {
                    false => Ok(RowIdentity::Unordered),
                    true => Ok(RowIdentity::UniqueKey {
                        columns: vec!["_id".to_owned()],
                    }),
                }
            })
        })
        .await
    }

    async fn table_estimate(&self, table: &TableRef, options: CallOptions) -> Result<TableEstimate, DriverError> {
        let (database, collection) = (self.database_of(table), table.name.clone());
        self.read(options, move |context, session| {
            Box::pin(async move { reader(&context, session).estimate(&database, &collection).await })
        })
        .await
    }

    async fn query_bound(
        &self,
        statement: &Statement,
        limit: RowLimit,
        options: CallOptions,
    ) -> Result<QueryResult, DriverError> {
        let mut planned = self.generated_read(statement)?;
        planned.limit_time(remaining_millis(options.deadline()));
        self.read(options, move |context, session| {
            Box::pin(async move {
                let source = start(&context.endpoint, &context.client, session, planned).await?;
                collect(&context.endpoint, source, session, limit).await
            })
        })
        .await
    }

    async fn count_rows(&self, statement: &Statement, options: CallOptions) -> Result<u64, DriverError> {
        let mut planned = self.generated_read(statement)?;
        planned.limit_time(remaining_millis(options.deadline()));
        self.read(options, move |context, session| {
            Box::pin(async move {
                match start(&context.endpoint, &context.client, session, planned).await? {
                    Source::Count(count) => Ok(count),
                    _ => Err(DriverError::Protocol("the count returned no number".to_owned())),
                }
            })
        })
        .await
    }

    /// On a client of its own, so a long export holds up nothing else.
    async fn stream_read(
        &self,
        read: &ReadStatement,
        mut sink: Box<dyn ResultSink>,
        options: CallOptions,
    ) -> Result<StreamSummary, DriverError> {
        self.ensure_open()?;
        let (read, endpoint, database) = (read.clone(), self.endpoint.clone(), self.database.clone());
        let json_fields = match &read {
            ReadStatement::Generated(statement) => generated(statement, &database)
                .map(|(_, planned)| self.json_fields_of(&planned))
                .unwrap_or_default(),
            ReadStatement::User(_) => BTreeSet::new(),
        };
        let kill = SessionKill::new();
        let armed = kill.clone();
        let stop = kill.clone();
        let outcome = self
            .calls
            .run_read(
                options,
                ClientCall::new(),
                kill,
                move |call, request: StopRequest| async move {
                    let result = crate::stream_read::stream(
                        &endpoint,
                        &database,
                        &read,
                        &json_fields,
                        sink.as_mut(),
                        &request,
                        &armed,
                    )
                    .await;
                    (call, result)
                },
            )
            .await;
        self.settle(outcome, &stop).await
    }

    async fn write_batch(&self, batch: &WriteBatch, options: CallOptions) -> Result<WriteReport, DriverError> {
        self.ensure_open()?;
        precheck(batch, self.settings.read_only)?;
        let ledger = Arc::new(WriteLedger::new(WriteAtomicity::StatementByStatement));
        let plan = WritePlan {
            batch: batch.clone(),
            ledger: ledger.clone(),
            endpoint: self.endpoint.clone(),
            client: self.client.clone(),
            database: self.database.clone(),
        };
        let kill = SessionKill::new();
        let armed = kill.clone();
        let stop = kill.clone();
        let outcome = self
            .calls
            .run_write(
                options,
                ClientCall::new(),
                kill,
                ledger,
                move |call, request| async move {
                    let result = match session(&plan.endpoint, &plan.client, &armed).await {
                        Ok(mut session) => {
                            let result = perform(&plan, &mut session, &request).await;
                            release(session, &armed);
                            result
                        }
                        Err(error) => Err(plan.ledger.failed(0, error, tablepro_core::SessionFate::RolledBack)),
                    };
                    (call, result)
                },
            )
            .await;
        self.settle(outcome, &stop).await
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
        let session = MongoEditorSession::open(
            self.endpoint.clone(),
            self.database.clone(),
            self.settings.read_only,
            options,
            cancel,
        )
        .await?;
        Ok(session)
    }

    async fn close(&self) -> Result<(), DriverError> {
        if self.closed.swap(true, Ordering::SeqCst) {
            return Ok(());
        }
        self.calls.shutdown().await;
        let bound = self.endpoint.liveness().close_timeout;
        let closing = async {
            self.client.clone().shutdown().immediate(true).await;
            self.probe.clone().shutdown().immediate(true).await;
        };
        let _ = tokio::time::timeout(bound, closing).await;
        Ok(())
    }
}

fn reader<'a>(context: &'a CallContext, session: &'a mut ClientSession) -> Reader<'a> {
    Reader {
        endpoint: &context.endpoint,
        client: &context.client,
        session,
        max_time: context.max_time,
    }
}
