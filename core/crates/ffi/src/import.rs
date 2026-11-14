use std::io::Read;
use std::ops::Range;
use std::path::PathBuf;
use std::sync::{Arc, Mutex, PoisonError};
use std::time::Duration;

use tablepro_core::dialect::SqlDialect;
use tablepro_core::edit::CellInput;
use tablepro_core::export::CsvDelimiter;
use tablepro_core::import::{
    CsvImportOptions, CsvRowError, ImportColumn, ImportError, MAX_CSV_FILE_BYTES, MAX_PREVIEW_ROWS, padded_row,
    plan_import, read_csv, read_csv_records, row_to_cells, suggest_mapping,
};
use tablepro_core::meta::TableRef;
use tablepro_core::{CallOptions, DriverError, ErrorCategory, WriteBatch, WriteKind};
use tablepro_session::runtime::Tasks;
use tablepro_session::{OperationError, OperationKind, Session};

use crate::cancel_token::{CancelToken, token};
use crate::catalog::TableName;
use crate::error::{BoxedErrorInfo, CoreError};
use crate::row_edits::{SaveGate, save_gate};
use crate::runtime::on_runtime;
use crate::session::DatabaseSession;

// As the Linux import allows: each statement gets this much on top of the call's own deadline.
const TIME_PER_STATEMENT: Duration = Duration::from_secs(5);

#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum CsvDelimiterTag {
    Comma,
    Semicolon,
    Tab,
    Pipe,
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct CsvReadOptions {
    pub delimiter: CsvDelimiterTag,
    // The first record names the fields.
    pub has_header: bool,
    // A field holding exactly this reads as NULL. Empty by default, as every export writes NULL.
    pub null_text: String,
}

// Headers are empty strings when the file has none, one per field of the widest row.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct CsvPreview {
    pub headers: Vec<String>,
    pub rows: Vec<Vec<String>>,
    // More rows follow the ones shown; the import reads them all.
    pub truncated: bool,
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct ImportColumnInfo {
    pub name: String,
    pub type_name: String,
    pub nullable: bool,
    pub has_default: bool,
    // A generated column or an identity that refuses a value: no field is ever mapped to it.
    pub server_filled: bool,
    // An empty field is an empty value here rather than NULL, when the NULL text is empty.
    pub takes_empty: bool,
}

// A field the column's type cannot read. `line` counts the header as line 1, as a spreadsheet shows it.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct CsvRowFault {
    pub line: u64,
    pub column: String,
    pub text: String,
    // The edit parse error's code, as a cell edit refused for the same reason has.
    pub reason: String,
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Enum)]
pub enum CsvImportCheck {
    // `statements` are the SQL texts the rows write as, in order; Safe Mode shows them before a confirmed run.
    // `plan` names this plan to `run`, so a plan replaced since is never the one written.
    Ready {
        plan: u64,
        rows: u64,
        statements: Vec<String>,
        gate: SaveGate,
    },
    // The file has no rows past its header.
    Empty,
    RowRefused {
        fault: CsvRowFault,
    },
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Enum)]
pub enum CsvImportOutcome {
    Imported {
        rows: u64,
    },
    // Nothing was written. The lines are those of the statement that failed, when the engine said which.
    RolledBack {
        error: BoxedErrorInfo,
        lines: Option<LineSpan>,
    },
    // The engine has no transaction to undo the import: `written_rows` rows before the failed lines stay.
    PartlyWritten {
        error: BoxedErrorInfo,
        written_rows: u64,
        lines: Option<LineSpan>,
    },
    // Stopped, or the connection went before the server answered: the table may hold some rows or none.
    Unknown {
        error: BoxedErrorInfo,
    },
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Record)]
pub struct LineSpan {
    pub first: u64,
    pub last: u64,
}

// A table's columns as a CSV import writes them, and the import planned last.
#[derive(uniffi::Object)]
pub struct CsvImport {
    session: Arc<Session>,
    tasks: Tasks,
    table: TableRef,
    columns: Arc<[ImportColumn]>,
    plans: Mutex<Plans>,
}

// The last plan begun and the one ready to run, changed together so a slower plan never replaces a later one.
#[derive(Default)]
struct Plans {
    last: u64,
    ready: Option<Planned>,
}

struct Planned {
    id: u64,
    batch: Arc<WriteBatch>,
    step_rows: Vec<Range<usize>>,
    first_line: usize,
    rows: usize,
    gate: SaveGate,
}

