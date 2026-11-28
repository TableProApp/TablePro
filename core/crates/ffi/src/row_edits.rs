use std::sync::{Arc, Mutex, MutexGuard, PoisonError, Weak};

use tablepro_core::column::{ColumnDefault, ColumnInfo, ColumnKind, ResultColumn, TemporalZone};
use tablepro_core::dialect::SqlDialect;
use tablepro_core::edit::{
    CellInput, EditContext, EditParseError, ResultLock, new_draft_cell, parse_edit_text, read_only_reason,
    result_source, result_target, value_for_column,
};
use tablepro_core::edits::{
    RowKey, RowState, SaveOutcome, SaveSnapshot, StatementSource, TabChangeTracker, TrackedChanges, TrackerEdit,
    TrackerRejection, UnknownCause, pk_identity,
};
use tablepro_core::export::value_to_text;
use tablepro_core::meta::{RowIdentity, TableRef};
use tablepro_core::save::{ChangeSet, SavePlan, plan_save};
use tablepro_core::sql_syntax::StatementAccess;
use tablepro_core::statement::Statement;
use tablepro_core::value::same_value;
use tablepro_core::{
    CommitResolution, DriverError, ErrorCategory, SafeModeLevel, Value, WriteGate, WriteKind, WriteReport,
};
use tablepro_session::runtime::Tasks;
use tablepro_session::{OperationError, OperationKind, Session};

use crate::cancel_token::{CancelToken, token};
use crate::catalog::TableName;
use crate::error::{BoxedErrorInfo, CoreError};
use crate::results::{ResultSet, ResultStore, ValueKind};
use crate::runtime::on_runtime;

// What the user put in a cell. An empty text means what `parse_edit_text` says it means for the column.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Enum)]
pub enum CellEdit {
    Text { text: String },
    Null,
    // The server's value: an insert leaves the column out, an update sets it to DEFAULT.
    Default,
}

// Why no row of the table, of the page or of the query result can be changed.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Enum)]
pub enum EditLock {
    ReadOnlyConnection,
    NoPrimaryKey,
    // A key the page holds cannot be named exactly, such as a float or PostgreSQL's server text for a date.
    KeyUnreadable { column: String },
    // The page was read with other columns than the editor's catalog.
    ColumnsChanged,
    // A query result's statement is not one SELECT (core ADR 0015).
    NotOneSelect,
    // A join, a subquery or a CTE.
    MoreThanOneTable,
    // DISTINCT, GROUP BY or an aggregate, so a row is not one row of the table.
    Collapsed,
    // The driver traced no column to the statement's table: a view, a temporary table, or an engine that reports none.
    Untraced,
    // The result leaves out part of the table's primary key.
    KeyNotShown,
}

impl From<ResultLock> for EditLock {
    fn from(lock: ResultLock) -> Self {
        match lock {
            ResultLock::NotOneSelect => Self::NotOneSelect,
            ResultLock::MoreThanOneTable => Self::MoreThanOneTable,
            ResultLock::Collapsed => Self::Collapsed,
            ResultLock::Untraced => Self::Untraced,
            ResultLock::NoPrimaryKey => Self::NoPrimaryKey,
            ResultLock::KeyNotShown => Self::KeyNotShown,
            ResultLock::ColumnsChanged => Self::ColumnsChanged,
        }
    }
}

// The grid's rules: a saved row's key and a column the server fills are locked, a new row may set its key.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct EditColumnInfo {
    pub name: String,
    pub editable: bool,
    pub editable_in_new_row: bool,
    // What a new row holds until the user types: the server's value where it has one, else NULL.
    pub new_row: CellEdit,
    pub nullable: bool,
    pub primary_key: bool,
    pub takes_empty: bool,
    // A saved row's cell can be set to DEFAULT: a declared default, on an engine whose UPDATE takes one.
    pub takes_default: bool,
    // What the column holds, so the app can offer an editor for it, such as a toggle for a boolean.
    pub kind: ValueKind,
    // An enum's or a set's labels in the type's order; empty for every other column.
    pub labels: Vec<String>,
    // A MySQL SET: the value is any combination of the labels.
    pub multiple: bool,
    // A typed time or timestamp is refused without its offset, as for PostgreSQL's timestamptz.
    pub needs_offset: bool,
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Enum)]
pub enum EditStart {
    // The whole value, never the grid's cut text; empty for NULL.
    Editable { text: String, is_null: bool },
    ReadOnly,
}

// A pending cell as the grid draws it.
#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum PendingKind {
    Value,
    Null,
    Default,
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct PendingCell {
    pub kind: PendingKind,
    // The whole value as text, empty for NULL and DEFAULT.
    pub text: String,
}

// One pending cell of a data row, by its place in the result set.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct OverlayCell {
    pub row: u64,
    pub column: u32,
    pub cell: PendingCell,
}

// A new row's cells, one per table column, in the table's order.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct OverlayRow {
    pub cells: Vec<PendingCell>,
}

// The pending edits over one result set, keyed by place so the grid draws them with no key of its own.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct GridOverlay {
    pub cells: Vec<OverlayCell>,
    pub modified_rows: Vec<u64>,
    pub deleted_rows: Vec<u64>,
    // New rows after the data rows, oldest first.
    pub drafts: Vec<OverlayRow>,
}

// What changed after an edit, so the app updates its buttons without a second call.
#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Record)]
pub struct PendingSummary {
    pub pending_count: u64,
    pub added_rows: u64,
    pub has_changes: bool,
    pub can_undo: bool,
    pub can_redo: bool,
    // A save may have landed; saving again is refused until the tab is reloaded or the changes discarded.
    pub outcome_unknown: bool,
    pub saving: bool,
}

// One statement of a save, with the values it binds as they would be written, NULL included.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct PlannedStatement {
    pub sql: String,
    pub values: Vec<String>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum SaveGate {
    Run,
    // Safe Mode asks before every write: the statements are shown first.
    Confirm,
    Refuse,
}

