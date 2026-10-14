use std::rc::Rc;

use tablepro_core::QueryResult;

use super::{CellPreset, RowObject};

/// Where a grid sends its events. The owner holds the grid, so the
/// closure holds the owner weakly.
pub type GridSink = Rc<dyn Fn(GridMsg)>;

#[derive(Debug)]
pub enum GridMsg {
    /// The sorter's state after the click, not a toggle hint: a click on
    /// another column fires both sort notifies, and a hint would flip twice.
    SortChanged(usize, bool),
    CellEdited {
        row: RowObject,
        column: usize,
        input: String,
    },
    CopyToClipboard(String),
    ShowToast(String),
    CopyRowsAsInsert {
        rows: Vec<RowObject>,
    },
    /// An intent, not a `Value`: the grid does not know the column's
    /// declared type, and `Text("")` in an `int` or a `date` column is an
    /// UPDATE the server rejects.
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
