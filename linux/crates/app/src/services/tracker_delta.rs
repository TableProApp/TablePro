use super::change_tracker::RowKey;

/// What a tracker change means for the grid, handed back once the
/// tracker is no longer borrowed so the caller can touch GTK freely.
#[derive(Debug, Clone, Default, PartialEq)]
pub struct TrackerDelta {
    /// Rows whose pending state changed and need a rebind.
    pub rows: Vec<RowKey>,
    /// Draft rows the list store has to gain or lose.
    pub visual: Vec<VisualChange>,
    pub pending_count: usize,
}

#[derive(Debug, Clone, PartialEq)]
pub enum VisualChange {
    RemoveDraft { draft_id: u64 },
    InsertDraft { draft_id: u64 },
}
