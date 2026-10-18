use tablepro_core::ColumnInfo;
use tablepro_core::meta::TableRef;

use super::change_tracker::TrackedChanges;
use crate::workspace::SaveSnapshot;

/// The table a tab's rows come from, as the tab last read it.
#[derive(Debug, Clone, PartialEq)]
pub struct SaveTarget {
    pub table: TableRef,
    pub columns: Vec<ColumnInfo>,
}

/// What one save of a tab's rows writes. The columns are the ones the
/// changes were built against, so the plan binds the same shape, and
/// `changes` maps a failing step back to its grid row.
#[derive(Debug, Clone)]
pub struct SaveBatch {
    pub table: TableRef,
    pub columns: Vec<ColumnInfo>,
    pub changes: TrackedChanges,
    pub snapshot: SaveSnapshot,
}
