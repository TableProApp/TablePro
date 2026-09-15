use std::sync::Arc;
use std::time::Duration;

use crate::column::ResultColumn;
use crate::error::DriverError;
use crate::server_diagnostics::ServerCode;
use crate::transaction_state::TransactionState;
use crate::value::Value;

/// Something the server said about a message that is not an error, such
/// as a RAISE NOTICE or a warning a statement raised.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ServerNotice {
    pub severity: String,
    pub message: String,
    pub code: Option<ServerCode>,
}

/// Why a result set stopped where it did.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum Truncation {
    /// Every row the statement produced is here.
    Complete,
    /// The server stopped sending, because the query had a LIMIT of its
    /// own or the run was stopped.
    ServerStopped,
    /// The run hit its row limit and there were more rows behind it.
    ReadPastLimit,
}

/// One step of a run, as it happens.
///
/// A run is a stream rather than a return value because the first rows
/// are worth showing before the last ones arrive, and because a script
/// can produce several result sets.
#[derive(Debug, Clone, PartialEq)]
pub enum ResultEvent {
    ResultSetStarted {
        columns: Arc<[ResultColumn]>,
    },
    /// The columns of a set whose types the driver could only resolve
    /// once rows arrived.
    ColumnsResolved {
        set_index: usize,
        columns: Arc<[ResultColumn]>,
    },
    Rows(Vec<Vec<Value>>),
    RowLimitReached {
        retained: u64,
    },
    ResultSetFinished {
        retained: u64,
        total_rows: Option<u64>,
        truncation: Truncation,
    },
    CommandCompleted {
        rows_affected: Option<u64>,
    },
    Notice(ServerNotice),
}

/// How a run ended.
#[derive(Debug, Clone, PartialEq)]
pub enum RunEnd {
    Completed,
    Failed(DriverError),
    Cancelled,
    TimedOut { server_cancelled: bool },
}

/// What a run did, once it is over.
#[derive(Debug, Clone, PartialEq)]
pub struct RunSummary {
    pub elapsed: Duration,
    pub end: RunEnd,
    pub transaction_state: TransactionState,
}

impl RunSummary {
    pub fn succeeded(&self) -> bool {
        matches!(self.end, RunEnd::Completed)
    }
}
