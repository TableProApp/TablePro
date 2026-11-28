use tablepro_core::TransactionState;
use tablepro_core::script_run::{BatchErrorPolicy, ResultSetSummary, ScriptBatchReport, ScriptEntry, Verdict};

use crate::error::{BoxedErrorInfo, CoreError};
use crate::run::{TransactionStateTag, TruncationTag};

/// One unit the script sends: a statement, or a whole `GO` batch on SQL
/// Server. The app splits the text with `SqlSyntax.Statements` and fills
/// these.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct ScriptBatch {
    pub text: String,
    /// How many times `GO n` asks for it; 0 and 1 send it once.
    pub repeat: u32,
    /// Where the batch starts in the buffer, in characters, so a server's
    /// error position becomes a buffer position.
    pub error_base: u64,
    /// Safe Mode is Read-Only and the batch writes, so it is not sent.
    pub refused: bool,
}

/// Whether the script stops after a batch fails. The app reads it off the
/// script with `SqlSyntax`, or defaults to stopping.
#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum BatchErrorPolicyTag {
    StopScript,
    ContinueNextBatch,
}

impl From<BatchErrorPolicyTag> for BatchErrorPolicy {
    fn from(tag: BatchErrorPolicyTag) -> Self {
        match tag {
            BatchErrorPolicyTag::StopScript => Self::StopScript,
            BatchErrorPolicyTag::ContinueNextBatch => Self::ContinueNextBatch,
        }
    }
}

/// How one batch ended, for deciding whether the next ran.
#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum VerdictTag {
    Completed,
    Failed,
    Stopped,
}

impl From<Verdict> for VerdictTag {
    fn from(verdict: Verdict) -> Self {
        match verdict {
            Verdict::Completed => Self::Completed,
            Verdict::Failed => Self::Failed,
            Verdict::Stopped => Self::Stopped,
        }
    }
}

/// One line of a batch's log. Errors carry a code; the app words them.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Enum)]
pub enum ScriptEntryInfo {
    /// A result set, readable through `ScriptRun::result_set(set_index)`.
    ResultSet {
        set_index: u32,
        retained: u64,
        total_rows: Option<u64>,
        truncation: TruncationTag,
        /// The run's row limit, when it cut this set short.
        run_limit: Option<u64>,
        /// The run's byte limit, when it cut this set short.
        size_limit: Option<u64>,
    },
    Command {
        rows_affected: Option<u64>,
    },
    Notice {
        severity: String,
        message: String,
        code: Option<String>,
    },
    NoticeLimitReached {
        retained: u64,
    },
    Failed {
        info: BoxedErrorInfo,
        /// Where the server says the error is in the buffer, in
        /// characters, when it says.
        error_char: Option<u64>,
        /// The session's connection went with this batch.
        lost: bool,
        /// A transaction was open on the session when the batch was sent.
        in_transaction: bool,
    },
    Cancelled,
    TimedOut {
        server_cancelled: bool,
    },
}

/// One batch's report, or the run's end. Per batch, in order; `Finished`
/// is the last event.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Enum)]
pub enum ScriptRunEvent {
    Batch {
        batch_index: u32,
        entries: Vec<ScriptEntryInfo>,
        verdict: VerdictTag,
        /// Where the batch left the transaction, as far as a connection
        /// still there said.
        transaction: TransactionStateTag,
        /// The editor session's connection is gone.
        lost: bool,
        elapsed_ms: u64,
    },
    Finished {
        /// The transaction the editor's connection is left in.
        transaction: TransactionStateTag,
        /// The session is gone, so the next run opens a new one.
        lost: bool,
        /// The run lost the connection with a transaction open, and its
        /// reports already say it was rolled back.
        rolled_back: bool,
    },
}

/// The run's end, for `ScriptRun::outcome`.
#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Record)]
pub struct ScriptRunSummary {
    pub transaction: TransactionStateTag,
    pub lost: bool,
    pub rolled_back: bool,
}

fn truncation(summary: &ResultSetSummary) -> TruncationTag {
    summary.truncation.into()
}

impl ScriptEntryInfo {
    fn of(entry: ScriptEntry) -> Self {
        match entry {
            ScriptEntry::ResultSet { set_index, summary } => Self::ResultSet {
                set_index: u32::try_from(set_index).unwrap_or(u32::MAX),
                retained: summary.retained,
                total_rows: summary.total_rows,
                truncation: truncation(&summary),
                run_limit: summary.run_limit,
                size_limit: summary.size_limit,
            },
            ScriptEntry::Command { rows_affected } => Self::Command { rows_affected },
            ScriptEntry::Notice {
                severity,
                message,
                code,
            } => Self::Notice {
                severity,
                message,
                code: code.as_ref().map(ToString::to_string),
            },
            ScriptEntry::NoticeLimitReached { retained } => Self::NoticeLimitReached { retained },
            ScriptEntry::Failed {
                error,
                error_char,
                lost,
                in_transaction,
            } => Self::Failed {
                info: CoreError::from(error).into_info(),
                error_char: error_char.map(|position| position as u64),
                lost,
                in_transaction,
            },
            ScriptEntry::Cancelled => Self::Cancelled,
            ScriptEntry::TimedOut { server_cancelled } => Self::TimedOut { server_cancelled },
        }
    }
}

impl ScriptRunEvent {
    pub(super) fn batch(report: ScriptBatchReport) -> Self {
        Self::Batch {
            batch_index: u32::try_from(report.batch).unwrap_or(u32::MAX),
            entries: report.entries.into_iter().map(ScriptEntryInfo::of).collect(),
            verdict: report.verdict.into(),
            transaction: transaction_tag(report.transaction),
            lost: report.lost,
            elapsed_ms: u64::try_from(report.elapsed_ms).unwrap_or(u64::MAX),
        }
    }
}

pub(super) fn transaction_tag(transaction: Option<TransactionState>) -> TransactionStateTag {
    transaction.map_or(TransactionStateTag::Unknown, Into::into)
}
