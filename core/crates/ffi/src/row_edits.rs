use std::collections::{HashMap, HashSet};
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering};

use tablepro_core::column::{ColumnInfo, ResultColumn};
use tablepro_core::dialect::SqlDialect;
use tablepro_core::dml::BuildSqlError;
use tablepro_core::edit::{
    CellInput, EditContext, EditParseError, is_unchanged, new_draft_cell, parse_edit_text, read_only_reason,
    value_for_column,
};
use tablepro_core::export::value_to_text;
use tablepro_core::meta::{RowIdentity, TableRef};
use tablepro_core::save::{ChangeSet, RowChange, RowUpdate, SavePlan, plan_save};
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
use crate::results::{ResultSet, ValueKind};
use crate::runtime::on_runtime;

// What the user put in a cell. An empty text means what `parse_edit_text` says it means for the column.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Enum)]
pub enum CellEdit {
    Text { text: String },
    Null,
    // The server's value: an insert leaves the column out, an update sets it to DEFAULT.
    Default,
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct CellChange {
    pub column: u32,
    pub edit: CellEdit,
}

// A row of the page, by its place in the result set the page was read into.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Enum)]
pub enum RowEdit {
    Update { row: u64, cells: Vec<CellChange> },
    // One cell per column, in the table's order.
    Insert { cells: Vec<CellEdit> },
    Delete { row: u64 },
}

// Why no row of the table, or of the page, can be changed.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Enum)]
pub enum EditLock {
    ReadOnlyConnection,
    NoPrimaryKey,
    // A key the page holds cannot be named exactly, such as a float or PostgreSQL's server text for a date.
    KeyUnreadable { column: String },
    // The page was read with other columns than the editor's catalog.
    ColumnsChanged,
}

// The Linux grid's rules: a saved row's key and a column the server fills are locked, a new row may set its key.
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
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Enum)]
pub enum EditStart {
    // The whole value, never the grid's cut text; empty for NULL.
    Editable { text: String, is_null: bool },
    ReadOnly,
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

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Enum)]
pub enum RowSaveOutcome {
    Saved { rows: Option<u64> },
    // Nothing was written. `edit` is the place in the edits of the change the save stopped at, when the engine said.
    RolledBack { error: BoxedErrorInfo, edit: Option<u32> },
    // The save may have landed in part or in full; saving again could write it twice.
    Unknown { error: BoxedErrorInfo, edit: Option<u32> },
}

