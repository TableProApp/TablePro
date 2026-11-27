use std::path::PathBuf;
use std::sync::Arc;
use std::sync::atomic::{AtomicU64, Ordering};

use tablepro_core::EditorSessionOptions;
use tablepro_core::import::{
    SqlImportEnd, SqlImportErrorPolicy, SqlImportFailure, SqlImportFault, SqlImportOptions, SqlImportReport,
    TransactionOutcome, run_sql_import,
};
use tablepro_core::sql_syntax::script::RefusedUnit;

use crate::cancel_token::{CancelToken, token};
use crate::error::{BoxedErrorInfo, CoreError};
use crate::export::blocking;
use crate::runtime::on_runtime;
use crate::session::DatabaseSession;

#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum SqlImportErrorPolicyTag {
    // Stop at the first statement that fails, as psql with `ON_ERROR_STOP` does.
    Stop,
    // Note it and go on, as `mysql --force` does.
    Continue,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Record)]
pub struct SqlImportOptionsArg {
    pub on_error: SqlImportErrorPolicyTag,
    // Run the whole file as one transaction, on an engine whose DDL rolls back. Only with Stop.
    pub one_transaction: bool,
}

impl From<SqlImportOptionsArg> for SqlImportOptions {
    fn from(options: SqlImportOptionsArg) -> Self {
        Self {
            on_error: match options.on_error {
                SqlImportErrorPolicyTag::Stop => SqlImportErrorPolicy::Stop,
                SqlImportErrorPolicyTag::Continue => SqlImportErrorPolicy::Continue,
            },
            one_transaction: options.one_transaction,
        }
    }
}

// What a SQL file import has done so far, which the app reads while it runs, as ExportProgress does for a row export.
#[derive(Debug, Default, uniffi::Object)]
pub struct SqlImportProgress {
    bytes_read: AtomicU64,
    statements: AtomicU64,
    failed: AtomicU64,
}

#[uniffi::export]
impl SqlImportProgress {
    #[uniffi::constructor]
    pub fn new() -> Arc<Self> {
        Arc::new(Self::default())
    }

    // Bytes of the file read, before any read ahead.
    pub fn bytes_read(&self) -> u64 {
        self.bytes_read.load(Ordering::Relaxed)
    }

    pub fn statements(&self) -> u64 {
        self.statements.load(Ordering::Relaxed)
    }

    pub fn failed(&self) -> u64 {
        self.failed.load(Ordering::Relaxed)
    }
}

impl SqlImportProgress {
    fn set(&self, progress: tablepro_core::import::SqlImportProgress) {
        self.bytes_read.store(progress.bytes_read, Ordering::Relaxed);
        self.statements.store(progress.statements, Ordering::Relaxed);
        self.failed.store(progress.failed, Ordering::Relaxed);
    }
}

#[derive(Debug, Clone, PartialEq, uniffi::Enum)]
pub enum SqlImportEndTag {
    Completed,
    // A statement failed and the import stopped there.
    Stopped,
    Cancelled,
    // The file could not be read; `code` is the read error's.
    FileError { code: String, message: String },
    // The editor session itself failed, as on a lost connection.
    SessionError { error: BoxedErrorInfo },
}

#[derive(Debug, Clone, PartialEq, uniffi::Enum)]
pub enum TransactionOutcomeTag {
    // Every statement committed as it ran, or the file's own transactions decided.
    AsWritten,
    Committed,
    RolledBack,
    // The file left a transaction of its own open, and it was rolled back.
    OpenRolledBack,
    // The commit or rollback failed, so what the server kept is unknown.
    Unknown { error: BoxedErrorInfo },
}

#[derive(Debug, Clone, PartialEq, uniffi::Enum)]
pub enum SqlImportFaultTag {
    // The server refused the statement.
    Statement { error: BoxedErrorInfo },
    // A psql meta-command nothing here runs.
    ClientCommand { command: String },
    // A COPY FROM stdin in the binary format, whose rows a script cannot hold.
    CopyBinary,
    // The file ended the transaction the import ran it in.
    FileEndsTransaction,
}

#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct SqlImportFailureRecord {
    pub line: u64,
    pub statement: String,
    pub fault: SqlImportFaultTag,
}

#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct SqlImportReportRecord {
    pub end: SqlImportEndTag,
    // Statements the server ran, each `GO n` repeat counted.
    pub statements: u64,
    // Lines passed over: client-only lines and the file's own transaction statements inside the import's transaction.
    pub skipped: u64,
    pub failed: u64,
    pub failures: Vec<SqlImportFailureRecord>,
    pub transaction: TransactionOutcomeTag,
    pub elapsed_ms: u64,
}

