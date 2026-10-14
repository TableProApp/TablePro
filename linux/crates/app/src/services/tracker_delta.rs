use super::change_tracker::RowKey;

/// What a tracker change means for the grid, handed back once the
/// tracker is no longer borrowed so the caller can touch GTK freely.
#[derive(Debug, Clone, Default, PartialEq)]
pub struct TrackerDelta {
    /// Rows whose pending state changed and need a redraw.
    pub changed: Vec<RowKey>,
    /// Draft rows the list store gains, oldest first.
    pub inserted_drafts: Vec<u64>,
    /// Draft rows the list store loses.
    pub removed_drafts: Vec<u64>,
    pub pending_count: usize,
}