// A table tab's rows as the save sees them: the catalog's columns, keyed by the primary key, as the Linux tracker keys
// them.
#[derive(uniffi::Object)]
pub struct TableEditor {
    session: Arc<Session>,
    tasks: Tasks,
    table: TableRef,
    columns: Arc<[ColumnInfo]>,
    lock: Option<EditLock>,
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
            Ok(Arc::new(Self {
                session,
                tasks,
                table,
                columns,
                lock,
            }))
        })
        .await
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

    // The result set holds the page's columns first, which build_page lays out in the catalog's order.
    fn check_layout(&self, rows: &[ResultColumn]) -> Result<(), CoreError> {
        let same = rows.len() >= self.columns.len()
            && self
                .columns
                .iter()
                .zip(rows)
                .all(|(catalog, read)| catalog.name == read.name);
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

    fn unreadable_key(&self, rows: &ResultSet, read: &[ResultColumn], row: u64) -> Option<String> {
        self.columns
            .iter()
            .enumerate()
            .filter(|(_, column)| column.primary_key)
            .find(|(index, column)| key_value(rows, read, row, *index, column).is_none())
            .map(|(_, column)| column.name.clone())
    }

    fn input(&self, column: &ColumnInfo, edit: &CellEdit, context: EditContext) -> Result<CellInput, CoreError> {
        let input = match edit {
            CellEdit::Text { text } => parse_edit_text(text, column, context).map_err(parse_error)?,
            CellEdit::Null if column.nullable => CellInput::Value(Value::Null),
            CellEdit::Null => return Err(parse_error(EditParseError::Required)),
            CellEdit::Default => CellInput::Default,
        };
        Ok(input)
    }

    // In the host's order, which is the order the changes were made, as the Linux tracker keeps it, so a new parent
    // row saves before the child pointed at it. A row is written once: a deleted row's updates go, one row's updates
    // merge, later cells winning.
    fn change_set(
        &self,
        dialect: &dyn SqlDialect,
        rows: &ResultSet,
        edits: &[RowEdit],
    ) -> Result<(ChangeSet, Vec<u32>), CoreError> {
        let read = rows.result_columns();
        let reads_rows = edits.iter().any(|edit| !matches!(edit, RowEdit::Insert { .. }));
        if reads_rows {
            self.check_layout(&read)?;
        }
        let deleted: HashSet<u64> = edits
            .iter()
            .filter_map(|edit| match edit {
                RowEdit::Delete { row } => Some(*row),
                _ => None,
            })
            .collect();
        let mut updates: HashMap<u64, Vec<CellChange>> = HashMap::new();
        for edit in edits {
            if let RowEdit::Update { row, cells } = edit {
                updates.entry(*row).or_default().extend(cells.iter().cloned());
            }
        }
        let mut written = HashSet::new();
        let mut changes = Vec::with_capacity(edits.len());
        let mut origins = Vec::with_capacity(edits.len());
        for (index, edit) in edits.iter().enumerate() {
            let change = match edit {
                RowEdit::Delete { row } if written.insert(*row) => Some(RowChange::Delete {
                    key: self.key(rows, &read, *row)?,
                }),
                RowEdit::Update { row, .. } if !deleted.contains(row) && written.insert(*row) => {
                    let cells = updates.get(row).map(Vec::as_slice).unwrap_or_default();
                    self.update(dialect, rows, &read, *row, cells)?
                }
                RowEdit::Insert { cells } => Some(self.insert(cells)?),
                RowEdit::Delete { .. } | RowEdit::Update { .. } => None,
            };
            if let Some(change) = change {
                changes.push(change);
                origins.push(u32::try_from(index).unwrap_or(u32::MAX));
            }
        }
        Ok((ChangeSet { changes }, origins))
    }

    fn check_cell(
        &self,
        dialect: Option<&dyn SqlDialect>,
        column: &ColumnInfo,
        edit: &CellEdit,
        new_row: bool,
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
        self.input(column, edit, context)
    }

    fn update(
        &self,
        dialect: &dyn SqlDialect,
        rows: &ResultSet,
        read: &[ResultColumn],
        row: u64,
        cells: &[CellChange],
    ) -> Result<Option<RowChange>, CoreError> {
        let mut assignments: Vec<(usize, CellInput)> = Vec::with_capacity(cells.len());
        for cell in cells {
            let column = self.column(cell.column)?;
            let index = cell.column as usize;
            let input = self.check_cell(Some(dialect), column, &cell.edit, false)?;
            let original = rows
                .stored_value(row, index)
                .and_then(|value| value_for_column(&value, &read[index].column_type, &column.column_type));
            let unchanged = match (&input, &original) {
                (CellInput::Value(edited), Some(original)) => is_unchanged(original, edited, &column.column_type),
                _ => false,
            };
            // A later edit of the same cell is the one that counts, also when it puts the value back.
            assignments.retain(|(position, _)| *position != index);
            if !unchanged {
                assignments.push((index, input));
            }
        }
        if assignments.is_empty() {
            return Ok(None);
        }
        Ok(Some(RowChange::Update(RowUpdate {
            key: self.key(rows, read, row)?,
            assignments,
        })))
    }

    fn insert(&self, cells: &[CellEdit]) -> Result<RowChange, CoreError> {
        if cells.len() != self.columns.len() {
            return Err(CoreError::failed(
                "edit.columns_changed",
                format!(
                    "a new row has {} cells and the table {} columns",
                    cells.len(),
                    self.columns.len()
                ),
            ));
        }
        let mut inputs = Vec::with_capacity(cells.len());
        for (column, edit) in self.columns.iter().zip(cells) {
            // SQL Server IDENTITY and PostgreSQL GENERATED ALWAYS refuse a value, so the server fills them.
            if column.is_auto_increment || column.is_generated {
                inputs.push(CellInput::Default);
                continue;
            }
            // A column with no text to type, such as a blob, still takes NULL or the server's value in a new row.
            let input = match edit {
                CellEdit::Text { .. } => self.check_cell(None, column, edit, true)?,
                CellEdit::Null | CellEdit::Default => self.input(column, edit, EditContext::InsertDraft)?,
            };
            inputs.push(input);
        }
        Ok(RowChange::Insert { cells: inputs })
    }
}

