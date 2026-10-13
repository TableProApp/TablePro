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
