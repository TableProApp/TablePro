use std::sync::Arc;
use std::time::Instant;

use tablepro_core::browse::{PageRequest, PagingMode, SortKey, build_count, build_page, paging_mode, read_page};
use tablepro_core::filter::FilterSet;
use tablepro_core::meta::{ObjectInfo, ObjectScope, PagePosition, RowCountEstimate, RowIdentity, TableRef};
use tablepro_core::sql_syntax::{SortReference, sort_reference, with_order_by};
use tablepro_core::{ByteLimit, ColumnInfo, EditorSessionOptions, QueryResult, ResultEvent, ResultSink, Truncation};
use tablepro_session::runtime::{Tasks, catch_panic};
use tablepro_session::{FailureCause, MonitorSignal, OperationError, OperationKind, Session, SessionHealth};
use tokio_util::sync::CancellationToken;

use crate::cancel_token::{CancelToken, token};
use crate::catalog::{ColumnEntry, ObjectEntry, ObjectKindTag, ObjectScopeArg, SchemaEntry, TableName};
use crate::definition::ObjectSource;
use crate::editor::QueryEditor;
use crate::error::{BoxedErrorInfo, CoreError};
use crate::filter::{self, FilterChoices, TableFilterArg};
use crate::library::SafeModeTag;
use crate::row_edits::TableEditor;
use crate::run::{QueryRun, RunListener, RunOutcome, RunSink, RunState, TransactionStateTag};
use crate::runtime::on_runtime;
use crate::safe_mode_gate::{self, RunGate};
use crate::statement_at::{self, StatementSpan};
use crate::structure::{self, TableStructure};

#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Record)]
pub struct ColumnSort {
    pub column: u32,
    pub ascending: bool,
}

// Row-address columns may follow the visible ones. An engine that pages on the server cannot seek past page one.
#[derive(uniffi::Object)]
pub struct TablePageRead {
    run: Arc<QueryRun>,
    visible_columns: u32,
    can_seek: bool,
}

#[uniffi::export]
impl TablePageRead {
    pub fn run(&self) -> Arc<QueryRun> {
        self.run.clone()
    }

    pub fn visible_columns(&self) -> u32 {
        self.visible_columns
    }

    pub fn can_seek(&self) -> bool {
        self.can_seek
    }
}

impl std::fmt::Debug for TablePageRead {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("TablePageRead")
            .field("visible_columns", &self.visible_columns)
            .field("can_seek", &self.can_seek)
            .finish_non_exhaustive()
    }
}

// The engine's own idea of a table's rows, read from its statistics with no scan. Exact where it keeps the count.
#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum RowEstimate {
    Exact { rows: u64 },
    Approximate { rows: u64 },
    // No statistics for the table, as SQLite before ANALYZE.
    Unknown,
}

impl From<RowCountEstimate> for RowEstimate {
    fn from(estimate: RowCountEstimate) -> Self {
        match estimate {
            RowCountEstimate::Exact(rows) => Self::Exact { rows },
            RowCountEstimate::Approximate(rows) => Self::Approximate { rows },
            RowCountEstimate::Unknown => Self::Unknown,
        }
    }
}

// How the session's connection is doing. A reconnect replaces it on its own; a failed one waits for reconnect().
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Enum)]
pub enum SessionHealthTag {
    Online,
    Reconnecting {
        attempt: u32,
    },
    // The server is unreachable; it is checked again on a long timer.
    Offline,
    Failed {
        cause: FailureCauseTag,
        reason: Option<BoxedErrorInfo>,
    },
}

