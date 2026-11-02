use crate::column::ColumnInfo;
use crate::value::Value;

use super::CellInput;

/// What a new row holds in `column` until the user types: the server's
/// value where it has one, else NULL.
pub fn new_draft_cell(column: &ColumnInfo) -> CellInput {
    match column.is_auto_increment || column.is_generated || !column.default.is_none() {
        true => CellInput::Default,
        false => CellInput::Value(Value::Null),
    }
}