// The plan a save would run now, for the confirm sheet and the delete question.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct SavePreview {
    pub statements: Vec<PlannedStatement>,
    pub gate: SaveGate,
    // How many rows the save deletes, for the delete question the app asks at every level.
    pub deletes: u64,
    pub is_empty: bool,
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Enum)]
pub enum RowSaveOutcome {
    Saved { rows: Option<u64> },
    // Nothing was written. `row` is the place of the row the save stopped at, when the engine said.
    RolledBack { error: BoxedErrorInfo, row: Option<u64> },
    // The save may have landed in part or in full; saving again could write it twice.
    Unknown { error: BoxedErrorInfo, row: Option<u64> },
}

// Why the tracker refused a save before anything was sent. The app words it.
fn rejection_error(rejection: TrackerRejection) -> CoreError {
    let message = match &rejection {
        TrackerRejection::OutcomeUnknown => "the last save's outcome is unknown; reload or discard first".to_owned(),
        TrackerRejection::AlreadySaving => "these changes are already being saved".to_owned(),
        TrackerRejection::ColumnsNotRead => "the table's columns have not been read yet".to_owned(),
        TrackerRejection::Build(error) => error.to_string(),
        TrackerRejection::ColumnsChanged(columns) => {
            format!("the edits to {} no longer fit the table", columns.join(", "))
        }
        TrackerRejection::KeyChanged => "the table's primary key changed after these edits were made".to_owned(),
    };
    CoreError::failed(rejection.code(), message)
}

// A table tab's rows, or a query result's, as the tracker keys them: by the primary key (ADR 0068). The editor holds
// the pending edits and undo; the app records edits by place, reads the overlay by place, and saves through here.
#[derive(uniffi::Object)]
pub struct TableEditor {
    session: Arc<Session>,
    tasks: Tasks,
    table: TableRef,
    // The columns a save writes, one per column of the rows; a query result's column that writes none is generated.
    columns: Arc<[ColumnInfo]>,
    identity: RowIdentity,
    lock: Option<EditLock>,
    layout: Layout,
    tracker: Mutex<TabChangeTracker>,
}

enum Layout {
    // A table tab's page holds the catalog's columns first, in the table's order.
    Page,
    // A query result keeps the columns it was read with; each writes the catalog column it traced to (core ADR 0015).
    // Edits name rows of that one result, so rows of another statement can never be keyed against this table.
    Result {
        read: Arc<[ResultColumn]>,
        rows: Weak<ResultStore>,
    },
}

impl TableEditor {
    pub(crate) async fn open(
        session: Arc<Session>,
        tasks: Tasks,
        table: TableName,
        refresh: bool,
        cancel: Option<Arc<CancelToken>>,
    ) -> Result<Arc<Self>, CoreError> {
        let cancel = token(cancel);
        let runtime = tasks.clone();
        on_runtime(&runtime, async move {
            let table: TableRef = table.into();
            let read = async {
                match refresh {
                    true => session.refresh_columns(table.clone()).await,
                    false => session.columns(table.clone()).await,
                }
            };
            let columns = tokio::select! {
                biased;
                () = cancel.cancelled() => return Err(CoreError::Cancelled),
                columns = read => columns?,
            };
            let lock = if session.read_only() {
                Some(EditLock::ReadOnlyConnection)
            } else if !columns.iter().any(|column| column.primary_key) {
                Some(EditLock::NoPrimaryKey)
            } else {
                None
            };
            Ok(Self::build(session, tasks, table, columns, lock, Layout::Page))
        })
        .await
    }

    // `sql` is the statement the result was read with. The table's columns are read again, so a result read after the
    // table changed locks rather than writes a column by its old place.
    pub(crate) async fn open_result(
        session: Arc<Session>,
        tasks: Tasks,
        sql: String,
        rows: Arc<ResultSet>,
        cancel: Option<Arc<CancelToken>>,
    ) -> Result<Arc<Self>, CoreError> {
        let cancel = token(cancel);
        let runtime = tasks.clone();
        on_runtime(&runtime, async move {
            let read = rows.result_columns();
            let held = Arc::downgrade(rows.store());
            let locked = |session, tasks, read: Arc<[ResultColumn]>, lock: EditLock| {
                Self::build(
                    session,
                    tasks,
                    TableRef::new(None, String::new()),
                    Arc::from([]),
                    Some(lock),
                    Layout::Result {
                        read,
                        rows: held.clone(),
                    },
                )
            };
            if session.read_only() {
                return Ok(locked(session, tasks, read, EditLock::ReadOnlyConnection));
            }
            let source = match result_source(&sql, session.grammar(), &read) {
                Ok(source) => source,
                Err(lock) => return Ok(locked(session, tasks, read, lock.into())),
            };
            let catalog = tokio::select! {
                biased;
                () = cancel.cancelled() => return Err(CoreError::Cancelled),
                columns = session.refresh_columns(source.table.clone()) => columns?,
            };
            let target = match result_target(&source, &read, &catalog) {
                Ok(target) => target,
                Err(lock) => return Ok(locked(session, tasks, read, lock.into())),
            };
            let columns = read
                .iter()
                .zip(&target.positions)
                .enumerate()
                .map(
                    |(index, (column, position))| match position.and_then(|position| catalog.get(position)) {
                        Some(info) => info.clone(),
                        None => unwritable(index, column),
                    },
                )
                .collect();
            Ok(Self::build(
                session,
                tasks,
                target.table,
                columns,
                None,
                Layout::Result { read, rows: held },
            ))
        })
        .await
    }

    fn build(
        session: Arc<Session>,
        tasks: Tasks,
        table: TableRef,
        columns: Arc<[ColumnInfo]>,
        lock: Option<EditLock>,
        layout: Layout,
    ) -> Arc<Self> {
        let identity = pk_identity(&columns);
        let mut tracker = TabChangeTracker::default();
        if lock.is_none() {
            let _ = tracker.set_target(tablepro_core::edits::SaveTarget {
                table: table.clone(),
                columns: columns.to_vec(),
            });
        }
        Arc::new(Self {
            session,
            tasks,
            table,
            columns,
            identity,
            lock,
            layout,
            tracker: Mutex::new(tracker),
        })
    }

