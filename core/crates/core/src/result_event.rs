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
    /// The server stopped the statement at the row limit, one row past
    /// the rows kept, so work it does per row may have run for only part
    /// of the rows. A set the byte limit also cut keeps this, since it
    /// says more.
    ServerStopped,
    /// The run hit its row limit and there were more rows behind it.
    ReadPastLimit,
    // Rows past the cut were not kept, though the engine may still have read them up to the row limit.
    ByteLimit,
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
    // Once per set, at the cut: `retained` rows of the set came before it.
    ByteLimitReached {
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
    /// The run raised more notices than it keeps. `retained` were sent
    /// before it; the rest are gone.
    NoticeLimitReached {
        retained: u64,
    },
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
