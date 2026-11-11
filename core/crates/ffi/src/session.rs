use std::sync::Arc;

use tablepro_core::EditorSessionOptions;
use tablepro_core::browse::{PageRequest, PagingMode, SortKey, build_count, build_page, paging_mode};
use tablepro_core::filter::FilterSet;
use tablepro_core::meta::{PagePosition, TableRef};
use tablepro_core::sql_syntax::{SortReference, sort_reference, with_order_by};
use tablepro_session::runtime::Tasks;
use tablepro_session::{FailureCause, MonitorSignal, OperationError, OperationKind, Session, SessionHealth};

use crate::cancel_token::{CancelToken, token};
use crate::catalog::{ColumnEntry, ObjectEntry, ObjectScopeArg, SchemaEntry, TableName};
use crate::editor::QueryEditor;
use crate::error::{BoxedErrorInfo, CoreError};
use crate::library::SafeModeTag;
use crate::row_edits::TableEditor;
use crate::runtime::on_runtime;
use crate::safe_mode_gate::{self, RunGate};
use crate::statement_at::{self, StatementSpan};

#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Record)]
pub struct ColumnSort {
    pub column: u32,
    pub ascending: bool,
}

// Row-address columns may follow the visible ones. An engine that pages on the server cannot seek past page one.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct TableQuery {
    pub sql: String,
    pub visible_columns: u32,
    pub can_seek: bool,
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

    // The page starts offset rows in, so the statement binds nothing and runs as editor text.
    pub async fn table_query(
        &self,
        table: TableName,
        sort: Option<ColumnSort>,
        limit: u64,
        offset: u64,
        cancel: Option<Arc<CancelToken>>,
    ) -> Result<TableQuery, CoreError> {
        let session = self.session.clone();
        let cancel = token(cancel);
        on_runtime(&self.tasks, async move {
            let table: TableRef = table.into();
            let columns = tokio::select! {
                biased;
                () = cancel.cancelled() => return Err(CoreError::Cancelled),
                columns = session.columns(table.clone()) => columns?,
            };
            let identity = session
                .run_cancellable(OperationKind::Metadata, &cancel, |lease, options| {
                    let table = table.clone();
                    async move { Ok(lease.row_identity(&table, options).await?) }
                })
                .await?;
            let dialect = session.current_dialect().ok_or_else(not_connected)?;
            let sort: Vec<SortKey> = sort
                .map(|sort| SortKey {
                    column: sort.column as usize,
                    ascending: sort.ascending,
                })
                .into_iter()
                .collect();
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
            let spec = build_page(
                &*dialect,
                &PageRequest {
                    table: &table,
                    columns: &columns,
                    filter: &FilterSet::default(),
                    sort: &sort,
                    identity: &identity,
                    position: &position,
                    limit,
                },
            )
            .map_err(OperationError::from)?;
            if !spec.statement.params().is_empty() {
                return Err(CoreError::failed(
                    "ffi.bound_statement",
                    "the table's first page binds values",
                ));
            }
            Ok(TableQuery {
                sql: spec.statement.sql().to_owned(),
                visible_columns: u32::try_from(spec.visible_columns()).unwrap_or(u32::MAX),
                can_seek,
            })
        })
        .await
    }

    // Every row of the table, counted by the server, for the pager's last page.
    pub async fn table_row_count(&self, table: TableName, cancel: Option<Arc<CancelToken>>) -> Result<u64, CoreError> {
        let session = self.session.clone();
        let cancel = token(cancel);
        on_runtime(&self.tasks, async move {
            let table: TableRef = table.into();
            let columns = tokio::select! {
                biased;
                () = cancel.cancelled() => return Err(CoreError::Cancelled),
                columns = session.columns(table.clone()) => columns?,
            };
            Ok(session
                .run_cancellable(OperationKind::Count, &cancel, |lease, options| {
                    let table = table.clone();
                    let columns = columns.clone();
                    async move {
                        let statement = build_count(&*lease.dialect(), &table, &columns, &FilterSet::default())
                            .map_err(OperationError::from)?;
                        Ok(lease.count_rows(&statement, options).await?)
                    }
                })
                .await?)
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

fn not_connected() -> CoreError {
    CoreError::failed("ffi.not_connected", "the session has no connection")
}

impl std::fmt::Debug for DatabaseSession {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("DatabaseSession")
            .field("session", &self.session)
            .finish_non_exhaustive()
    }
}