    fn tracker(&self) -> MutexGuard<'_, TabChangeTracker> {
        self.tracker.lock().unwrap_or_else(PoisonError::into_inner)
    }

    fn column(&self, column: u32) -> Result<&ColumnInfo, CoreError> {
        usize::try_from(column)
            .ok()
            .and_then(|index| self.columns.get(index))
            .ok_or_else(|| CoreError::failed("edit.out_of_range", format!("no column {column}")))
    }

    fn require_unlocked(&self) -> Result<(), CoreError> {
        match &self.lock {
            None if self.session.read_only() => Err(lock_error(&EditLock::ReadOnlyConnection)),
            None => Ok(()),
            Some(lock) => Err(lock_error(lock)),
        }
    }

    // A page holds the catalog's columns first, which build_page lays out in the catalog's order; a query result is
    // the one the editor was opened on, sorted or not.
    fn check_layout(&self, set: &ResultSet, rows: &[ResultColumn]) -> Result<(), CoreError> {
        let same = match &self.layout {
            Layout::Page => {
                rows.len() >= self.columns.len()
                    && self
                        .columns
                        .iter()
                        .zip(rows)
                        .all(|(catalog, read)| catalog.name == read.name)
            }
            Layout::Result { read, rows: held } => {
                std::ptr::eq(held.as_ptr(), Arc::as_ptr(set.store()))
                    && rows.len() == read.len()
                    && read.iter().zip(rows).all(|(opened, now)| opened.name == now.name)
            }
        };
        match same {
            true => Ok(()),
            false => Err(CoreError::failed(
                "edit.columns_changed",
                "the rows were read with other columns than the table has now",
            )),
        }
    }

    fn key(&self, rows: &ResultSet, read: &[ResultColumn], row: u64) -> Result<Vec<Value>, CoreError> {
        let mut key = Vec::new();
        for (index, column) in self.columns.iter().enumerate().filter(|(_, column)| column.primary_key) {
            let value = key_value(rows, read, row, index, column).ok_or_else(|| {
                CoreError::failed(
                    "edit.key_unreadable",
                    format!(
                        "the key column {} of row {row} cannot be read back exactly",
                        column.name
                    ),
                )
            })?;
            key.push(value);
        }
        Ok(key)
    }

    // The stable key of a data row, read from its primary key so the edit survives a later sort, filter or page.
    fn row_key(&self, rows: &ResultSet, read: &[ResultColumn], row: u64) -> Result<RowKey, CoreError> {
        let key = self.key(rows, read, row)?;
        RowKey::from_pk_values(&key)
            .ok_or_else(|| CoreError::failed("edit.no_primary_key", "the table has no primary key"))
    }

    fn unreadable_key(&self, rows: &ResultSet, read: &[ResultColumn], row: u64) -> Option<String> {
        self.columns
            .iter()
            .enumerate()
            .filter(|(_, column)| column.primary_key)
            .find(|(index, column)| key_value(rows, read, row, *index, column).is_none())
            .map(|(_, column)| column.name.clone())
    }

    fn input(
        &self,
        column: &ColumnInfo,
        edit: &CellEdit,
        context: EditContext,
        read: Option<&Value>,
    ) -> Result<CellInput, CoreError> {
        let input = match edit {
            CellEdit::Text { text } => parse_edit_text(text, column, context, read).map_err(parse_error)?,
            CellEdit::Null if column.nullable => CellInput::Value(Value::Null),
            CellEdit::Null => return Err(parse_error(EditParseError::Required)),
            CellEdit::Default => CellInput::Default,
        };
        Ok(input)
    }

    fn check_cell(
        &self,
        dialect: Option<&dyn SqlDialect>,
        column: &ColumnInfo,
        edit: &CellEdit,
        new_row: bool,
        read: Option<&Value>,
    ) -> Result<CellInput, CoreError> {
        let open = match new_row {
            true => editable_in_new_row(column),
            false => editable(column),
        };
        if !open {
            return Err(parse_error(EditParseError::NotEditable(
                read_only_reason(&column.column_type.kind).unwrap_or(tablepro_core::edit::ReadOnlyReason::Undecodable),
            )));
        }
        if !new_row && matches!(edit, CellEdit::Default) && !takes_default(column, dialect) {
            return Err(CoreError::failed(
                "edit.no_default",
                format!("column {} has no default an update can set", column.name),
            ));
        }
        let context = match new_row {
            true => EditContext::InsertDraft,
            false => EditContext::UpdateRow,
        };
        self.input(column, edit, context, read)
    }

    // The value the row holds in `column` now, read as the catalog's type where the server text is exact.
    fn stored(&self, rows: &ResultSet, read: &[ResultColumn], row: u64, column: usize) -> Option<Value> {
        let info = self.columns.get(column)?;
        rows.stored_value(row, column)
            .and_then(|value| value_for_column(&value, &read.get(column)?.column_type, &info.column_type))
    }

    // The cells a new draft starts with: the server's value where it fills the column, else what a draft holds.
    fn new_draft(&self) -> Vec<CellInput> {
        self.columns.iter().map(new_draft_cell).collect()
    }

    // A copy of `row`: its key and the columns the server computes start as a new row's; the rest copy its value or
    // its pending edit.
    fn duplicate_cells(&self, rows: &ResultSet, read: &[ResultColumn], key: &RowKey) -> Vec<CellInput> {
        let tracker = self.tracker();
        let row = self.position_of(rows, read, key);
        self.columns
            .iter()
            .enumerate()
            .map(|(index, column)| {
                if column.primary_key || !editable_in_new_row(column) {
                    return new_draft_cell(column);
                }
                if let Some(input) = tracker.pending_input(key, index) {
                    return input;
                }
                match row.and_then(|row| self.stored(rows, read, row, index)) {
                    Some(value) => CellInput::Value(value),
                    None => new_draft_cell(column),
                }
            })
            .collect()
    }

    // Where `key` sits in `rows`, by reading each row's primary key; `None` when it is off this page.
    fn position_of(&self, rows: &ResultSet, read: &[ResultColumn], key: &RowKey) -> Option<u64> {
        if !matches!(key, RowKey::Persisted(_)) {
            return None;
        }
        (0..rows.row_count()).find(|row| self.row_key(rows, read, *row).is_ok_and(|found| &found == key))
    }

    fn summary(&self, tracker: &TabChangeTracker) -> PendingSummary {
        let state = tracker.pending_state();
        PendingSummary {
            pending_count: tracker.pending_count() as u64,
            added_rows: tracker.drafts().len() as u64,
            has_changes: tracker.pending_count() > 0,
            can_undo: tracker.can_undo(),
            can_redo: tracker.can_redo(),
            outcome_unknown: matches!(state, tablepro_core::edits::PendingState::OutcomeUnknown(_)),
            saving: matches!(state, tablepro_core::edits::PendingState::Saving),
        }
    }

    // The core outcome to settle on, plus the statement the engine stopped at, so the app can focus its row.
    fn classify(
        &self,
        written: Result<WriteReport, OperationError>,
        resolution: Option<Result<CommitResolution, OperationError>>,
    ) -> (SaveOutcome, Option<CoreError>, Option<usize>) {
        let error = match written {
            Ok(report) => {
                return (
                    SaveOutcome::Committed {
                        rows: report.total_rows(),
                    },
                    None,
                    None,
                );
            }
            Err(error) => error,
        };
        let info = CoreError::from(&error);
        let (outcome, step) = match &error {
            OperationError::Driver(driver) => match driver {
                DriverError::RolledBack { statement_index, .. }
                | DriverError::RowGuardFailed { statement_index, .. }
                | DriverError::GuardUnsupported { statement_index } => {
                    (SaveOutcome::RolledBack, Some(*statement_index))
                }
                DriverError::ReadOnly(_) => (SaveOutcome::RolledBack, None),
                DriverError::CommitOutcomeUnknown { token, .. } => match resolution {
                    Some(Ok(CommitResolution::Applied)) => (SaveOutcome::Committed { rows: None }, None),
                    Some(Ok(CommitResolution::NotApplied)) => (SaveOutcome::RolledBack, None),
                    _ => (
                        SaveOutcome::Unknown(UnknownCause::CommitAckLost { token: token.clone() }),
                        None,
                    ),
                },
                DriverError::PartiallyApplied { statement_index, .. } => (
                    SaveOutcome::Unknown(UnknownCause::PartiallyApplied),
                    Some(*statement_index),
                ),
                other => match other.category() {
                    ErrorCategory::Interrupted | ErrorCategory::Timeout | ErrorCategory::ConnectionLost => {
                        (SaveOutcome::Unknown(UnknownCause::Interrupted), None)
                    }
                    _ => (SaveOutcome::RolledBack, None),
                },
            },
            OperationError::Sql(_) | OperationError::Build(_) | OperationError::Browse(_) => {
                (SaveOutcome::RolledBack, None)
            }
            OperationError::Cancelled => (SaveOutcome::Unknown(UnknownCause::Interrupted), None),
            OperationError::Panicked(_) => (SaveOutcome::Unknown(UnknownCause::Panicked), None),
            OperationError::Closed => (SaveOutcome::Unknown(UnknownCause::Closed), None),
        };
        (outcome, Some(info), step)
    }

    // The grid place of the statement the save stopped at, from the change's source row.
    fn failed_row(
        &self,
        rows: &ResultSet,
        read: &[ResultColumn],
        plan: &SavePlan,
        changes: &TrackedChanges,
        statement_index: Option<usize>,
    ) -> Option<u64> {
        let change = plan.origin(statement_index?)?;
        match changes.source(change)? {
            StatementSource::Insert { draft_id } => {
                let tracker = self.tracker();
                let index = tracker.drafts().keys().position(|id| *id == draft_id)?;
                Some(rows.row_count() + index as u64)
            }
            StatementSource::Update { row_key } | StatementSource::Delete { row_key } => {
                self.position_of(rows, read, &row_key)
            }
        }
    }
}

