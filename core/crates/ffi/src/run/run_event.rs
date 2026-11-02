use tablepro_core::{DriverError, RunEnd, RunSummary, ServerNotice, Truncation};

use crate::error::{CoreError, ErrorInfo};
use crate::results::ResultColumnInfo;

/// One thing that happened in a run, in the order it happened. Rows that
/// arrive between two drains come as one `RowsAppended` with the set's
/// row count at the last append.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Enum)]
pub enum RunEvent {
    ResultSetStarted {
        set_index: u32,
        columns: Vec<ResultColumnInfo>,
    },
    /// The columns of a set whose types the driver knew only once rows
    /// arrived.
    ColumnsResolved {
        set_index: u32,
        columns: Vec<ResultColumnInfo>,
    },
    RowsAppended {
        set_index: u32,
        row_count: u64,
    },
    RowLimitReached {
        set_index: u32,
        retained: u64,
    },
    ResultSetFinished {
        set_index: u32,
        row_count: u64,
        /// Every row the statement produced, where the engine counted
        /// past the limit.
        total_rows: Option<u64>,
        truncation: TruncationTag,
    },
    CommandCompleted {
        rows_affected: Option<u64>,
    },
    /// Something the server said that is not an error.
    Notice {
        severity: String,
        message: String,
        code: Option<String>,
    },
    /// The last event of every run.
    Finished {
        outcome: RunOutcome,
    },
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum TruncationTag {
    Complete,
    /// The statement was stopped at the row limit.
    ServerStopped,
    /// There were rows past the limit, which were not kept.
    ReadPastLimit,
}

/// How a run ended. A statement the server refused is `Failed`, not an
/// error of the call.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Enum)]
pub enum RunOutcome {
    Completed { elapsed_ms: u64 },
    Failed { info: ErrorInfo },
    Cancelled,
    TimedOut { server_cancelled: bool },
}

impl RunOutcome {
    pub(crate) fn of(result: Result<RunSummary, DriverError>) -> Self {
        match result {
            Ok(summary) => match summary.end {
                RunEnd::Completed => Self::Completed {
                    elapsed_ms: u64::try_from(summary.elapsed.as_millis()).unwrap_or(u64::MAX),
                },
                RunEnd::Failed(error) => Self::from(CoreError::from(error)),
                RunEnd::Cancelled => Self::Cancelled,
                RunEnd::TimedOut { server_cancelled } => Self::TimedOut { server_cancelled },
            },
            Err(error) => Self::from(CoreError::from(error)),
        }
    }
}

impl From<CoreError> for RunOutcome {
    fn from(error: CoreError) -> Self {
        match error {
            CoreError::Cancelled => Self::Cancelled,
            CoreError::Failed { info } => Self::Failed { info },
        }
    }
}

impl From<Truncation> for TruncationTag {
    fn from(truncation: Truncation) -> Self {
        match truncation {
            Truncation::Complete => Self::Complete,
            Truncation::ServerStopped => Self::ServerStopped,
            Truncation::ReadPastLimit => Self::ReadPastLimit,
        }
    }
}

impl From<ServerNotice> for RunEvent {
    fn from(notice: ServerNotice) -> Self {
        Self::Notice {
            severity: notice.severity,
            message: notice.message,
            code: notice.code.as_ref().map(ToString::to_string),
        }
    }
}