#[uniffi::export]
impl DatabaseSession {
    // Run a SQL file on an editor session of the import's own, a statement at a time, as the engine's own client
    // would. The file is read on a blocking thread a piece at a time and never held whole.
    pub async fn import_sql_file(
        &self,
        path: String,
        options: SqlImportOptionsArg,
        progress: Option<Arc<SqlImportProgress>>,
        cancel: Option<Arc<CancelToken>>,
    ) -> Result<SqlImportReportRecord, CoreError> {
        let session = self.session().clone();
        let tasks = self.tasks().clone();
        let cancel = token(cancel);
        let options = SqlImportOptions::from(options);
        on_runtime(self.tasks(), async move {
            let dialect = session
                .current_dialect()
                .ok_or_else(|| CoreError::failed("ffi.not_connected", "the session has no connection"))?;
            let opened = PathBuf::from(&path);
            let file = blocking(&tasks, move || {
                std::fs::File::open(&opened).map_err(|error| {
                    let mut failed = CoreError::failed("sql_import.unreadable", format!("{path}: {error}"));
                    if let CoreError::Failed { info } = &mut failed {
                        info.path = Some(path);
                    }
                    failed
                })
            })
            .await?;
            let editor = session
                .open_editor_session(EditorSessionOptions::default(), &cancel)
                .await?;
            let mut report_progress = |latest: tablepro_core::import::SqlImportProgress| {
                if let Some(sink) = &progress {
                    sink.set(latest);
                }
            };
            let report = run_sql_import(
                editor.as_ref(),
                &*dialect,
                Box::new(file),
                options,
                &mut report_progress,
                &cancel,
            )
            .await;
            editor.close().await;
            Ok(report_record(report))
        })
        .await
    }
}

fn report_record(report: SqlImportReport) -> SqlImportReportRecord {
    SqlImportReportRecord {
        end: end_tag(report.end),
        statements: report.statements,
        skipped: report.skipped,
        failed: report.failed,
        failures: report.failures.into_iter().map(failure_record).collect(),
        transaction: transaction_tag(report.transaction),
        elapsed_ms: u64::try_from(report.elapsed.as_millis()).unwrap_or(u64::MAX),
    }
}

fn end_tag(end: SqlImportEnd) -> SqlImportEndTag {
    match end {
        SqlImportEnd::Completed => SqlImportEndTag::Completed,
        SqlImportEnd::Stopped => SqlImportEndTag::Stopped,
        SqlImportEnd::Cancelled => SqlImportEndTag::Cancelled,
        SqlImportEnd::File(error) => SqlImportEndTag::FileError {
            code: error.code().to_owned(),
            message: error.to_string(),
        },
        SqlImportEnd::Session(error) => SqlImportEndTag::SessionError {
            error: CoreError::from(error).into_info(),
        },
    }
}

fn transaction_tag(outcome: TransactionOutcome) -> TransactionOutcomeTag {
    match outcome {
        TransactionOutcome::AsWritten => TransactionOutcomeTag::AsWritten,
        TransactionOutcome::Committed => TransactionOutcomeTag::Committed,
        TransactionOutcome::RolledBack => TransactionOutcomeTag::RolledBack,
        TransactionOutcome::OpenRolledBack => TransactionOutcomeTag::OpenRolledBack,
        TransactionOutcome::Unknown(error) => TransactionOutcomeTag::Unknown {
            error: CoreError::from(error).into_info(),
        },
    }
}

fn failure_record(failure: SqlImportFailure) -> SqlImportFailureRecord {
    SqlImportFailureRecord {
        line: failure.line,
        statement: failure.statement,
        fault: fault_tag(failure.fault),
    }
}

fn fault_tag(fault: SqlImportFault) -> SqlImportFaultTag {
    match fault {
        SqlImportFault::Statement(error) => SqlImportFaultTag::Statement {
            error: CoreError::from(error).into_info(),
        },
        SqlImportFault::Refused(RefusedUnit::ClientCommand { command }) => SqlImportFaultTag::ClientCommand { command },
        SqlImportFault::Refused(RefusedUnit::CopyBinary) => SqlImportFaultTag::CopyBinary,
        SqlImportFault::FileEndsTransaction => SqlImportFaultTag::FileEndsTransaction,
    }
}