#[uniffi::export]
impl TableEditor {
    // Read again on each call, since a reconnect can make the connection read-only.
    pub fn lock(&self) -> Option<EditLock> {
        match &self.lock {
            None if self.session.read_only() => Some(EditLock::ReadOnlyConnection),
            lock => lock.clone(),
        }
    }

    // Whether a copy of the row holds its values exactly. PostgreSQL's server text for a float, a time or money may not
    // name the stored value (core ADR 0015), so such a query result row is not duplicated; a table page's are typed.
    pub fn copies_exactly(&self, rows: Arc<ResultSet>, row: u64) -> bool {
        match &self.layout {
            Layout::Page => true,
            Layout::Result { read, .. } => copies_exactly(read, &self.columns, &rows, row),
        }
    }

    // The table a save writes, as the result's driver named it; None while a query result is locked.
    pub fn table(&self) -> Option<TableName> {
        (!self.table.name.is_empty()).then(|| TableName {
            schema: self.table.schema.clone(),
            name: self.table.name.clone(),
        })
    }

    // The page's own locks too: a lock here leaves every row of `rows` as it is.
    pub fn lock_for(&self, rows: Arc<ResultSet>) -> Option<EditLock> {
        if let Some(lock) = self.lock() {
            return Some(lock);
        }
        let read = rows.result_columns();
        if self.check_layout(&rows, &read).is_err() {
            return Some(EditLock::ColumnsChanged);
        }
        if rows.row_count() == 0 {
            return None;
        }
        self.unreadable_key(&rows, &read, 0)
            .map(|column| EditLock::KeyUnreadable { column })
    }

    pub fn columns(&self) -> Vec<EditColumnInfo> {
        let dialect = self.session.current_dialect();
        self.columns
            .iter()
            .enumerate()
            .map(|(index, column)| EditColumnInfo {
                name: match &self.layout {
                    Layout::Result { read, .. } => read.get(index).map_or_else(String::new, |read| read.name.clone()),
                    Layout::Page => column.name.clone(),
                },
                editable: editable(column),
                editable_in_new_row: editable_in_new_row(column),
                new_row: match new_draft_cell(column) {
                    CellInput::Value(Value::Null) => CellEdit::Null,
                    _ => CellEdit::Default,
                },
                nullable: column.nullable,
                primary_key: column.primary_key,
                takes_empty: column.column_type.kind.accepts_empty_string(),
                takes_default: takes_default(column, dialect.as_deref()),
                kind: ValueKind::of_column(&column.column_type.kind),
                labels: match &column.column_type.kind {
                    ColumnKind::Enum { labels, .. } => labels.clone(),
                    _ => Vec::new(),
                },
                multiple: matches!(column.column_type.kind, ColumnKind::Enum { multiple: true, .. }),
                needs_offset: matches!(
                    column.column_type.kind,
                    ColumnKind::Time { with_offset: true, .. }
                        | ColumnKind::Timestamp {
                            zone: TemporalZone::Offset,
                            ..
                        }
                ),
            })
            .collect()
    }