#[uniffi::export]
impl DatabaseSession {
    // The table's columns as the server defines them now.
    pub async fn open_csv_import(
        &self,
        table: TableName,
        cancel: Option<Arc<CancelToken>>,
    ) -> Result<Arc<CsvImport>, CoreError> {
        let session = self.session().clone();
        let tasks = self.tasks().clone();
        let cancel = token(cancel);
        on_runtime(self.tasks(), async move {
            let table: TableRef = table.into();
            let definition = session
                .run_cancellable(OperationKind::Metadata, &cancel, |lease, options| {
                    let table = table.clone();
                    async move { Ok(lease.fetch_table_definition(&table, options).await?) }
                })
                .await?;
            let columns: Arc<[ImportColumn]> = definition.columns.iter().map(ImportColumn::from_definition).collect();
            if columns.is_empty() {
                return Err(CoreError::failed("import.no_table_columns", "the table has no columns"));
            }
            Ok(Arc::new(CsvImport {
                session,
                tasks,
                table,
                columns,
                plans: Mutex::new(Plans::default()),
            }))
        })
        .await
    }
}

#[uniffi::export]
impl CsvImport {
    pub fn columns(&self) -> Vec<ImportColumnInfo> {
        self.columns
            .iter()
            .map(|column| ImportColumnInfo {
                name: column.info.name.clone(),
                type_name: column.info.column_type.name.clone(),
                nullable: column.info.nullable,
                has_default: !column.info.default.is_none(),
                server_filled: column.server_filled,
                takes_empty: column.info.column_type.kind.accepts_empty_string(),
            })
            .collect()
    }

    // The first rows, enough to judge the delimiter and the header.
    pub async fn preview(&self, path: String, options: CsvReadOptions) -> Result<CsvPreview, CoreError> {
        let options = CsvImportOptions::from(options);
        blocking(&self.tasks, move || {
            let bytes = read_file(&path)?;
            let sheet = read_csv(&bytes, &options, Some(MAX_PREVIEW_ROWS)).map_err(read_error)?;
            Ok(CsvPreview {
                headers: sheet.headers,
                rows: sheet.rows,
                truncated: sheet.truncated,
            })
        })
        .await
    }

    // Per column, the field whose header names it, ignoring case and surrounding space; never a server-filled one.
    pub fn suggest_mapping(&self, headers: Vec<String>) -> Vec<Option<u32>> {
        suggest_mapping(&headers, &self.columns)
            .into_iter()
            .map(|field| field.and_then(|field| u32::try_from(field).ok()))
            .collect()
    }

    // Reads the whole file and plans its rows into the table, `mapping` naming a field per column (None leaves the
    // column to its default). The plan replaces any planned before and is what `run` writes.
    pub async fn plan(
        &self,
        path: String,
        options: CsvReadOptions,
        mapping: Vec<Option<u32>>,
    ) -> Result<CsvImportCheck, CoreError> {
        if mapping.len() != self.columns.len() {
            return Err(CoreError::failed(
                "import.mapping_invalid",
                format!("{} fields mapped for {} columns", mapping.len(), self.columns.len()),
            ));
        }
        let id = {
            let mut plans = self.plans();
            plans.last = plans.last.wrapping_add(1);
            plans.ready = None;
            plans.last
        };
        let dialect = self
            .session
            .current_dialect()
            .ok_or_else(|| CoreError::failed("ffi.not_connected", "the session has no connection"))?;
        let gate = save_gate(self.session.safe_mode());
        let columns = self.columns.clone();
        let table = self.table.clone();
        let options = CsvImportOptions::from(options);
        let planned = blocking(&self.tasks, move || {
            plan_file(id, &path, &options, &mapping, &columns, &table, &*dialect, gate)
        })
        .await?;
        let check = match &planned {
            Ok(Some(planned)) => CsvImportCheck::Ready {
                plan: planned.id,
                rows: u64::try_from(planned.rows).unwrap_or(u64::MAX),
                statements: planned
                    .batch
                    .steps
                    .iter()
                    .map(|step| step.statement.sql().to_owned())
                    .collect(),
                gate: planned.gate,
            },
            Ok(None) => CsvImportCheck::Empty,
            Err(fault) => CsvImportCheck::RowRefused { fault: fault.clone() },
        };
        if let Ok(Some(planned)) = planned {
            // A plan that finishes after a later one began is dropped, whatever order they end in.
            let mut plans = self.plans();
            if plans.last != id {
                return Err(CoreError::failed(
                    "import.plan_replaced",
                    "a later plan replaced this one",
                ));
            }
            plans.ready = Some(planned);
        }
        Ok(check)
    }

