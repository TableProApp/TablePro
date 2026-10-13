use tablepro_core::Value;

use super::change_tracker::{CellEdit, DeleteMark, DraftRow, RowKey};
use super::touch::Touch;

/// One step of a tab's undo history, holding the pending state on both
/// sides of the step. Undo puts `before` back exactly and redo puts
/// `after` back, touches included, so a save after an undo runs in the
/// same order it would have before the step.
#[derive(Debug, Clone, PartialEq)]
pub enum UndoOp {
    /// `None` on either side means the cell had no pending edit, which
    /// is also what an edit back to the fetched value leaves.
    CellEdit {
        row_key: RowKey,
        col: usize,
        before: Option<CellEdit>,
        after: Option<CellEdit>,
    },
    DraftCell {
        draft_id: u64,
        col: usize,
        before: Value,
        after: Value,
        before_touch: Touch,
        after_touch: Touch,
    },
    Insert {
        draft: DraftRow,
    },
    Delete {
        row_key: RowKey,
        before: Option<DeleteMark>,
        after: DeleteMark,
    },
}

impl UndoOp {
    pub fn is_about_draft(&self, draft_id: u64) -> bool {
        match self {
            UndoOp::Insert { draft } => draft.draft_id == draft_id,
            UndoOp::DraftCell { draft_id: id, .. } => *id == draft_id,
            UndoOp::CellEdit { row_key, .. } | UndoOp::Delete { row_key, .. } => *row_key == RowKey::Draft(draft_id),
        }
    }
}
