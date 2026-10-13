use tablepro_core::Value;

use super::change_tracker::RowKey;

/// One change a browse tab records against its pending edits.
#[derive(Debug, Clone, PartialEq)]
pub enum TrackerEdit {
    Cell {
        row_key: RowKey,
        col: usize,
        original: Value,
        value: Value,
    },
    DraftCell {
        draft_id: u64,
        col: usize,
        value: Value,
    },
    Insert {
        values: Vec<Value>,
    },
    Delete {
        row_key: RowKey,
        original_values: Vec<Value>,
    },
    DiscardDraft {
        draft_id: u64,
    },
}

impl TrackerEdit {
    /// The row the edit changes. An insert makes a new one.
    pub fn row_key(&self) -> Option<RowKey> {
        match self {
            Self::Cell { row_key, .. } | Self::Delete { row_key, .. } => Some(row_key.clone()),
            Self::DraftCell { draft_id, .. } | Self::DiscardDraft { draft_id } => Some(RowKey::Draft(*draft_id)),
            Self::Insert { .. } => None,
        }
    }
}