impl SessionHealthTag {
    // The reason a failure carries is read again on each call, so it does not tell two states apart.
    fn same_state(&self, other: &Self) -> bool {
        match (self, other) {
            (Self::Failed { cause, .. }, Self::Failed { cause: seen, .. }) => cause == seen,
            _ => self == other,
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum FailureCauseTag {
    Authentication,
    Tls,
    Configuration,
    HostKey,
}

// Each catalog level is read when first asked for and shared by every caller.
#[derive(uniffi::Object)]
pub struct DatabaseSession {
    session: Arc<Session>,
    tasks: Tasks,
}

impl DatabaseSession {
    pub(crate) fn new(session: Arc<Session>, tasks: Tasks) -> Self {
        Self { session, tasks }
    }
}

#[uniffi::export]
impl DatabaseSession {
    pub fn id(&self) -> String {
        self.session.id().to_string()
    }

    pub fn name(&self) -> String {
        self.session.metadata().name.clone()
    }

    pub fn driver_id(&self) -> String {
        self.session.metadata().driver_id.clone()
    }

    pub fn read_only(&self) -> bool {
        self.session.read_only()
    }

    pub async fn schemas(&self, cancel: Option<Arc<CancelToken>>) -> Result<Vec<SchemaEntry>, CoreError> {
        let session = self.session.clone();
        self.cancellable(cancel, async move {
            Ok(session.schemas().await?.iter().map(SchemaEntry::from).collect())
        })
        .await
    }

    pub async fn objects(
        &self,
        scope: ObjectScopeArg,
        cancel: Option<Arc<CancelToken>>,
    ) -> Result<Vec<ObjectEntry>, CoreError> {
        let session = self.session.clone();
        self.cancellable(cancel, async move {
            Ok(session
                .objects(scope.into())
                .await?
                .iter()
                .map(ObjectEntry::from)
                .collect())
        })
        .await
    }

    // For a change the catalog did not see, such as a table the editor created.
    pub async fn refresh_objects(
        &self,
        scope: ObjectScopeArg,
        cancel: Option<Arc<CancelToken>>,
    ) -> Result<Vec<ObjectEntry>, CoreError> {
        let session = self.session.clone();
        self.cancellable(cancel, async move {
            Ok(session
                .refresh_objects(scope.into())
                .await?
                .iter()
                .map(ObjectEntry::from)
                .collect())
        })
        .await
    }

    pub async fn columns(
        &self,
        table: TableName,
        cancel: Option<Arc<CancelToken>>,
    ) -> Result<Vec<ColumnEntry>, CoreError> {
        let session = self.session.clone();
        self.cancellable(cancel, async move {
            Ok(session
                .columns(table.into())
                .await?
                .iter()
                .map(ColumnEntry::from)
                .collect())
        })
        .await
    }

    // What the filter bar offers on this table, read from the catalog's columns and the engine's dialect.
    pub async fn filter_choices(
        &self,
        table: TableName,
        cancel: Option<Arc<CancelToken>>,
    ) -> Result<FilterChoices, CoreError> {
        let session = self.session.clone();
        self.cancellable(cancel, async move {
            let columns = session.columns(table.into()).await?;
            let dialect = session.current_dialect().ok_or_else(not_connected)?;
            Ok(filter::choices(&*dialect, &columns))
        })
        .await
    }

    // Returns once the page is built and its read started, so a bad filter fails the call; rows come as run events.
    #[expect(
        clippy::too_many_arguments,
        reason = "the page's table, sort, filter and window, the app's listener and its cancel, as the app passes them"
    )]
    pub async fn read_table_page(
        &self,
        table: TableName,
        sort: Option<ColumnSort>,
        filter: Option<TableFilterArg>,
        limit: u64,
        offset: u64,
        listener: Box<dyn RunListener>,
        cancel: Option<Arc<CancelToken>>,
    ) -> Result<Arc<TablePageRead>, CoreError> {
        let session = self.session.clone();
        let tasks = self.tasks.clone();
        let cancel = token(cancel);
        on_runtime(&self.tasks, async move {
            let dialect = session.current_dialect().ok_or_else(not_connected)?;
            let filter = filter::filter_set(filter, &*dialect)?;
            let plan = plan_page(&session, table, sort_keys(sort), filter, limit, offset, &cancel).await?;
            Ok(Arc::new(start_page(session, &tasks, plan, listener)))
        })
        .await
    }

    // Every row the filter selects, counted by the server, for the pager's last page.
    pub async fn table_row_count(
        &self,
        table: TableName,
        filter: Option<TableFilterArg>,
        cancel: Option<Arc<CancelToken>>,
    ) -> Result<u64, CoreError> {
        let session = self.session.clone();
        let cancel = token(cancel);
        on_runtime(&self.tasks, async move {
            let table: TableRef = table.into();
            let dialect = session.current_dialect().ok_or_else(not_connected)?;
            let filter = filter::filter_set(filter, &*dialect)?;
            let columns = tokio::select! {
                biased;
                () = cancel.cancelled() => return Err(CoreError::Cancelled),
                columns = session.columns(table.clone()) => columns?,
            };
            Ok(session
                .run_cancellable(OperationKind::Count, &cancel, |lease, options| {
                    let table = table.clone();
                    let columns = columns.clone();
                    let filter = filter.clone();
                    async move {
                        // Built before the count runs, so a filter the engine cannot take never reaches it.
                        let statement =
                            build_count(&*lease.dialect(), &table, &columns, &filter).map_err(OperationError::from)?;
                        Ok(lease.count_rows(&statement, options).await?)
                    }
                })
                .await?)
        })
        .await
    }

    // Of the whole table, so it says nothing exact about a filtered view; the app decides from it whether to count.
    pub async fn table_row_estimate(
        &self,
        table: TableName,
        cancel: Option<Arc<CancelToken>>,
    ) -> Result<RowEstimate, CoreError> {
        let session = self.session.clone();
        let cancel = token(cancel);
        on_runtime(&self.tasks, async move {
            let table: TableRef = table.into();
            let estimate = session
                .run_cancellable(OperationKind::Metadata, &cancel, |lease, options| {
                    let table = table.clone();
                    async move { Ok(lease.table_estimate(&table, options).await?) }
                })
                .await?;
            Ok(RowEstimate::from(estimate.rows))
        })
        .await
    }

    // The table as the server defines it now. `kind` decides whether a CREATE script belongs: a view gets none.
    pub async fn table_structure(
        &self,
        table: TableName,
        kind: ObjectKindTag,
        cancel: Option<Arc<CancelToken>>,
    ) -> Result<TableStructure, CoreError> {
        let session = self.session.clone();
        let cancel = token(cancel);
        on_runtime(&self.tasks, async move {
            let table: TableRef = table.into();
            // The catalog's kind wins over the app's, which a session saved before it was kept does not carry.
            let listed = tokio::select! {
                biased;
                () = cancel.cancelled() => return Err(CoreError::Cancelled),
                listed = catalog_kind(&session, &table) => listed,
            };
            let kind = listed.unwrap_or(kind);
            // The script is written in the dialect of the connection that read the definition.
            let (definition, dialect) = session
                .run_cancellable(OperationKind::Metadata, &cancel, |lease, options| {
                    let table = table.clone();
                    async move {
                        let definition = lease.fetch_table_definition(&table, options).await?;
                        Ok((definition, lease.dialect()))
                    }
                })
                .await?;
            Ok(structure::table_structure(&definition, &*dialect, kind))
        })
        .await
    }

    // None when the object is gone or the login cannot read its text, which servers do not tell apart.
    pub async fn object_definition(
        &self,
        object: ObjectEntry,
        cancel: Option<Arc<CancelToken>>,
    ) -> Result<Option<ObjectSource>, CoreError> {
        let object = ObjectInfo::try_from(object)?;
        let session = self.session.clone();
        let cancel = token(cancel);
        on_runtime(&self.tasks, async move {
            let definition = session
                .run_cancellable(OperationKind::Metadata, &cancel, |lease, options| {
                    let object = object.clone();
                    async move { Ok(lease.fetch_object_definition(&object, options).await?) }
                })
                .await?;
            Ok(definition.map(ObjectSource::from))
        })
        .await
    }

    pub fn health(&self) -> SessionHealthTag {
        health_tag(&self.session, &self.session.health().borrow())
    }

    // Waits until the health is no longer seen and returns it. Fails once the session is closed.
    pub async fn health_change(
        &self,
        seen: SessionHealthTag,
        cancel: Option<Arc<CancelToken>>,
    ) -> Result<SessionHealthTag, CoreError> {
        let session = self.session.clone();
        let cancel = token(cancel);
        on_runtime(&self.tasks, async move {
            let mut health = session.health();
            loop {
                let now = health_tag(&session, &health.borrow_and_update());
                if !now.same_state(&seen) {
                    return Ok(now);
                }
                tokio::select! {
                    biased;
                    () = cancel.cancelled() => return Err(CoreError::Cancelled),
                    changed = health.changed() => {
                        if changed.is_err() {
                            return Err(CoreError::failed("ffi.session_closed", "the session was closed"));
                        }
                    }
                }
            }
        })
        .await
    }

    // Connects again now, which is also the only way out of a failed health.
    pub fn reconnect(&self) {
        self.session.signal(MonitorSignal::RetryNow);
    }

    // None when the statement cannot run again or the engine can order by neither name nor position.
    pub fn sorted_query(
        &self,
        sql: String,
        columns: Vec<String>,
        column: u32,
        ascending: bool,
    ) -> Result<Option<String>, CoreError> {
        let dialect = self.session.current_dialect().ok_or_else(not_connected)?;
        let grammar = dialect.grammar();
        let Some(column) = usize::try_from(column).ok() else {
            return Ok(None);
        };
        let target = match sort_reference(&sql, grammar, &columns, column) {
            Some(SortReference::Name) => dialect.quote_identifier(&columns[column]),
            Some(SortReference::Position(position)) => position.to_string(),
            None => return Ok(None),
        };
        let direction = if ascending { "ASC" } else { "DESC" };
        Ok(with_order_by(&sql, grammar, &format!("{target} {direction}")))
    }

    // At the session's level now, read by the engine's own rules also while the session's link is down.
    pub fn gate_run(&self, sql: String) -> RunGate {
        safe_mode_gate::gate(&sql, self.session.grammar(), self.session.safe_mode())
    }

    // `caret` and the span count UTF-16 units. Split by the grammar `gate_run` and the driver read the text with.
    pub fn statement_at(&self, sql: String, caret: u32) -> Option<StatementSpan> {
        statement_at::statement_at(&sql, caret, self.session.grammar())
    }

    // A level saved while the session is open applies to it at once. False when `level` is on the other side of
    // Read-only, which takes a new connection; the session keeps its level until then.
    pub fn set_safe_mode(&self, level: SafeModeTag) -> bool {
        self.session.set_safe_mode(level.into())
    }

    // The table's rows as a save sees them, for a table tab that edits. `refresh` reads the catalog again, as a
    // tab's Refresh does, so the page that follows is read with the same columns.
    pub async fn table_editor(
        &self,
        table: TableName,
        refresh: bool,
        cancel: Option<Arc<CancelToken>>,
    ) -> Result<Arc<TableEditor>, CoreError> {
        TableEditor::open(self.session.clone(), self.tasks.clone(), table, refresh, cancel).await
    }

    pub async fn open_editor(&self, cancel: Option<Arc<CancelToken>>) -> Result<Arc<QueryEditor>, CoreError> {
        let session = self.session.clone();
        let tasks = self.tasks.clone();
        let cancel = token(cancel);
        on_runtime(&self.tasks, async move {
            let editor = session
                .open_editor_session(EditorSessionOptions::default(), &cancel)
                .await?;
            Ok(Arc::new(QueryEditor::new(editor, tasks)))
        })
        .await
    }

    // Editors opened from it close on their own.
    pub async fn close(&self) -> Result<(), CoreError> {
        let closing = self.session.begin_shutdown();
        on_runtime(&self.tasks, async move {
            closing
                .await
                .map(|_| ())
                .map_err(|failure| CoreError::failed("ffi.close_failed", failure.to_string()))
        })
        .await
    }
}

impl DatabaseSession {
    pub(crate) fn session(&self) -> &Arc<Session> {
        &self.session
    }

