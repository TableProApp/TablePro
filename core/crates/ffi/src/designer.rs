use std::sync::Mutex;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, PoisonError};

use tablepro_core::ForeignKeyInfo;
use tablepro_core::column::{ColumnDefault, ColumnType};
use tablepro_core::ddl::{
    BuildDdlError, ChangeReview, DdlPlan, DestructiveChange, DraftColumn, DraftTableOptions, DraftType,
    PendingStructure, ReferentialAction, SaveBlocker, TableChanges, TableDefinition, TableDraft, default_text,
    diff_table, parse_default,
};
use tablepro_core::dialect::SqlDialect;
use tablepro_core::meta::{IndexInfo, IndexKey, TableRef};
use tablepro_core::sql_syntax::StatementAccess;
use tablepro_core::statement::SqlBuildError;
use tablepro_core::{CommitResolution, DriverError, ErrorCategory, SafeModeLevel, WriteGate, WriteReport};
use tablepro_session::runtime::Tasks;
use tablepro_session::{OperationError, OperationKind, Session};

use crate::cancel_token::{CancelToken, token};
use crate::catalog::TableName;
use crate::error::{BoxedErrorInfo, CoreError};
use crate::row_edits::{SaveGate, resolve_commit};
use crate::runtime::on_runtime;
use crate::session::DatabaseSession;

// A column as the table designer edits it. `type_text` and `default_text` are what the user typed; the core resolves
// them with the connection's dialect. `original_name` names the column this one started from, None for a new one.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct DraftColumnInput {
    pub original_name: Option<String>,
    pub name: String,
    pub type_text: String,
    pub nullable: bool,
    pub primary_key: bool,
    pub auto_increment: bool,
    pub default_text: String,
    pub comment: Option<String>,
    pub character_set: Option<String>,
    pub collation: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Enum)]
