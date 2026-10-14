use std::rc::Rc;

use tablepro_core::QueryResult;

use super::{CellPreset, RowObject};
use crate::services::tracker_edit::TrackerEdit;

/// Where a grid sends its events. The owner holds the grid, so the
/// closure holds the owner weakly.
pub type GridSink = Rc<dyn Fn(GridMsg)>;

#[derive(Debug)]
pub enum GridMsg {
    /// The sorter's state after the click, not a toggle hint: a click on
    /// another column fires both sort notifies, and a hint would flip twice.
    SortChanged(usize, bool),
    /// An edit of `column` in `row`, already parsed for the column.
    Edit {
        row: RowObject,
        column: usize,
        edit: TrackerEdit,
    },
    CopyToClipboard(String),
    ShowToast(String),
    CopyRowsAsInsert {
        rows: Vec<RowObject>,
    },
    /// An intent the tab resolves against the column, so the keyboard
    /// path and the menu reach the same value.
    SetCellValue {
        row: RowObject,
        column: usize,
        preset: CellPreset,
    },
    ExportResults(QueryResult),
    DeleteRows {
        rows: Vec<RowObject>,
    },
    InsertRow,
    DuplicateRows {
        rows: Vec<RowObject>,
    },
}