    // Writes the plan `plan` names, once, while it is the last one made. `confirmed` says the user answered Safe Mode's
    // question; a level saved since the plan refuses before anything is sent.
    pub async fn run(
        &self,
        plan: u64,
        confirmed: bool,
        cancel: Option<Arc<CancelToken>>,
    ) -> Result<CsvImportOutcome, CoreError> {
        // Checked before the plan is taken, so a refusal leaves it to run once answered.
        let planned = {
            let mut plans = self.plans();
            let Some(planned) = plans.ready.as_ref().filter(|planned| planned.id == plan) else {
                return Err(CoreError::failed("import.not_planned", "no import is planned"));
            };
            if planned.gate == SaveGate::Confirm && !confirmed {
                return Err(CoreError::failed(
                    "import.not_confirmed",
                    "Safe Mode asks before this import and it was not answered",
                ));
            }
            match save_gate(self.session.safe_mode()) {
                SaveGate::Refuse => {
                    return Err(CoreError::failed(
                        "edit.read_only_connection",
                        "the connection is read-only",
                    ));
                }
                now if now != planned.gate => return Err(safe_mode_changed()),
                _ => {}
            }
            plans.ready.take()
        };
        let Some(planned) = planned else {
            return Err(CoreError::failed("import.not_planned", "no import is planned"));
        };
        let session = self.session.clone();
        let cancel = token(cancel);
        on_runtime(&self.tasks, async move {
            let gated = session.clone();
            let batch = planned.batch.clone();
            let gate = planned.gate;
            let written = session
                .run_cancellable(
                    OperationKind::Save(WriteKind::RowChanges),
                    &cancel,
                    move |lease, options| {
                        let (batch, gated) = (batch.clone(), gated.clone());
                        async move {
                            // Checked again on the lease, so a level saved while the import waited for it holds.
                            if save_gate(gated.safe_mode()) != gate {
                                return Ok(Err(safe_mode_changed()));
                            }
                            let options = with_time_for(options, batch.steps.len());
                            Ok(Ok(lease.write_batch(&batch, options).await?))
                        }
                    },
                )
                .await;
            match written {
                Ok(Err(refused)) => Err(refused),
                Ok(Ok(_)) => Ok(CsvImportOutcome::Imported {
                    rows: u64::try_from(planned.rows).unwrap_or(u64::MAX),
                }),
                Err(error) => Ok(failed(&error, &planned)),
            }
        })
        .await
    }
}

impl CsvImport {
    fn plans(&self) -> std::sync::MutexGuard<'_, Plans> {
        self.plans.lock().unwrap_or_else(PoisonError::into_inner)
    }
}

#[expect(
    clippy::too_many_arguments,
    reason = "one call, from plan, with what it read from the import"
)]
fn plan_file(
    id: u64,
    path: &str,
    options: &CsvImportOptions,
    mapping: &[Option<u32>],
    columns: &[ImportColumn],
    table: &TableRef,
    dialect: &dyn SqlDialect,
    gate: SaveGate,
) -> Result<Result<Option<Planned>, CsvRowFault>, CoreError> {
    let bytes = read_file(path)?;
    let records = read_csv_records(&bytes, options, None).map_err(read_error)?;
    drop(bytes);
    let width = records.width;
    let mapping: Vec<Option<usize>> = mapping
        .iter()
        .map(|field| field.and_then(|field| usize::try_from(field).ok()))
        .collect();
    if let Some(field) = mapping.iter().flatten().find(|field| **field >= width) {
        return Err(CoreError::failed(
            "import.mapping_invalid",
            format!("field {field} is past the file's {width} fields"),
        ));
    }
    if records.rows.is_empty() {
        return Ok(Ok(None));
    }
    let first_line = if options.has_header { 2 } else { 1 };
    let mut rows: Vec<Vec<CellInput>> = Vec::with_capacity(records.rows.len());
    // One row padded at a time, as read_csv pads them all, so a wide record cannot multiply every other row.
    for (index, row) in records.rows.into_iter().enumerate() {
        let row = padded_row(row, width);
        match row_to_cells(&row, &mapping, columns, options, first_line + index) {
            Ok(cells) => rows.push(cells),
            Err(error) => return Ok(Err(CsvRowFault::from(error))),
        }
    }
    let count = rows.len();
    let plan = plan_import(dialect, table, columns, rows)
        .map_err(|error| CoreError::failed(error.code(), error.to_string()))?;
    Ok(Ok(Some(Planned {
        id,
        batch: Arc::new(plan.batch),
        step_rows: plan.step_rows,
        first_line,
        rows: count,
        gate,
    })))
}

fn read_file(path: &str) -> Result<Vec<u8>, CoreError> {
    let path = PathBuf::from(path);
    let unreadable = |error: std::io::Error| {
        let mut failed = CoreError::failed("import.unreadable", format!("{}: {error}", path.display()));
        if let CoreError::Failed { info } = &mut failed {
            info.path = Some(path.display().to_string());
        }
        failed
    };
    let file = std::fs::File::open(&path).map_err(&unreadable)?;
    // Every row becomes part of one write held in memory, so a file past the cap is refused, not read whole.
    let cap = u64::try_from(MAX_CSV_FILE_BYTES).unwrap_or(u64::MAX);
    let mut bytes = Vec::new();
    file.take(cap.saturating_add(1))
        .read_to_end(&mut bytes)
        .map_err(&unreadable)?;
    if bytes.len() > MAX_CSV_FILE_BYTES {
        return Err(CoreError::failed(
            "import.too_large",
            format!("the file is past the {MAX_CSV_FILE_BYTES} bytes an import reads"),
        ));
    }
    Ok(bytes)
}