pub enum IndexKeyInput {
    Column { name: String, descending: bool },
    Expression { sql: String, descending: bool },
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct IndexInput {
    pub name: String,
    pub keys: Vec<IndexKeyInput>,
    pub unique: bool,
    pub primary: bool,
    pub predicate: Option<String>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum ReferentialActionTag {
    NoAction,
    Restrict,
    Cascade,
    SetNull,
    SetDefault,
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct ForeignKeyInput {
    pub name: String,
    pub columns: Vec<String>,
    pub ref_schema: Option<String>,
    pub ref_table: String,
    pub ref_columns: Vec<String>,
    pub on_delete: Option<ReferentialActionTag>,
    pub on_update: Option<ReferentialActionTag>,
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct TableOptionsInput {
    pub character_set: Option<String>,
    pub collation: Option<String>,
    pub converts_columns: bool,
    pub next_auto_increment: Option<u64>,
}

// The whole draft the designer plans. For an existing table the app starts from `starting_draft` and edits it; for a
// new one it builds the columns from scratch.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct TableDraftInput {
    pub schema: Option<String>,
    pub name: String,
    pub columns: Vec<DraftColumnInput>,
    pub indexes: Vec<IndexInput>,
    pub foreign_keys: Vec<ForeignKeyInput>,
    pub options: Option<TableOptionsInput>,
}

// A part of the save that loses data or drops something it has to make again, named before it runs.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Enum)]
pub enum DestructiveChangeTag {
    // The rows are copied into a new table and the old one dropped. `recreated` names the objects made again.
    RebuildTable {
        recreated: Vec<String>,
        renumbers_rowids: bool,
    },
    DropColumn {
        column: String,
    },
    ChangeColumnType {
        column: String,
        from: String,
        to: String,
    },
    SetNotNull {
        column: String,
    },
    ConvertCharacterSet,
    ChangeColumnCharacterSet {
        column: String,
    },
    DropIndex {
        index: String,
    },
    DropForeignKey {
        key: String,
    },
}

// Why a draft cannot be saved as it stands, for the app to word.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Enum)]
pub enum SaveBlockerTag {
    // The draft itself is invalid; `code` is the DraftProblem's.
    Draft { code: String },
    // A column's typed default the engine's parser refused.
    UnparsedDefault { column: String },
}

// The statements a plan runs, what it loses, and whether it can be saved now.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct TableDesignerPlan {
    // Names the plan to `run`, so a plan replaced since is never the one written.
    pub plan_id: u64,
    pub statements: Vec<String>,
    // The edits the action bar counts.
    pub operations: u64,
    pub destructive: Vec<DestructiveChangeTag>,
    // The name the tab follows once the save lands, when that differs from the one it shows now.
    pub saved_table_name: Option<String>,
    // Set when the draft cannot be saved; the plan is a preview only.
    pub blocked: Option<SaveBlockerTag>,
    pub gate: SaveGate,
}

#[derive(Debug, Clone, PartialEq, uniffi::Enum)]
pub enum TableSaveOutcome {
    Done,
    // Nothing changed.
    Failed { error: BoxedErrorInfo },
    // The change may have landed in part or in full.
    Unknown { error: BoxedErrorInfo },
}

#[uniffi::export]
impl DatabaseSession {
    // Opens the designer for an existing table, read as the server defines it now; `table` None opens a new table in
    // `schema` (the connection's default schema when None).
    pub async fn open_table_designer(
        &self,
        table: Option<TableName>,
        schema: Option<String>,
        cancel: Option<Arc<CancelToken>>,
    ) -> Result<Arc<TableDesigner>, CoreError> {
        let session = self.session().clone();
        let tasks = self.tasks().clone();
        let cancel = token(cancel);
        on_runtime(self.tasks(), async move {
            let original = match table {
                Some(table) => {
                    let table: TableRef = table.into();
                    let definition = session
                        .run_cancellable(OperationKind::Metadata, &cancel, |lease, options| {
                            let table = table.clone();
                            async move { Ok(lease.fetch_table_definition(&table, options).await?) }
                        })
                        .await?;
                    Some(definition)
                }
                None => None,
            };
            Ok(Arc::new(TableDesigner {
                session,
                tasks,
                original,
                new_schema: schema,
                planned: Mutex::new(None),
                last: AtomicBool::new(false),
                next_id: Mutex::new(0),
            }))
        })
        .await
    }
}

// One table's designer: the table as it was read and the plan ready to run.
#[derive(uniffi::Object)]
pub struct TableDesigner {
    session: Arc<Session>,
    tasks: Tasks,
    original: Option<TableDefinition>,
    new_schema: Option<String>,
    planned: Mutex<Option<Planned>>,
    // Whether the ready plan has already run.
    last: AtomicBool,
    next_id: Mutex<u64>,
}

struct Planned {
    id: u64,
    pending: PendingStructure,
    shown: DdlPlan,
    gate: SaveGate,
    access: StatementAccess,
}

#[uniffi::export]
impl TableDesigner {
    // The draft the app starts from: the table's columns, indexes, keys and options as the server defines them, with
    // each column's type and default as text. Empty for a new table.
    pub fn starting_draft(&self) -> Result<TableDraftInput, CoreError> {
        let dialect = self.session.current_dialect().ok_or_else(not_connected)?;
        let (schema, name, draft) = match &self.original {
            Some(original) => {
                let draft = TableDraft::from_definition(original);
                (draft.table.schema.clone(), draft.table.name.clone(), Some(draft))
            }
            None => (self.new_schema.clone(), String::new(), None),
        };
        let draft = draft.unwrap_or_else(|| TableDraft::new(TableRef::new(schema.clone(), name.clone())));
        Ok(draft_record(&draft, &*dialect))
    }

    // Suggested column types the engine offers, for the type field's completion.
    pub fn type_suggestions(&self) -> Vec<String> {
        self.session
            .current_dialect()
            .and_then(|dialect| dialect.ddl().map(|ddl| ddl.type_suggestions().to_vec()))
            .unwrap_or_default()
            .into_iter()
            .map(str::to_owned)
            .collect()
    }

    // The statements the draft would run, planned at the session's Safe Mode level now, with what the save loses. A
    // draft the engine cannot plan at all is refused here; one a typed value blocks still returns its preview, with
    // `blocked` set so the app holds the save.
    pub fn plan(&self, draft: TableDraftInput) -> Result<TableDesignerPlan, CoreError> {
        let dialect = self.session.current_dialect().ok_or_else(not_connected)?;
        let ddl = dialect
            .ddl()
            .ok_or_else(|| CoreError::failed("designer.unsupported", "the engine does not edit table structure"))?;
        let pending = self.pending(draft, &*dialect);
        let plan = pending.plan(ddl).map_err(build_error)?;
        let review = pending.review(ddl).map_err(build_error)?;
        let blocked = pending.check().err().map(blocker_tag);
        let access = access_of(&review);
        let gate = designer_gate(self.session.safe_mode(), access, self.session.read_only());
        let id = {
            let mut next = self.next_id.lock().unwrap_or_else(PoisonError::into_inner);
            *next = next.wrapping_add(1);
            *next
        };
        let statements = plan.sql().into_iter().map(str::to_owned).collect();
        let saved_table_name = pending.saved_table_name().filter(|name| {
            self.original
                .as_ref()
                .is_none_or(|original| original.table.name != *name)
        });
        let record = TableDesignerPlan {
            plan_id: id,
            statements,
            operations: review.operations as u64,
            destructive: review.destructive.iter().map(destructive_tag).collect(),
            saved_table_name,
            blocked,
            gate,
        };
        *self.planned.lock().unwrap_or_else(PoisonError::into_inner) = Some(Planned {
            id,
            pending,
            shown: plan,
            gate,
            access,
        });
        self.last.store(false, Ordering::Release);
        Ok(record)
    }

    // Runs the plan `plan_id` names, once, planned again on the connection that writes it. `confirmed` says the user
    // answered the gate's question. A draft a typed value blocks, another level than the one planned at, or another
    // plan refuses before anything is sent.
    pub async fn run(
        &self,
        plan_id: u64,
        confirmed: bool,
        cancel: Option<Arc<CancelToken>>,
    ) -> Result<TableSaveOutcome, CoreError> {
        let (pending, shown, gate, access) = {
            let planned = self.planned.lock().unwrap_or_else(PoisonError::into_inner);
            let Some(planned) = planned.as_ref().filter(|planned| planned.id == plan_id) else {
                return Err(CoreError::failed("designer.not_planned", "no change is planned"));
            };
            if let Err(blocker) = planned.pending.check() {
                return Err(blocker_error(&blocker));
            }
            match planned.gate {
                SaveGate::Refuse => {
                    return Err(CoreError::failed(
                        "edit.read_only_connection",
                        "the connection is read-only",
                    ));
                }
                SaveGate::Confirm if !confirmed => {
                    return Err(CoreError::failed(
                        "designer.not_confirmed",
                        "Safe Mode asks before this change and it was not answered",
                    ));
                }
                _ => {}
            }
            (
                planned.pending.clone(),
                planned.shown.clone(),
                planned.gate,
                planned.access,
            )
        };
        if designer_gate(self.session.safe_mode(), access, self.session.read_only()) != gate {
            return Err(safe_mode_changed());
        }
        if self.last.swap(true, Ordering::AcqRel) {
            return Err(CoreError::failed("designer.already_run", "this change already ran"));
        }
        let session = self.session.clone();
        let cancel = token(cancel);
        let target = pending.table();
        let kind = shown.kind;
        on_runtime(&self.tasks, async move {
            let gated = session.clone();
            let written = session
                .run_cancellable(OperationKind::Save(kind), &cancel, move |lease, options| {
                    let (pending, shown, gated, target) =
                        (pending.clone(), shown.clone(), gated.clone(), target.clone());
                    async move {
                        // Checked again on the lease, so a level saved while the change waited for it holds.
                        if designer_gate(gated.safe_mode(), access, gated.read_only()) != gate {
                            return Ok(Err(safe_mode_changed()));
                        }
                        let dialect = lease.dialect();
                        let ddl = dialect.ddl().ok_or(SqlBuildError::from(BuildDdlError::Unsupported(
                            tablepro_core::ddl::DdlOperation::AlterTable,
                        )))?;
                        let plan = pending.plan(ddl).map_err(SqlBuildError::from)?;
                        // A connection replaced since the plan can write other SQL than the user was shown.
                        if plan.sql() != shown.sql() {
                            return Ok(Err(CoreError::failed(
                                "designer.not_as_planned",
                                "the connection would run other statements than the ones planned",
                            )));
                        }
                        Ok(Ok(lease.write_batch(&plan.into_write_batch(target), options).await?))
                    }
                })
                .await;
            let written = match written {
                Ok(Err(refused)) => return Err(refused),
                Ok(Ok(report)) => Ok(report),
                Err(error) => Err(error),
            };
            let resolution = resolve_commit(&session, &written).await;
            let outcome = outcome(written, resolution);
            if !matches!(outcome, TableSaveOutcome::Failed { .. }) {
                session.invalidate_columns();
            }
            Ok(outcome)
        })
        .await
    }
}

impl TableDesigner {
    fn pending(&self, draft: TableDraftInput, dialect: &dyn SqlDialect) -> PendingStructure {
        let mut unparsed = Vec::new();
        let draft = build_draft(draft, self.original.as_ref(), dialect, &mut unparsed);
        let changes = match &self.original {
            Some(original) => diff_table(original, &draft),
            None => TableChanges::default(),
        };
        PendingStructure {
            original: self.original.clone(),
            draft,
            changes,
            unparsed_defaults: unparsed,
            invalid_auto_increment: false,
        }
    }
}

fn build_draft(
    input: TableDraftInput,
    original: Option<&TableDefinition>,
    dialect: &dyn SqlDialect,
    unparsed: &mut Vec<String>,
) -> TableDraft {
    TableDraft {
        table: TableRef::new(input.schema, input.name),
        columns: input
            .columns
            .into_iter()
            .map(|column| draft_column(column, original, dialect, unparsed))
            .collect(),
        indexes: input.indexes.into_iter().map(index_info).collect(),
        foreign_keys: input.foreign_keys.into_iter().map(foreign_key_info).collect(),
        options: input.options.map(|options| DraftTableOptions {
            character_set: options.character_set,
            collation: options.collation,
            converts_columns: options.converts_columns,
            next_auto_increment: options.next_auto_increment,
        }),
    }
}

fn draft_column(
    input: DraftColumnInput,
    original: Option<&TableDefinition>,
    dialect: &dyn SqlDialect,
    unparsed: &mut Vec<String>,
) -> DraftColumn {
    let started = input.original_name.as_ref().and_then(|name| {
        original
            .and_then(|original| original.columns.iter().find(|column| column.name() == name))
            .cloned()
    });
    // A type left as the catalogue spelled it is kept so the diff sees no change; typed text goes through the parser.
    let column_type = match &started {
        Some(original) if DraftType::Catalog(original.info.column_type.clone()).text() == input.type_text.trim() => {
            DraftType::Catalog(original.info.column_type.clone())
        }
        _ => DraftType::Typed(input.type_text.clone()),
    };
    let default = if input.default_text.trim().is_empty() {
        ColumnDefault::None
    } else {
        let resolved = column_type
            .column_type(dialect, &input.name)
            .unwrap_or_else(|_| ColumnType::untyped_text(column_type.text()));
        match parse_default(dialect, &input.default_text, &resolved) {
            Ok(default) => default,
            // The value the user typed is their edit still, so the save is held rather than dropping it without a word.
            Err(_) => {
                unparsed.push(input.name.clone());
                ColumnDefault::None
            }
        }
    };
    DraftColumn {
        original: started,
        name: input.name,
        column_type,
        nullable: input.nullable,
        primary_key: input.primary_key,
        auto_increment: input.auto_increment,
        default,
        comment: input.comment,
        character_set: input.character_set,
        collation: input.collation,
    }
}

fn index_info(input: IndexInput) -> IndexInfo {
    IndexInfo {
        name: input.name,
        keys: input
            .keys
            .into_iter()
            .map(|key| match key {
                IndexKeyInput::Column { name, descending } => IndexKey::Column { name, descending },
                IndexKeyInput::Expression { sql, descending } => IndexKey::Expression { sql, descending },
            })
            .collect(),
        unique: input.unique,
        primary: input.primary,
        predicate: input.predicate,
        definition: None,
    }
}

fn foreign_key_info(input: ForeignKeyInput) -> ForeignKeyInfo {
    ForeignKeyInfo {
        name: input.name,
        columns: input.columns,
        ref_schema: input.ref_schema,
        ref_table: input.ref_table,
        ref_columns: input.ref_columns,
        on_delete: input.on_delete.map(referential_action),
        on_update: input.on_update.map(referential_action),
    }
}

fn referential_action(action: ReferentialActionTag) -> ReferentialAction {
    match action {
        ReferentialActionTag::NoAction => ReferentialAction::NoAction,
        ReferentialActionTag::Restrict => ReferentialAction::Restrict,
        ReferentialActionTag::Cascade => ReferentialAction::Cascade,
        ReferentialActionTag::SetNull => ReferentialAction::SetNull,
        ReferentialActionTag::SetDefault => ReferentialAction::SetDefault,
    }
}

// The draft as records for the app, each column's type and default as the text the user edits.
fn draft_record(draft: &TableDraft, dialect: &dyn SqlDialect) -> TableDraftInput {
    TableDraftInput {
        schema: draft.table.schema.clone(),
        name: draft.table.name.clone(),
        columns: draft
            .columns
            .iter()
            .map(|column| column_record(column, dialect))
            .collect(),
        indexes: draft.indexes.iter().map(index_record).collect(),
        foreign_keys: draft.foreign_keys.iter().map(foreign_key_record).collect(),
        options: draft.options.as_ref().map(|options| TableOptionsInput {
            character_set: options.character_set.clone(),
            collation: options.collation.clone(),
            converts_columns: options.converts_columns,
            next_auto_increment: options.next_auto_increment,
        }),
    }
}

fn column_record(column: &DraftColumn, dialect: &dyn SqlDialect) -> DraftColumnInput {
    let default_text = match &column.default {
        ColumnDefault::None => String::new(),
        default => {
            let column_type = column
                .column_type
                .column_type(dialect, &column.name)
                .unwrap_or_else(|_| ColumnType::untyped_text(column.column_type.text()));
            default_text(dialect, default, &column_type)
        }
    };
    DraftColumnInput {
        original_name: column.original_name().map(str::to_owned),
        name: column.name.clone(),
        type_text: column.column_type.text().to_owned(),
        nullable: column.nullable,
        primary_key: column.primary_key,
        auto_increment: column.auto_increment,
        default_text,
        comment: column.comment.clone(),
        character_set: column.character_set.clone(),
        collation: column.collation.clone(),
    }
}

fn index_record(index: &IndexInfo) -> IndexInput {
    IndexInput {
        name: index.name.clone(),
        keys: index
            .keys
            .iter()
            .map(|key| match key {
                IndexKey::Column { name, descending } => IndexKeyInput::Column {
                    name: name.clone(),
                    descending: *descending,
                },
                IndexKey::Expression { sql, descending } => IndexKeyInput::Expression {
                    sql: sql.clone(),
                    descending: *descending,
                },
            })
            .collect(),
        unique: index.unique,
        primary: index.primary,
        predicate: index.predicate.clone(),
    }
}

fn foreign_key_record(key: &ForeignKeyInfo) -> ForeignKeyInput {
    ForeignKeyInput {
        name: key.name.clone(),
        columns: key.columns.clone(),
        ref_schema: key.ref_schema.clone(),
        ref_table: key.ref_table.clone(),
        ref_columns: key.ref_columns.clone(),
        on_delete: key.on_delete.map(action_tag),
        on_update: key.on_update.map(action_tag),
    }
}

fn action_tag(action: ReferentialAction) -> ReferentialActionTag {
    match action {
        ReferentialAction::NoAction => ReferentialActionTag::NoAction,
        ReferentialAction::Restrict => ReferentialActionTag::Restrict,
        ReferentialAction::Cascade => ReferentialActionTag::Cascade,
        ReferentialAction::SetNull => ReferentialActionTag::SetNull,
        ReferentialAction::SetDefault => ReferentialActionTag::SetDefault,
    }
}

fn destructive_tag(change: &DestructiveChange) -> DestructiveChangeTag {
    match change {
        DestructiveChange::RebuildTable(rebuild) => DestructiveChangeTag::RebuildTable {
            recreated: rebuild.recreated.iter().map(|object| object.name.clone()).collect(),
            renumbers_rowids: rebuild.renumbers_rowids,
        },
        DestructiveChange::DropColumn { column } => DestructiveChangeTag::DropColumn { column: column.clone() },
        DestructiveChange::ChangeColumnType { column, from, to } => DestructiveChangeTag::ChangeColumnType {
            column: column.clone(),
            from: from.clone(),
            to: to.clone(),
        },
        DestructiveChange::SetNotNull { column } => DestructiveChangeTag::SetNotNull { column: column.clone() },
        DestructiveChange::ConvertCharacterSet => DestructiveChangeTag::ConvertCharacterSet,
        DestructiveChange::ChangeColumnCharacterSet { column } => {
            DestructiveChangeTag::ChangeColumnCharacterSet { column: column.clone() }
        }
        DestructiveChange::DropIndex { index } => DestructiveChangeTag::DropIndex { index: index.clone() },
        DestructiveChange::DropForeignKey { key } => DestructiveChangeTag::DropForeignKey { key: key.clone() },
    }
}

fn blocker_tag(blocker: SaveBlocker) -> SaveBlockerTag {
    match blocker {
        SaveBlocker::Draft(problem) => SaveBlockerTag::Draft {
            code: problem.code().to_owned(),
        },
        SaveBlocker::UnparsedDefault(column) => SaveBlockerTag::UnparsedDefault { column },
        // An invalid auto-increment never crosses the boundary: the app sends a parsed number or none.
        SaveBlocker::InvalidAutoIncrement => SaveBlockerTag::Draft {
            code: "ddl.invalid_auto_increment".to_owned(),
        },
    }
}

fn blocker_error(blocker: &SaveBlocker) -> CoreError {
    match blocker {
        SaveBlocker::Draft(problem) => CoreError::failed(problem.code(), "the draft cannot be saved as it stands"),
        SaveBlocker::UnparsedDefault(column) => CoreError::failed(
            "designer.unparsed_default",
            format!("the default for {column} is not a value the column takes"),
        ),
        SaveBlocker::InvalidAutoIncrement => {
            CoreError::failed("ddl.invalid_auto_increment", "the next auto-increment is not a value")
        }
    }
}

// A structure change that drops or loses something asks at every level but Read-only; one that only adds asks where
// Safe Mode asks before every write.
fn access_of(review: &ChangeReview) -> StatementAccess {
    match review.destructive.is_empty() {
        true => StatementAccess::Write,
        false => StatementAccess::Destructive,
    }
}

fn designer_gate(level: SafeModeLevel, access: StatementAccess, read_only: bool) -> SaveGate {
    if read_only {
        return SaveGate::Refuse;
    }
    match level.gate(access) {
        WriteGate::Run => SaveGate::Run,
        WriteGate::Confirm => SaveGate::Confirm,
        WriteGate::Refuse => SaveGate::Refuse,
    }
}

// What the server holds now decides, as a row save reads it.
fn outcome(
    written: Result<WriteReport, OperationError>,
    resolution: Option<Result<CommitResolution, OperationError>>,
) -> TableSaveOutcome {
    let error = match written {
        Ok(_) => return TableSaveOutcome::Done,
        Err(error) => error,
    };
    let info = || CoreError::from(&error).into_info();
    match &error {
        OperationError::Driver(DriverError::CommitOutcomeUnknown { .. }) => match resolution {
            Some(Ok(CommitResolution::Applied)) => TableSaveOutcome::Done,
            Some(Ok(CommitResolution::NotApplied)) => TableSaveOutcome::Failed { error: info() },
            _ => TableSaveOutcome::Unknown { error: info() },
        },
        OperationError::Driver(DriverError::PartiallyApplied { .. }) => TableSaveOutcome::Unknown { error: info() },
        OperationError::Driver(driver)
            if matches!(
                driver.category(),
                ErrorCategory::Interrupted | ErrorCategory::Timeout | ErrorCategory::ConnectionLost
            ) =>
        {
            TableSaveOutcome::Unknown { error: info() }
        }
        OperationError::Cancelled | OperationError::Panicked(_) | OperationError::Closed => {
            TableSaveOutcome::Unknown { error: info() }
        }
        _ => TableSaveOutcome::Failed { error: info() },
    }
}

fn build_error(error: BuildDdlError) -> CoreError {
    CoreError::failed("designer.refused", error.to_string())
}

fn safe_mode_changed() -> CoreError {
    CoreError::failed(
        "designer.safe_mode_changed",
        "the connection's Safe Mode changed after the change was planned",
    )
}

fn not_connected() -> CoreError {
    CoreError::failed("ffi.not_connected", "the session has no connection")
}

impl std::fmt::Debug for TableDesigner {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("TableDesigner")
            .field("original", &self.original.as_ref().map(|original| &original.table))
            .finish_non_exhaustive()
    }
}
