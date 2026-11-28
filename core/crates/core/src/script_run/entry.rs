use crate::error::DriverError;
use crate::result_event::Truncation;
use crate::server_diagnostics::ServerCode;
use crate::transaction_state::TransactionState;

use super::BatchErrorPolicy;

/// How much of a result set a run kept, as the driver reported it when
/// the set ended. Carries no worded sentence; an app writes the banner.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct ResultSetSummary {
    /// The rows the result holds.
    pub retained: u64,
    /// What the server says the whole set held, when it says.
    pub total_rows: Option<u64>,
    pub truncation: Truncation,
    /// The run's limit on the rows of all its results, when that limit
    /// cut this one short.
    pub run_limit: Option<u64>,
    /// The run's limit on the bytes of all its results, when that limit
    /// cut this one short.
    pub size_limit: Option<u64>,
}

impl ResultSetSummary {
    /// A set that has not ended, or ended with every row it held.
    pub fn complete(retained: u64) -> Self {
        Self {
            retained,
            total_rows: None,
            truncation: Truncation::Complete,
            run_limit: None,
            size_limit: None,
        }
    }
}

/// One line of a batch's structured log. Errors carry a code and typed
/// fields; the app that shows them writes the sentence.
#[derive(Debug, Clone, PartialEq)]
pub enum ScriptEntry {
    /// A result set, whose rows are in the store at `set_index`.
    ResultSet {
        set_index: usize,
        summary: ResultSetSummary,
    },
    /// A statement that returned no rows, with what it changed when the
    /// server reports that.
    Command {
        rows_affected: Option<u64>,
    },
    Notice {
        severity: String,
        message: String,
        code: Option<ServerCode>,
    },
    /// The run raised more notices than it keeps; `retained` came before
    /// this and the rest are gone.
    NoticeLimitReached {
        retained: u64,
    },
    Failed {
        error: DriverError,
        /// Where in the buffer the server says the error is, in
        /// characters, when it says.
        error_char: Option<usize>,
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

impl ScriptEntry {
    pub fn is_failure(&self) -> bool {
        matches!(self, Self::Failed { .. } | Self::TimedOut { .. })
    }
}

/// How one run of a batch ended, for deciding whether the next is sent.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Verdict {
    Completed,
    Failed,
    /// Cancelled, timed out, or the session itself failed: nothing more
    /// can run, whatever the engine's batch rules say.
    Stopped,
}

/// Whether the script goes on after a batch ended this way. A failed
/// statement stops it, because the statements after it were written
/// assuming it worked, unless the engine runs batches independently.
pub fn continues(verdict: Verdict, policy: BatchErrorPolicy) -> bool {
    match verdict {
        Verdict::Completed => true,
        Verdict::Failed => policy == BatchErrorPolicy::ContinueNextBatch,
        Verdict::Stopped => false,
    }
}

/// One batch's run, as the loop hands it to the caller.
#[derive(Debug, Clone, PartialEq)]
pub struct ScriptBatchReport {
    pub batch: usize,
    pub entries: Vec<ScriptEntry>,
    pub verdict: Verdict,
    pub transaction: Option<TransactionState>,
    /// The editor session's connection is gone.
    pub lost: bool,
    pub elapsed_ms: u128,
}

/// Where a run left the session.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub struct AfterRun {
    /// Where the transaction stands, as far as a connection still there
    /// said.
    pub transaction: Option<TransactionState>,
    /// The run lost the connection with a transaction open, and its
    /// results already say the transaction was rolled back.
    pub rollback_told: bool,
}