    // The text a cell's editor starts from: the whole value, which the grid shows cut.
    pub fn edit_start(&self, rows: Arc<ResultSet>, row: u64, column: u32) -> Result<EditStart, CoreError> {
        let info = self.column(column)?;
        if !editable(info) {
            return Ok(EditStart::ReadOnly);
        }
        let index = column as usize;
        let kind = rows
            .cell_kind(row, index)
            .ok_or_else(|| CoreError::failed("edit.out_of_range", format!("no cell at row {row}, column {column}")))?;
        // A value the driver could not read, or bytes, have no text that writes them back.
        if matches!(kind, Some(ValueKind::Undecodable | ValueKind::Bytes)) {
            return Ok(EditStart::ReadOnly);
        }
        let text = rows.full_text(row, index).flatten();
        Ok(EditStart::Editable {
            is_null: text.is_none(),
            text: text.unwrap_or_default(),
        })
    }

    // Reads the text as the save will, so a cell the user leaves can say why it would not save.
    pub fn check(&self, column: u32, edit: CellEdit, new_row: bool) -> Result<(), CoreError> {
        let info = self.column(column)?;
        let dialect = self.session.current_dialect();
        self.check_cell(dialect.as_deref(), info, &edit, new_row, None)
            .map(|_| ())
    }

    pub fn pending(&self) -> PendingSummary {
        let tracker = self.tracker();
        self.summary(&tracker)
    }

    // The pending edits laid over `rows`, by place: the grid draws them without a key of its own.
    pub fn overlay(&self, rows: Arc<ResultSet>) -> GridOverlay {
        let tracker = self.tracker();
        let drafts = tracker
            .drafts()
            .values()
            .map(|draft| OverlayRow {
                cells: draft.cells.iter().map(pending_cell).collect(),
            })
            .collect();
        let read = rows.result_columns();
        let mut cells = Vec::new();
        let mut modified_rows = Vec::new();
        let mut deleted_rows = Vec::new();
        // Off-page edits have no place here; a column change locks the page, so it shows no overlay but its drafts.
        if tracker.pending_count() > tracker.drafts().len() && self.check_layout(&rows, &read).is_ok() {
            let width = self.columns.len();
            for row in 0..rows.row_count() {
                let Ok(key) = self.row_key(&rows, &read, row) else {
                    continue;
                };
                if tracker.row_state(&key) == RowState::PendingDelete {
                    deleted_rows.push(row);
                    continue;
                }
                let pending = tracker.pending_inputs(&key, width);
                if pending.is_empty() {
                    continue;
                }
                modified_rows.push(row);
                for (column, input) in pending {
                    cells.push(OverlayCell {
                        row,
                        column: column as u32,
                        cell: pending_cell(&input),
                    });
                }
            }
        }
        GridOverlay {
            cells,
            modified_rows,
            deleted_rows,
            drafts,
        }
    }

    // Records a cell the user committed. A data row is named by its primary key; a new row by its place after the data.
    pub fn set_cell(
        &self,
        rows: Arc<ResultSet>,
        row: u64,
        column: u32,
        edit: CellEdit,
    ) -> Result<PendingSummary, CoreError> {
        self.require_unlocked()?;
        let info = self.column(column)?;
        let index = column as usize;
        let read = rows.result_columns();
        let data_rows = rows.row_count();
        let dialect = self.session.current_dialect();
        let tracker_edit = if row < data_rows {
            self.check_layout(&rows, &read)?;
            let original = self.stored(&rows, &read, row, index);
            let value = self.check_cell(dialect.as_deref(), info, &edit, false, original.as_ref())?;
            let row_key = self.row_key(&rows, &read, row)?;
            TrackerEdit::Cell {
                row_key,
                col: index,
                original: original.unwrap_or(Value::Null),
                value,
            }
        } else {
            let draft_id = self
                .tracker()
                .drafts()
                .get_index((row - data_rows) as usize)
                .map(|(id, _)| *id)
                .ok_or_else(|| CoreError::failed("edit.out_of_range", format!("no new row at {row}")))?;
            let input = self.check_cell(dialect.as_deref(), info, &edit, true, None)?;
            TrackerEdit::DraftCell {
                draft_id,
                col: index,
                input,
            }
        };
        let mut tracker = self.tracker();
        let _ = tracker.apply(tracker_edit);
        Ok(self.summary(&tracker))
    }

    // A new row after the data rows, holding the server's value where it fills the column, else NULL.
    pub fn insert_row(&self) -> Result<PendingSummary, CoreError> {
        self.require_unlocked()?;
        let cells = self.new_draft();
        let mut tracker = self.tracker();
        let _ = tracker.apply(TrackerEdit::InsertDrafts { rows: vec![cells] });
        Ok(self.summary(&tracker))
    }

    // Each row copied once, in the order given; a data row copies only where its value reads back exactly.
    pub fn duplicate_rows(&self, rows: Arc<ResultSet>, places: Vec<u64>) -> Result<PendingSummary, CoreError> {
        self.require_unlocked()?;
        let read = rows.result_columns();
        let data_rows = rows.row_count();
        let mut drafts = Vec::new();
        for place in places {
            let key = if place < data_rows {
                self.check_layout(&rows, &read)?;
                self.row_key(&rows, &read, place)?
            } else {
                match self.tracker().drafts().get_index((place - data_rows) as usize) {
                    Some((id, _)) => RowKey::Draft(*id),
                    None => continue,
                }
            };
            drafts.push(self.duplicate_cells(&rows, &read, &key));
        }
        let mut tracker = self.tracker();
        let _ = tracker.apply(TrackerEdit::InsertDrafts { rows: drafts });
        Ok(self.summary(&tracker))
    }

