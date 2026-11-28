use std::time::Duration;

use crate::byte_limit::ByteLimit;
use crate::row_limit::RowLimit;
use crate::sql_syntax::script::BatchErrorPolicy;

/// One unit the server is sent: a statement on most engines, a whole
/// `GO` batch on SQL Server.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct RunBatch {
    pub text: String,
    /// How many times `GO n` asks for it.
    pub repeat: u32,
    /// Where the batch starts in the buffer, in characters.
    pub error_base: usize,
    /// Safe Mode is Read-Only and the batch writes, so it is not sent.
    pub refused: bool,
}

/// What one press of Run sends, and how.
#[derive(Debug, Clone)]
pub struct ScriptRun {
    pub batches: Vec<RunBatch>,
    pub policy: BatchErrorPolicy,
    pub statement_timeout: Option<Duration>,
    pub row_limit: RowLimit,
    pub run_row_limit: u64,
    pub byte_limit: ByteLimit,
}

/// The rows a batch may still keep under its run's limit.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct RowRoom {
    /// The run's limit, which a result it cuts short names.
    pub run_limit: u64,
    pub left: u64,
    /// The statement was sent with `left` as its row limit, below its
    /// own, so a result the driver cut short was cut by the run's limit.
    pub limits_statement: bool,
    /// The run's byte limit, which a result it cuts short names.
    pub run_bytes: u64,
    /// The bytes of rows the run can still keep.
    pub bytes_left: u64,
}

impl RowRoom {
    /// A result the session cut for size without a room from the run
    /// names the editor's own limit.
    pub const UNLIMITED: Self = Self {
        run_limit: u64::MAX,
        left: u64::MAX,
        limits_statement: false,
        run_bytes: ByteLimit::EDITOR_DEFAULT.get(),
        bytes_left: u64::MAX,
    };
}

/// Rows and bytes one run has kept across all its results so far.
#[derive(Debug, Clone, Copy, Default)]
pub(super) struct Kept {
    pub(super) rows: u64,
    pub(super) bytes: u64,
}

/// What a statement may keep once the run has kept `kept`, and the row
/// and byte limits it goes out with. With no room left it still runs,
/// for what it changes, and reads one row, which is dropped.
pub fn room_after(run: &ScriptRun, rows_kept: u64, bytes_kept: u64) -> (RowRoom, RowLimit, ByteLimit) {
    let left = run.run_row_limit.saturating_sub(rows_kept);
    let own = run.row_limit.get();
    let bytes_left = run.byte_limit.get().saturating_sub(bytes_kept);
    let room = RowRoom {
        run_limit: run.run_row_limit,
        left,
        limits_statement: left < own,
        run_bytes: run.byte_limit.get(),
        bytes_left,
    };
    (
        room,
        RowLimit::new(left.clamp(1, own)).unwrap_or(run.row_limit),
        ByteLimit::new(bytes_left.max(1)).unwrap_or(run.byte_limit),
    )
}
