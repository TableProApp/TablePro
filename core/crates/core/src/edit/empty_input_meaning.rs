use crate::column::ColumnInfo;

use super::EditContext;

/// What committing an empty cell means.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum EmptyInputMeaning {
    /// The empty string, which the column can hold.
    EmptyText,
    /// Leave the column out of the insert so the server fills it.
    Default,
    Null,
    /// Nothing the column can hold, so the edit is refused.
    Required,
}

/// What an empty cell means for this column in this row.
///
/// Only an INSERT can leave a column out, so an existing row never gets
/// a default from an empty cell: `SET c = DEFAULT` is not available on
/// SQLite or in a ClickHouse mutation.
pub fn empty_input_meaning(column: &ColumnInfo, context: EditContext) -> EmptyInputMeaning {
    if column.column_type.kind.accepts_empty_string() {
        return EmptyInputMeaning::EmptyText;
    }
    let server_fills = !column.default.is_none() || column.is_auto_increment || column.is_generated;
    match context {
        EditContext::InsertDraft if server_fills => EmptyInputMeaning::Default,
        _ if column.nullable => EmptyInputMeaning::Null,
        _ => EmptyInputMeaning::Required,
    }
}
