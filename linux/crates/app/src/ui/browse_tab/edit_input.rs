use super::row_deletion::RowDeletion;
use crate::services::tracker_edit::TrackerEdit;
use crate::ui::grid::{CellPreset, RowObject};

/// What changes the tab's pending edits: a cell, a new or duplicated
/// row, a delete, undo and redo.
#[derive(Debug)]
pub(crate) enum EditInput {
    InsertRow,
    /// Queued after an insert, so the focus lands on the column view
    /// as it is once the insert is drawn.
    FocusInsertedDraft,
    /// Queued after a paste, as `FocusInsertedDraft` is after an insert.
    SelectPastedDrafts(u32),
    DeleteRows(Vec<RowObject>),
    /// Checked against the cell's lock before the tracker takes it.
    GridEdit {
        row: RowObject,
        column: usize,
        edit: TrackerEdit,
    },
    /// A preset from a cell's menu or Ctrl+Backspace. The tab resolves it
    /// against the column, so both paths reach the same value.
    GridSetCellValue {
        row: RowObject,
        column: usize,
        preset: CellPreset,
    },
    DuplicateRows(Vec<RowObject>),
    Undo,
    Redo,
    /// A delete the user confirmed, or one small enough to need no
    /// confirmation.
    MarkRowsDeleted(RowDeletion),
    /// The user answered the bulk delete confirmation `ticket` opened.
    BulkDeleteAnswered {
        ticket: u64,
        confirmed: bool,
    },
}