    // A new row is dropped; a data row is marked for the save to delete, with its edits.
    pub fn delete_rows(&self, rows: Arc<ResultSet>, places: Vec<u64>) -> Result<PendingSummary, CoreError> {
        self.require_unlocked()?;
        let read = rows.result_columns();
        let data_rows = rows.row_count();
        let mut persisted = Vec::new();
        let mut drafts = Vec::new();
        let mut checked = false;
        for place in places {
            if place < data_rows {
                if !checked {
                    self.check_layout(&rows, &read)?;
                    checked = true;
                }
                let key = self.row_key(&rows, &read, place)?;
                let original = (0..self.columns.len())
                    .map(|index| rows.stored_value(place, index).unwrap_or(Value::Null))
                    .collect::<Vec<_>>();
                persisted.push((key, Arc::from(original)));
            } else if let Some((id, _)) = self.tracker().drafts().get_index((place - data_rows) as usize) {
                drafts.push(*id);
            }
        }
        let mut tracker = self.tracker();
        let _ = tracker.apply(TrackerEdit::DeleteRows { persisted, drafts });
        Ok(self.summary(&tracker))
    }

    // Un-delete data rows marked for deletion.
    pub fn restore_rows(&self, rows: Arc<ResultSet>, places: Vec<u64>) -> Result<PendingSummary, CoreError> {
        self.require_unlocked()?;
        let read = rows.result_columns();
        let data_rows = rows.row_count();
        let mut keys = Vec::new();
        for place in places.into_iter().filter(|place| *place < data_rows) {
            if let Ok(key) = self.row_key(&rows, &read, place) {
                keys.push(key);
            }
        }
        let mut tracker = self.tracker();
        let _ = tracker.restore_rows(keys);
        Ok(self.summary(&tracker))
    }

    pub fn undo(&self) -> PendingSummary {
        let mut tracker = self.tracker();
        let _ = tracker.undo();
        self.summary(&tracker)
    }

    pub fn redo(&self) -> PendingSummary {
        let mut tracker = self.tracker();
        let _ = tracker.redo();
        self.summary(&tracker)
    }

    pub fn discard(&self) -> PendingSummary {
        let mut tracker = self.tracker();
        let _ = tracker.discard();
        self.summary(&tracker)
    }

    // The statements the save would run now, the Safe Mode gate and how many rows it deletes.
    pub fn preview(&self) -> Result<SavePreview, CoreError> {
        self.require_unlocked()?;
        let dialect = self
            .session
            .current_dialect()
            .ok_or_else(|| CoreError::failed("ffi.not_connected", "the session has no connection"))?;
        let gate = save_gate(self.session.safe_mode());
        let tracker = self.tracker();
        let Some((_, changes)) = tracker.preview_save().map_err(rejection_error)? else {
            return Ok(SavePreview {
                statements: Vec::new(),
                gate,
                deletes: 0,
                is_empty: true,
            });
        };
        let deletes = changes
            .changes
            .changes
            .iter()
            .filter(|change| matches!(change, tablepro_core::save::RowChange::Delete { .. }))
            .count() as u64;
        let plan =
            plan_save(&*dialect, &self.table, &self.columns, &self.identity, &changes.changes).map_err(build_error)?;
        let statements = plan.batch.steps.iter().map(|step| planned(&step.statement)).collect();
        Ok(SavePreview {
            statements,
            gate,
            deletes,
            is_empty: plan.batch.steps.is_empty(),
        })
    }

    // Saves the pending changes. `confirmed` answers Safe Mode's question; the tracker settles on the outcome, so a
    // commit drops the saved rows, a rollback keeps them, and an unknown outcome refuses the next save.
    pub async fn save(
        &self,
        rows: Arc<ResultSet>,
        confirmed: bool,
        cancel: Option<Arc<CancelToken>>,
    ) -> Result<RowSaveOutcome, CoreError> {
        self.require_unlocked()?;
        let planned_gate = save_gate(self.session.safe_mode());
        if planned_gate == SaveGate::Refuse {
            return Err(lock_error(&EditLock::ReadOnlyConnection));
        }
        if planned_gate == SaveGate::Confirm && !confirmed {
            return Err(CoreError::failed(
                "edit.not_confirmed",
                "Safe Mode asks before this save and it was not answered",
            ));
        }
        let dialect = self
            .session
            .current_dialect()
            .ok_or_else(|| CoreError::failed("ffi.not_connected", "the session has no connection"))?;
        let batch = match self.tracker().begin_save() {
            Ok(Some(batch)) => batch,
            Ok(None) => return Ok(RowSaveOutcome::Saved { rows: Some(0) }),
            Err(rejection) => return Err(rejection_error(rejection)),
        };
        let plan = match plan_save(
            &*dialect,
            &batch.table,
            &batch.columns,
            &self.identity,
            &batch.changes.changes,
        ) {
            Ok(plan) => plan,
            Err(error) => {
                // Nothing was sent, so the changes stay as they were.
                let _ = self.tracker().settle_save(&SaveOutcome::RolledBack, batch.snapshot);
                return Err(build_error(error));
            }
        };
        let run = self
            .run_batch(
                &plan,
                &batch.table,
                &batch.columns,
                &batch.changes.changes,
                planned_gate,
                cancel,
            )
            .await;
        let (written, resolution) = match run {
            Ok(pair) => pair,
            Err(refused) => {
                let _ = self.tracker().settle_save(&SaveOutcome::RolledBack, batch.snapshot);
                return Err(refused);
            }
        };
        Ok(self.finish_save(&rows, written, resolution, &plan, &batch.changes, batch.snapshot))
    }
}

type RanBatch = (
    Result<WriteReport, OperationError>,
    Option<Result<CommitResolution, OperationError>>,
);

