use std::sync::Arc;

use tablepro_core::Value;
use tablepro_core::edit::CellInput;

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
        input: CellInput,
    },
    InsertDraft {
        cells: Vec<CellInput>,
    },
    /// One Delete: the saved rows are marked, each with the row as it
    /// was read, and the drafts are dropped.
    DeleteRows {
        persisted: Vec<(RowKey, Arc<[Value]>)>,
        drafts: Vec<u64>,
    },
}

impl TrackerEdit {
    /// The rows the edit changes. An insert makes a new one.
    pub fn row_keys(&self) -> Vec<RowKey> {
        match self {
            Self::Cell { row_key, .. } => vec![row_key.clone()],
            Self::DraftCell { draft_id, .. } => vec![RowKey::Draft(*draft_id)],
            Self::DeleteRows { persisted, drafts } => persisted
                .iter()
                .map(|(row_key, _)| row_key.clone())
                .chain(drafts.iter().map(|draft_id| RowKey::Draft(*draft_id)))
                .collect(),
            Self::InsertDraft { .. } => Vec::new(),
        }
    }
}
