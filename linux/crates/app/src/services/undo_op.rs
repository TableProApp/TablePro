use std::collections::HashSet;

use tablepro_core::edit::CellInput;

use super::change_tracker::{CellEdit, DeleteMark, DraftRow, RowKey};
use super::column_relayout::ColumnRelayout;
use super::touch::Touch;

/// One step of a tab's undo history, holding the pending state on both
/// sides of the step. Undo puts `before` back exactly and redo puts
/// `after` back, touches included, so a save after an undo runs in the
/// same order it would have before the step.
#[derive(Debug, Clone, PartialEq)]
pub enum UndoOp {
    Group {
        steps: Vec<UndoOp>,
    },
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
        before: CellInput,
        after: CellInput,
        before_touch: Touch,
        after_touch: Touch,
    },
    /// One undo removes every draft the insert made.
    Insert {
        drafts: Vec<DraftRow>,
    },
    Delete {
        steps: Vec<DeleteStep>,
    },
}

#[derive(Debug, Clone, PartialEq)]
pub struct DeleteStep {
    pub row_key: RowKey,
    pub before: Option<DeleteMark>,
    pub after: DeleteMark,
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
            UndoOp::Group { steps } => Some(UndoOp::Group {
                steps: steps.iter().map(|step| step.relayout(layout)).collect::<Option<_>>()?,
            }),
            UndoOp::CellEdit {
                row_key,
                col,
                before,
                after,
            } => {
                layout.key(row_key).ok()?;
                let mut moved = layout.position(*col)?;
                for edit in [before, after].into_iter().flatten() {
                    moved = layout.input_cell(*col, &edit.pending).ok()?;
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
                layout.input_cell(*col, before).ok()?;
                Some(UndoOp::DraftCell {
                    draft_id: *draft_id,
                    col: layout.input_cell(*col, after).ok()?,
                    before: before.clone(),
                    after: after.clone(),
                    before_touch: *before_touch,
                    after_touch: *after_touch,
                })
            }
            UndoOp::Insert { drafts } => Some(UndoOp::Insert {
                drafts: drafts
                    .iter()
                    .map(|draft| {
                        Some(DraftRow {
                            cells: layout.draft(&draft.cells).ok()?,
                            ..draft.clone()
                        })
                    })
                    .collect::<Option<_>>()?,
            }),
            UndoOp::Delete { steps } => Some(UndoOp::Delete {
                steps: steps
                    .iter()
                    .map(|step| {
                        layout.key(&step.row_key).ok()?;
                        Some(DeleteStep {
                            row_key: step.row_key.clone(),
                            before: step.before.as_ref().map(delete_mark),
                            after: delete_mark(&step.after),
                        })
                    })
                    .collect::<Option<_>>()?,
            }),
        }
    }

    /// Drops what the step says about drafts that are gone, and returns
    /// whether anything is left of the step.
    pub fn forget_drafts(&mut self, gone: &HashSet<u64>) -> bool {
        let is_gone = |row_key: &RowKey| matches!(row_key, RowKey::Draft(draft_id) if gone.contains(draft_id));
        match self {
            UndoOp::Group { steps } => {
                steps.retain_mut(|step| step.forget_drafts(gone));
                !steps.is_empty()
            }
            UndoOp::Insert { drafts } => {
                drafts.retain(|draft| !gone.contains(&draft.draft_id));
                !drafts.is_empty()
            }
            UndoOp::DraftCell { draft_id, .. } => !gone.contains(&*draft_id),
            UndoOp::CellEdit { row_key, .. } => !is_gone(row_key),
            UndoOp::Delete { steps } => {
                steps.retain(|step| !is_gone(&step.row_key));
                !steps.is_empty()
            }
        }
    }
}