impl TableEditor {
    // Runs the plan on the writing lease, planning it again there so a connection replaced since cannot save other SQL
    // than the user was shown. An `Err` here was refused before anything was sent.
    async fn run_batch(
        &self,
        plan: &SavePlan,
        table: &TableRef,
        columns: &[ColumnInfo],
        change_set: &ChangeSet,
        planned_gate: SaveGate,
        cancel: Option<Arc<CancelToken>>,
    ) -> Result<RanBatch, CoreError> {
        let session = self.session.clone();
        let cancel = token(cancel);
        let shown = plan.clone();
        let identity = self.identity.clone();
        let table = table.clone();
        let columns = columns.to_vec();
        let change_set = change_set.clone();
        on_runtime(&self.tasks, async move {
            let gated = session.clone();
            let written = session
                .run_cancellable(
                    OperationKind::Save(WriteKind::RowChanges),
                    &cancel,
                    move |lease, options| {
                        let (table, columns, identity, change_set, shown, gated) = (
                            table.clone(),
                            columns.clone(),
                            identity.clone(),
                            change_set.clone(),
                            shown.clone(),
                            gated.clone(),
                        );
                        async move {
                            if save_gate(gated.safe_mode()) != planned_gate {
                                return Ok(Err(safe_mode_changed()));
                            }
                            let plan = plan_save(&*lease.dialect(), &table, &columns, &identity, &change_set)?;
                            if !same_plan(&plan, &shown) {
                                return Ok(Err(CoreError::failed(
                                    "edit.not_as_planned",
                                    "the connection would save other statements than the ones planned",
                                )));
                            }
                            Ok(Ok(lease.write_batch(&plan.batch, options).await?))
                        }
                    },
                )
                .await;
            let written: Result<WriteReport, OperationError> = match written {
                Ok(Err(refused)) => return Err(refused),
                Ok(Ok(report)) => Ok(report),
                Err(error) => Err(error),
            };
            let resolution = resolve_commit(&session, &written).await;
            Ok((written, resolution))
        })
        .await
    }

    // Settles the tracker on what the save left in the database and words the outcome for the app, with the place of
    // the row the save stopped at so the grid can scroll to it.
    fn finish_save(
        &self,
        rows: &ResultSet,
        written: Result<WriteReport, OperationError>,
        resolution: Option<Result<CommitResolution, OperationError>>,
        plan: &SavePlan,
        changes: &TrackedChanges,
        snapshot: SaveSnapshot,
    ) -> RowSaveOutcome {
        let read = rows.result_columns();
        let (outcome, error, step) = self.classify(written, resolution);
        let failed = self.failed_row(rows, &read, plan, changes, step);
        let _ = self.tracker().settle_save(&outcome, snapshot);
        if let Some(row) = failed
            && !matches!(outcome, SaveOutcome::Committed { .. })
            && let Ok(key) = self.row_key(rows, &read, row)
        {
            let _ = self.tracker().mark_error_row(key);
        }
        match outcome {
            SaveOutcome::Committed { rows } => RowSaveOutcome::Saved { rows },
            SaveOutcome::RolledBack => RowSaveOutcome::RolledBack {
                error: error
                    .unwrap_or_else(|| CoreError::failed("edit.rolled_back", "the save rolled back"))
                    .into_info(),
                row: failed,
            },
            SaveOutcome::Unknown(_) => RowSaveOutcome::Unknown {
                error: error
                    .unwrap_or_else(|| CoreError::failed("edit.outcome_unknown", "the save outcome is unknown"))
                    .into_info(),
                row: failed,
            },
        }
    }
}

pub(crate) fn save_gate(level: SafeModeLevel) -> SaveGate {
    match level.gate(StatementAccess::Write) {
        WriteGate::Run => SaveGate::Run,
        WriteGate::Confirm => SaveGate::Confirm,
        WriteGate::Refuse => SaveGate::Refuse,
    }
}

fn pending_cell(input: &CellInput) -> PendingCell {
    match input {
        CellInput::Value(Value::Null) => PendingCell {
            kind: PendingKind::Null,
            text: String::new(),
        },
        CellInput::Value(value) => PendingCell {
            kind: PendingKind::Value,
            text: value_to_text(value).unwrap_or_default(),
        },
        CellInput::Default | CellInput::Expression(_) => PendingCell {
            kind: PendingKind::Default,
            text: String::new(),
        },
    }
}

// The values a copy takes, as Duplicate copies them: every column but the key and what the server fills.
fn copies_exactly(read: &[ResultColumn], columns: &[ColumnInfo], rows: &ResultSet, row: u64) -> bool {
    columns
        .iter()
        .enumerate()
        .filter(|(_, column)| !column.primary_key && editable_in_new_row(column))
        .all(|(index, column)| match rows.stored_value(row, index) {
            None | Some(Value::Null) => true,
            Some(value) => read
                .get(index)
                .is_some_and(|read| value_for_column(&value, &read.column_type, &column.column_type).is_some()),
        })
}

// A NUL cannot be in an identifier, so no key lookup by name ever lands on this column, and no statement names it.
fn unwritable(index: usize, column: &ResultColumn) -> ColumnInfo {
    ColumnInfo {
        name: format!("\0{index}"),
        column_type: column.column_type.clone(),
        nullable: true,
        primary_key: false,
        is_auto_increment: false,
        is_generated: true,
        partition_scoped: false,
        default: ColumnDefault::None,
        comment: None,
    }
}

fn editable(column: &ColumnInfo) -> bool {
    !column.primary_key && editable_in_new_row(column)
}

fn editable_in_new_row(column: &ColumnInfo) -> bool {
    !column.is_generated && !column.is_auto_increment && read_only_reason(&column.column_type.kind).is_none()
}

// SQLite and a ClickHouse mutation have no `SET c = DEFAULT`, so only a dialect that parses it offers one.
fn takes_default(column: &ColumnInfo, dialect: Option<&dyn SqlDialect>) -> bool {
    !column.default.is_none() && !column.is_generated && dialect.is_some_and(SqlDialect::update_sets_default)
}

fn key_value(rows: &ResultSet, read: &[ResultColumn], row: u64, index: usize, column: &ColumnInfo) -> Option<Value> {
    rows.stored_value(row, index)
        .and_then(|value| value_for_column(&value, &read.get(index)?.column_type, &column.column_type))
        .filter(|value| !matches!(value, Value::Null))
}

