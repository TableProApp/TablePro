use tablepro_core::Value;

use super::change_tracker::{CellEdit, DeleteMark, DraftRow, RowKey};
use super::column_relayout::ColumnRelayout;
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
    /// The step under the columns `layout` moves to, or `None` when a
    /// value in it has no place there.
    pub(crate) fn relayout(&self, layout: &ColumnRelayout<'_>) -> Option<Self> {
        let delete_mark = |mark: &DeleteMark| DeleteMark {
            original_values: layout.fetched(&mark.original_values),
            touched: mark.touched,
        };
        match self {
            UndoOp::CellEdit {
                row_key,
                col,
                before,
                after,
            } => {
                layout.key(row_key).ok()?;
                let mut moved = layout.position(*col)?;
                for edit in [before, after].into_iter().flatten() {
                    moved = layout.cell(*col, &edit.pending).ok()?;
                }
                Some(UndoOp::CellEdit {
                    row_key: row_key.clone(),
                    col: moved,
                    before: before.clone(),
                    after: after.clone(),
                })
            }
            UndoOp::DraftCell {
                draft_id,
                col,
                before,
                after,
                before_touch,
                after_touch,
            } => {
                layout.cell(*col, before).ok()?;
                Some(UndoOp::DraftCell {
                    draft_id: *draft_id,
                    col: layout.cell(*col, after).ok()?,
                    before: before.clone(),
                    after: after.clone(),
                    before_touch: *before_touch,
                    after_touch: *after_touch,
                })
            }
            UndoOp::Insert { draft } => Some(UndoOp::Insert {
                draft: DraftRow {
                    values: layout.row(&draft.values).ok()?,
                    ..draft.clone()
                },
            }),
            UndoOp::Delete { row_key, before, after } => {
                layout.key(row_key).ok()?;
                Some(UndoOp::Delete {
                    row_key: row_key.clone(),
                    before: before.as_ref().map(delete_mark),
                    after: delete_mark(after),
                })
            }
        }
    }

    pub fn is_about_draft(&self, draft_id: u64) -> bool {
        match self {
            UndoOp::Insert { draft } => draft.draft_id == draft_id,
            UndoOp::DraftCell { draft_id: id, .. } => *id == draft_id,
            UndoOp::CellEdit { row_key, .. } | UndoOp::Delete { row_key, .. } => *row_key == RowKey::Draft(draft_id),
        }
    }
}
