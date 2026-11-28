use std::sync::Arc;

use crate::column::ResultColumn;
use crate::value::Value;

/// Where a script run's result-set rows are kept.
///
/// The batch loop trims each result to the run's budget before the rows
/// reach here, so the store keeps what it is given. `start_set` hands
/// back a run-wide index the structured log points at; the Windows app
/// backs it with the core's `ResultStore`, the Linux app with the rows
/// its grid reads. One run uses one store across all its batches.
pub trait ScriptResultStore: Send + Sync {
    /// A new result set started. The returned index names it for the rest
    /// of the run and is what the log's `ResultSet` entry carries.
    fn start_set(&self, columns: Arc<[ResultColumn]>) -> usize;

    /// The columns of a set whose types the driver knew only once rows
    /// arrived.
    fn resolve_columns(&self, set_index: usize, columns: Arc<[ResultColumn]>);

    /// Keep `rows` for the set, after the loop has trimmed them to the
    /// run's budget.
    fn append(&self, set_index: usize, rows: Vec<Vec<Value>>);

    /// The set ended. `total_rows` is every row the statement produced
    /// where the engine counted past the limit; `cut` says rows the set
    /// held were dropped, by the driver or the run's budget. A set the
    /// run abandons before it ends is never told this; the caller marks
    /// it when the run finishes.
    fn finish_set(&self, set_index: usize, total_rows: Option<u64>, cut: bool);
}