fn safe_mode_changed() -> CoreError {
    CoreError::failed(
        "edit.safe_mode_changed",
        "the connection's Safe Mode changed after the save was planned",
    )
}

fn planned(statement: &Statement) -> PlannedStatement {
    PlannedStatement {
        sql: statement.sql().to_owned(),
        values: statement
            .params()
            .iter()
            .map(|param| shown_value(param.value()))
            .collect(),
    }
}

// A bound value as the user would write it, on one line.
fn shown_value(value: &Value) -> String {
    let Some(text) = value_to_text(value) else {
        return "NULL".to_owned();
    };
    let text = text.replace(['\n', '\r'], " ");
    match value {
        Value::Bool(_)
        | Value::Int(_)
        | Value::UInt(_)
        | Value::WideInt(_)
        | Value::Float32(_)
        | Value::Float64(_)
        | Value::Decimal(_) => text,
        _ => format!("'{}'", text.replace('\'', "''")),
    }
}

// Statement by statement, the same SQL binding the same values. A NaN is the same NaN, which `==` on floats denies.
fn same_plan(left: &SavePlan, right: &SavePlan) -> bool {
    left.batch.steps.len() == right.batch.steps.len()
        && left.batch.steps.iter().zip(&right.batch.steps).all(|(left, right)| {
            let (left, right) = (&left.statement, &right.statement);
            left.sql() == right.sql()
                && left.params().len() == right.params().len()
                && left.params().iter().zip(right.params()).all(|(left, right)| {
                    left.param_type() == right.param_type() && same_value(left.value(), right.value())
                })
        })
}

// Ask the server what became of a commit whose acknowledgement was lost, where the engine left a way to ask.
pub(crate) async fn resolve_commit(
    session: &Session,
    written: &Result<WriteReport, OperationError>,
) -> Option<Result<CommitResolution, OperationError>> {
    let Err(OperationError::Driver(DriverError::CommitOutcomeUnknown { token: Some(token), .. })) = written else {
        return None;
    };
    let token = token.clone();
    let resolved = session
        .run(OperationKind::Metadata, move |lease, options| {
            let token = token.clone();
            async move {
                lease
                    .resolve_commit(&token, options)
                    .await
                    .map_err(OperationError::from)
            }
        })
        .await;
    if let Err(error) = &resolved {
        tracing::warn!(%error, "could not ask the server whether a save landed");
    }
    Some(resolved)
}

fn lock_error(lock: &EditLock) -> CoreError {
    match lock {
        EditLock::ReadOnlyConnection => CoreError::failed("edit.read_only_connection", "the connection is read-only"),
        EditLock::NoPrimaryKey => CoreError::failed("edit.no_primary_key", "the table has no primary key"),
        EditLock::KeyUnreadable { column } => CoreError::failed(
            "edit.key_unreadable",
            format!("the key column {column} cannot be read back exactly"),
        ),
        EditLock::ColumnsChanged => CoreError::failed(
            "edit.columns_changed",
            "the rows were read with other columns than the table has now",
        ),
        EditLock::NotOneSelect => CoreError::failed("edit.not_one_select", "only the rows of one SELECT can be edited"),
        EditLock::MoreThanOneTable => CoreError::failed(
            "edit.more_than_one_table",
            "rows from more than one table, a subquery or a CTE cannot be edited",
        ),
        EditLock::Collapsed => {
            CoreError::failed("edit.collapsed", "grouped, distinct or computed rows cannot be edited")
        }
        EditLock::Untraced => CoreError::failed("edit.untraced", "only rows read straight from a table can be edited"),
        EditLock::KeyNotShown => CoreError::failed(
            "edit.key_not_shown",
            "the result leaves out part of the table's primary key",
        ),
    }
}

fn parse_error(error: EditParseError) -> CoreError {
    CoreError::failed(error.code(), error.to_string())
}

fn build_error(error: tablepro_core::dml::BuildSqlError) -> CoreError {
    CoreError::failed(error.code(), error.to_string())
}

#[cfg(test)]
mod tests {
    use tablepro_core::column::{ColumnKind, ColumnType, FloatWidth, IntegerKind, IntegerWidth, ReadForm};

    use super::*;
    use crate::results::ResultStore;

    fn catalog(name: &str, kind: ColumnKind) -> ColumnInfo {
        ColumnInfo {
            name: name.to_owned(),
            column_type: ColumnType {
                name: name.to_owned(),
                kind,
                catalog: None,
                dynamic_storage: false,
                read_form: ReadForm::Native,
            },
            nullable: true,
            primary_key: false,
            is_auto_increment: false,
            is_generated: false,
            partition_scoped: false,
            default: ColumnDefault::None,
            comment: None,
        }
    }

    #[test]
    fn pending_cell_keeps_default_and_null_apart() {
        assert_eq!(pending_cell(&CellInput::Value(Value::Null)).kind, PendingKind::Null);
        assert_eq!(pending_cell(&CellInput::Default).kind, PendingKind::Default);
        let value = pending_cell(&CellInput::Value(Value::Int(7)));
        assert_eq!(value.kind, PendingKind::Value);
        assert_eq!(value.text, "7");
    }

    #[test]
    fn server_text_for_a_float_does_not_copy_and_an_integer_s_does() {
        let read: Arc<[ResultColumn]> = vec![
            ResultColumn::new("amount", ColumnType::untyped_text("float8")),
            ResultColumn::new("count", ColumnType::untyped_text("int4")),
        ]
        .into();
        let columns = [
            catalog("amount", ColumnKind::Float(FloatWidth::F64)),
            catalog(
                "count",
                ColumnKind::Integer(IntegerKind {
                    width: IntegerWidth::W32,
                    signed: true,
                }),
            ),
        ];
        let store = Arc::new(ResultStore::new(read.clone()));
        store.append(&[
            vec![Value::Text("0.1".to_owned()), Value::Text("7".to_owned())],
            vec![Value::Null, Value::Text("8".to_owned())],
        ]);
        let rows = ResultSet::new(0, store);

        assert!(!copies_exactly(&read, &columns, &rows, 0));
        assert!(copies_exactly(&read, &columns, &rows, 1));
    }
}
