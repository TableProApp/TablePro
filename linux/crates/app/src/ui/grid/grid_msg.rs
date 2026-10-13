use tablepro_core::QueryResult;

use super::CellPreset;

#[derive(Debug)]
pub enum GridMsg {
    /// The sorter's state after the click, not a toggle hint: a click on
    /// another column fires both sort notifies, and a hint would flip twice.
    SortChanged(usize, bool),
    CellEdited {
        row_position: u32,
        col_index: usize,
        new_value: String,
    },
    CopyToClipboard(String),
    ShowToast(String),
    CopyRowAsInsert {
        row_position: u32,
    },
    /// An intent, not a `Value`: the grid does not know the column's
    /// declared type, and `Text("")` in an `int` or a `date` column is an
    /// UPDATE the server rejects.
    SetCellValue {
        row_position: u32,
        col_index: usize,
        preset: CellPreset,
    },
    ExportResults(QueryResult),
    DeleteRowAt {
        row_position: u32,
    },
    InsertRow,
    DuplicateRow {
        row_position: u32,
    },
}