    pub(crate) fn tasks(&self) -> &Tasks {
        &self.tasks
    }

    // A catalog read is shared, so a cancel abandons this caller's wait and leaves the read to finish for the others.
    async fn cancellable<T, F>(&self, cancel: Option<Arc<CancelToken>>, work: F) -> Result<T, CoreError>
    where
        T: Send + 'static,
        F: Future<Output = Result<T, CoreError>> + Send + 'static,
    {
        let cancel = token(cancel);
        on_runtime(&self.tasks, async move {
            tokio::select! {
                biased;
                () = cancel.cancelled() => Err(CoreError::Cancelled),
                done = work => done,
            }
        })
        .await
    }
}

fn health_tag(session: &Session, health: &SessionHealth) -> SessionHealthTag {
    match health {
        SessionHealth::Online => SessionHealthTag::Online,
        SessionHealth::Reconnecting { attempt } => SessionHealthTag::Reconnecting { attempt: *attempt },
        SessionHealth::Offline => SessionHealthTag::Offline,
        SessionHealth::Failed { cause } => SessionHealthTag::Failed {
            cause: match cause {
                FailureCause::Authentication => FailureCauseTag::Authentication,
                FailureCause::Tls => FailureCauseTag::Tls,
                FailureCause::Configuration => FailureCauseTag::Configuration,
                FailureCause::HostKeyUnknown | FailureCause::HostKeyChanged | FailureCause::HostKeyRevoked => {
                    FailureCauseTag::HostKey
                }
            },
            reason: session
                .last_rejection()
                .and_then(|rejection| match CoreError::from((*rejection).clone()) {
                    CoreError::Failed { info } => Some(info),
                    CoreError::Cancelled => None,
                }),
        },
    }
}

// The kind the catalog lists the table under, where the catalog has been read and holds it.
async fn catalog_kind(session: &Session, table: &TableRef) -> Option<ObjectKindTag> {
    let scope = match &table.schema {
        Some(schema) => ObjectScope::Schema(schema.clone()),
        None => ObjectScope::DefaultSchema,
    };
    let objects = session.objects(scope).await.ok()?;
    objects
        .iter()
        .find(|object| object.name == table.name && object.kind.is_browsable())
        .map(|object| ObjectKindTag::from(object.kind))
}

fn not_connected() -> CoreError {
    CoreError::failed("ffi.not_connected", "the session has no connection")
}

pub(crate) fn sort_keys(sort: Option<ColumnSort>) -> Vec<SortKey> {
    sort.map(|sort| SortKey {
        column: usize::try_from(sort.column).unwrap_or(usize::MAX),
        ascending: sort.ascending,
    })
    .into_iter()
    .collect()
}

// The read builds its SQL again from its own lease, so it is spelled for that server even after a reconnect.
struct PagePlan {
    table: TableRef,
    columns: Arc<[ColumnInfo]>,
    identity: RowIdentity,
    filter: FilterSet,
    sort: Vec<SortKey>,
    position: PagePosition,
    limit: u64,
    visible_columns: u32,
    can_seek: bool,
}

async fn plan_page(
    session: &Session,
    table: TableName,
    sort: Vec<SortKey>,
    filter: FilterSet,
    limit: u64,
    offset: u64,
    cancel: &CancellationToken,
) -> Result<PagePlan, CoreError> {
    let table: TableRef = table.into();
    let columns = tokio::select! {
        biased;
        () = cancel.cancelled() => return Err(CoreError::Cancelled),
        columns = session.columns(table.clone()) => columns?,
    };
    let identity = session
        .run_cancellable(OperationKind::Metadata, cancel, |lease, options| {
            let table = table.clone();
            async move { Ok(lease.row_identity(&table, options).await?) }
        })
        .await?;
    let dialect = session.current_dialect().ok_or_else(not_connected)?;
    let can_seek = paging_mode(dialect.table_paging(), &identity, &sort) != PagingMode::ServerPaging;
    if offset > 0 && !can_seek {
        return Err(CoreError::failed(
            "ffi.page_unsupported",
            "the engine reads a table only from its start",
        ));
    }
    let position = match offset {
        0 => PagePosition::First,
        rows => PagePosition::Offset(rows),
    };
    // Built once here, so a filter the engine cannot take fails the call and never reaches the server.
    let spec = build_page(
        &*dialect,
        &PageRequest {
            table: &table,
            columns: &columns,
            filter: &filter,
            sort: &sort,
            identity: &identity,
            position: &position,
            limit,
        },
    )
    .map_err(OperationError::from)?;
    Ok(PagePlan {
        visible_columns: u32::try_from(spec.visible_columns()).unwrap_or(u32::MAX),
        can_seek,
        table,
        columns,
        identity,
        filter,
        sort,
        position,
        limit,
    })
}

fn start_page(session: Arc<Session>, tasks: &Tasks, plan: PagePlan, listener: Box<dyn RunListener>) -> TablePageRead {
    let state = Arc::new(RunState::new(listener));
    let visible_columns = plan.visible_columns;
    let can_seek = plan.can_seek;
    let run = state.clone();
    drop(tasks.spawn_task(async move {
        let started = Instant::now();
        let outcome = match catch_panic(read_into(&session, &plan, &run)).await {
            Ok(Ok(())) => RunOutcome::Completed {
                elapsed_ms: u64::try_from(started.elapsed().as_millis()).unwrap_or(u64::MAX),
            },
            Ok(Err(error)) => RunOutcome::from(CoreError::from(error)),
            Err(panic) => RunOutcome::from(CoreError::failed(
                "ffi.panicked",
                format!("the page read panicked: {panic}"),
            )),
        };
        // A pooled connection reads the page, so no transaction of the user's is left open.
        run.finish(outcome, TransactionStateTag::Idle);
    }));
    TablePageRead {
        run: Arc::new(QueryRun::new(state, tasks.clone())),
        visible_columns,
        can_seek,
    }
}

// The run's cancel reaches the driver through the operation, so a cancel stops the statement on the server.
async fn read_into(session: &Session, plan: &PagePlan, state: &Arc<RunState>) -> Result<(), OperationError> {
    let read = session
        .run_cancellable(OperationKind::Page, &state.cancel, move |lease, options| async move {
            let request = PageRequest {
                table: &plan.table,
                columns: &plan.columns,
                filter: &plan.filter,
                sort: &plan.sort,
                identity: &plan.identity,
                position: &plan.position,
                limit: plan.limit,
            };
            read_page::<OperationError>(&*lease, &request, &options).await
        })
        .await?;
    // An engine that pages on the server hands back where more rows start, and only page one can be read here.
    let truncation = match read.result.truncated || (read.mode == PagingMode::ServerPaging && read.next.is_some()) {
        true => Truncation::ReadPastLimit,
        false => Truncation::Complete,
    };
    deliver(
        RunSink::new(state.clone(), ByteLimit::EDITOR_DEFAULT),
        read.result,
        truncation,
    )
    .await;
    Ok(())
}

async fn deliver(mut sink: RunSink, result: QueryResult, truncation: Truncation) {
    let retained = u64::try_from(result.rows.len()).unwrap_or(u64::MAX);
    sink.accept(ResultEvent::ResultSetStarted {
        columns: result.columns,
    })
    .await;
    if !result.rows.is_empty() {
        sink.accept(ResultEvent::Rows(result.rows)).await;
    }
    sink.accept(ResultEvent::ResultSetFinished {
        retained,
        total_rows: None,
        truncation,
    })
    .await;
}

impl std::fmt::Debug for DatabaseSession {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("DatabaseSession")
            .field("session", &self.session)
            .finish_non_exhaustive()
    }
}