#[uniffi::export]
impl TableEditor {
    pub fn lock(&self) -> Option<EditLock> {
        match &self.lock {
            None if self.session.read_only() => Some(EditLock::ReadOnlyConnection),
            lock => lock.clone(),
        }
    }

    // The page's own locks too: a lock here leaves every row of `rows` as it is.
    pub fn lock_for(&self, rows: Arc<ResultSet>) -> Option<EditLock> {
        if let Some(lock) = self.lock() {
            return Some(lock);
        }
        let read = rows.result_columns();
        if self.check_layout(&read).is_err() {
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
            .map(|column| EditColumnInfo {
                name: column.name.clone(),
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
        self.check_cell(dialect.as_deref(), info, &edit, new_row).map(|_| ())
    }

    // The statements the edits save as, at the session's Safe Mode level now. `rows` is the result set the rows were
    // read into; a cell edited back to its value is left out.
    pub fn plan(&self, rows: Arc<ResultSet>, edits: Vec<RowEdit>) -> Result<Arc<RowSave>, CoreError> {
        self.require_unlocked()?;
        let dialect = self
            .session
            .current_dialect()
            .ok_or_else(|| CoreError::failed("ffi.not_connected", "the session has no connection"))?;
        let (changes, origins) = self.change_set(&*dialect, &rows, &edits)?;
        let identity = pk_identity(&self.columns);
        let plan = plan_save(&*dialect, &self.table, &self.columns, &identity, &changes).map_err(build_error)?;
        let level = self.session.safe_mode();
        Ok(Arc::new(RowSave {
            session: self.session.clone(),
            tasks: self.tasks.clone(),
            table: self.table.clone(),
            columns: self.columns.clone(),
            identity,
            changes,
            origins,
            plan,
            level,
            started: AtomicBool::new(false),
        }))
    }
}

// One save, which runs only the statements it was planned with.
#[derive(uniffi::Object)]
pub struct RowSave {
    session: Arc<Session>,
    tasks: Tasks,
    table: TableRef,
    columns: Arc<[ColumnInfo]>,
    identity: RowIdentity,
    changes: ChangeSet,
    origins: Vec<u32>,
    plan: SavePlan,
    level: SafeModeLevel,
    started: AtomicBool,
}

#[uniffi::export]
impl RowSave {
    pub fn statements(&self) -> Vec<PlannedStatement> {
        self.plan
            .batch
            .steps
            .iter()
            .map(|step| planned(&step.statement))
            .collect()
    }

    pub fn is_empty(&self) -> bool {
        self.plan.batch.steps.is_empty()
    }

    // Row changes are writes, so Off saves, Confirm writes asks first and Read only refuses.
    pub fn gate(&self) -> SaveGate {
        save_gate(self.level)
    }

    // Runs the statements shown, planned again on the connection that writes them. `confirmed` says the user answered
    // Safe Mode's question. Another level than the one planned at, or another plan, refuses before anything is sent.
    pub async fn run(&self, confirmed: bool, cancel: Option<Arc<CancelToken>>) -> Result<RowSaveOutcome, CoreError> {
        let planned_gate = self.gate();
        if planned_gate == SaveGate::Confirm && !confirmed {
            return Err(CoreError::failed(
                "edit.not_confirmed",
                "Safe Mode asks before this save and it was not answered",
            ));
        }
        let now = save_gate(self.session.safe_mode());
        if now == SaveGate::Refuse {
            return Err(lock_error(&EditLock::ReadOnlyConnection));
        }
        if now != planned_gate {
            return Err(safe_mode_changed());
        }
        if self.is_empty() {
            return Ok(RowSaveOutcome::Saved { rows: Some(0) });
        }
        // A second run would write the same rows twice.
        if self.started.swap(true, Ordering::AcqRel) {
            return Err(CoreError::failed("edit.already_saved", "this save already ran"));
        }
        let session = self.session.clone();
        let cancel = token(cancel);
        let table = self.table.clone();
        let columns = self.columns.clone();
        let identity = self.identity.clone();
        let changes = self.changes.clone();
        let shown = self.plan.clone();
        let planned = self.plan.clone();
        let origins = self.origins.clone();
        on_runtime(&self.tasks, async move {
            let gated = session.clone();
            let written = session
                .run_cancellable(
                    OperationKind::Save(WriteKind::RowChanges),
                    &cancel,
                    move |lease, options| {
                        let (table, columns, identity, changes, shown, gated) = (
                            table.clone(),
                            columns.clone(),
                            identity.clone(),
                            changes.clone(),
                            shown.clone(),
                            gated.clone(),
                        );
                        async move {
                            // Checked again on the lease, so a level saved while the save waited for it holds.
                            if save_gate(gated.safe_mode()) != planned_gate {
                                return Ok(Err(safe_mode_changed()));
                            }
                            let plan = plan_save(&*lease.dialect(), &table, &columns, &identity, &changes)?;
                            // A connection replaced since the plan can write other SQL than the user was shown.
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
            let written = match written {
                Ok(Err(refused)) => return Err(refused),
                Ok(Ok(report)) => Ok(report),
                Err(error) => Err(error),
            };
            let resolution = resolve_commit(&session, &written).await;
            Ok(outcome(written, resolution, &planned, &origins))
        })
        .await
    }
}

fn save_gate(level: SafeModeLevel) -> SaveGate {
    match level.gate(StatementAccess::Write) {
        WriteGate::Run => SaveGate::Run,
        WriteGate::Confirm => SaveGate::Confirm,
        WriteGate::Refuse => SaveGate::Refuse,
    }
}

// The primary key columns in the table's order, the order a key is read in.
fn pk_identity(columns: &[ColumnInfo]) -> RowIdentity {
    RowIdentity::UniqueKey {
        columns: columns
            .iter()
            .filter(|column| column.primary_key)
            .map(|column| column.name.clone())
            .collect(),
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
async fn resolve_commit(
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

// As the Linux app reads a save's result: what is in the database now decides.
fn outcome(
    written: Result<WriteReport, OperationError>,
    resolution: Option<Result<CommitResolution, OperationError>>,
    plan: &SavePlan,
    origins: &[u32],
) -> RowSaveOutcome {
    let error = match written {
        Ok(report) => {
            return RowSaveOutcome::Saved {
                rows: report.total_rows(),
            };
        }
        Err(error) => error,
    };
    let info = || CoreError::from(&error).into_info();
    let edit = |step: usize| plan.origin(step).and_then(|change| origins.get(change).copied());
    match &error {
        OperationError::Driver(driver) => match driver {
            DriverError::RolledBack { statement_index, .. }
            | DriverError::RowGuardFailed { statement_index, .. }
            | DriverError::GuardUnsupported { statement_index } => RowSaveOutcome::RolledBack {
                error: info(),
                edit: edit(*statement_index),
            },
            DriverError::ReadOnly(_) => RowSaveOutcome::RolledBack {
                error: info(),
                edit: None,
            },
            DriverError::CommitOutcomeUnknown { .. } => match resolution {
                Some(Ok(CommitResolution::Applied)) => RowSaveOutcome::Saved { rows: None },
                Some(Ok(CommitResolution::NotApplied)) => RowSaveOutcome::RolledBack {
                    error: info(),
                    edit: None,
                },
                _ => RowSaveOutcome::Unknown {
                    error: info(),
                    edit: None,
                },
            },
            DriverError::PartiallyApplied { statement_index, .. } => RowSaveOutcome::Unknown {
                error: info(),
                edit: edit(*statement_index),
            },
            other => match other.category() {
                ErrorCategory::Interrupted | ErrorCategory::Timeout | ErrorCategory::ConnectionLost => {
                    RowSaveOutcome::Unknown {
                        error: info(),
                        edit: None,
                    }
                }
                _ => RowSaveOutcome::RolledBack {
                    error: info(),
                    edit: None,
                },
            },
        },
        OperationError::Sql(_) | OperationError::Build(_) | OperationError::Browse(_) => RowSaveOutcome::RolledBack {
            error: info(),
            edit: None,
        },
        OperationError::Cancelled | OperationError::Panicked(_) | OperationError::Closed => RowSaveOutcome::Unknown {
            error: info(),
            edit: None,
        },
    }
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
    }
}

fn parse_error(error: EditParseError) -> CoreError {
    CoreError::failed(error.code(), error.to_string())
}

fn build_error(error: BuildSqlError) -> CoreError {
    CoreError::failed(error.code(), error.to_string())
}