fn read_error(error: ImportError) -> CoreError {
    let code = match &error {
        ImportError::NotUtf8 { .. } => "import.not_utf8",
        ImportError::Malformed { .. } => "import.malformed",
        ImportError::NoColumns => "import.no_columns",
        ImportError::TooManyFields { .. } => "import.too_many_fields",
    };
    CoreError::failed(code, error.to_string())
}

fn with_time_for(options: CallOptions, statements: usize) -> CallOptions {
    let extra = TIME_PER_STATEMENT.saturating_mul(u32::try_from(statements).unwrap_or(u32::MAX));
    CallOptions::new(
        options.deadline().map(|deadline| deadline + extra),
        options.cancel().clone(),
    )
}

fn safe_mode_changed() -> CoreError {
    CoreError::failed(
        "import.safe_mode_changed",
        "the connection's Safe Mode changed after the import was planned",
    )
}

// As the Linux import words a failure: by the lines of the file the failed statement held.
fn failed(error: &OperationError, planned: &Planned) -> CsvImportOutcome {
    let info = || CoreError::from(error).into_info();
    let lines = |step: usize| {
        planned.step_rows.get(step).map(|rows| LineSpan {
            first: line(planned.first_line + rows.start),
            last: line(planned.first_line + rows.end.saturating_sub(1)),
        })
    };
    match error {
        OperationError::Driver(driver) => match driver {
            DriverError::RolledBack { statement_index, .. }
            | DriverError::RowGuardFailed { statement_index, .. }
            | DriverError::GuardUnsupported { statement_index } => CsvImportOutcome::RolledBack {
                error: info(),
                lines: lines(*statement_index),
            },
            DriverError::PartiallyApplied { statement_index, .. } => {
                let written: usize = planned
                    .step_rows
                    .iter()
                    .take(*statement_index)
                    .map(ExactSizeIterator::len)
                    .sum();
                CsvImportOutcome::PartlyWritten {
                    error: info(),
                    written_rows: line(written),
                    lines: lines(*statement_index),
                }
            }
            DriverError::ReadOnly(_) => CsvImportOutcome::RolledBack {
                error: info(),
                lines: None,
            },
            DriverError::CommitOutcomeUnknown { .. } => CsvImportOutcome::Unknown { error: info() },
            other => match other.category() {
                ErrorCategory::Interrupted | ErrorCategory::Timeout | ErrorCategory::ConnectionLost => {
                    CsvImportOutcome::Unknown { error: info() }
                }
                _ => CsvImportOutcome::RolledBack {
                    error: info(),
                    lines: None,
                },
            },
        },
        OperationError::Sql(_) | OperationError::Build(_) | OperationError::Browse(_) => CsvImportOutcome::RolledBack {
            error: info(),
            lines: None,
        },
        OperationError::Cancelled | OperationError::Panicked(_) | OperationError::Closed => {
            CsvImportOutcome::Unknown { error: info() }
        }
    }
}

fn line(value: usize) -> u64 {
    u64::try_from(value).unwrap_or(u64::MAX)
}

async fn blocking<T, F>(tasks: &Tasks, work: F) -> Result<T, CoreError>
where
    T: Send + 'static,
    F: FnOnce() -> Result<T, CoreError> + Send + 'static,
{
    let runner = tasks.clone();
    on_runtime(tasks, async move {
        runner
            .spawn_blocking_task(work)
            .await
            .map_err(|failure| CoreError::failed("ffi.panicked", failure.to_string()))?
    })
    .await
}

impl From<CsvReadOptions> for CsvImportOptions {
    fn from(options: CsvReadOptions) -> Self {
        Self {
            delimiter: match options.delimiter {
                CsvDelimiterTag::Comma => CsvDelimiter::Comma,
                CsvDelimiterTag::Semicolon => CsvDelimiter::Semicolon,
                CsvDelimiterTag::Tab => CsvDelimiter::Tab,
                CsvDelimiterTag::Pipe => CsvDelimiter::Pipe,
            },
            has_header: options.has_header,
            null_marker: options.null_text,
        }
    }
}

impl From<CsvRowError> for CsvRowFault {
    fn from(error: CsvRowError) -> Self {
        Self {
            line: line(error.line),
            column: error.column,
            text: error.text,
            reason: error.reason.code().to_owned(),
        }
    }
}

impl std::fmt::Debug for CsvImport {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("CsvImport")
            .field("table", &self.table)
            .finish_non_exhaustive()
    }
}
