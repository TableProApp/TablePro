use super::BrowseTabInput;
use crate::ui::grid::GridMsg;

pub(super) fn to_input(msg: GridMsg) -> BrowseTabInput {
    match msg {
        GridMsg::SortChanged(col_idx, ascending) => BrowseTabInput::SortChanged { col_idx, ascending },
        GridMsg::CellEdited {
            row_position,
            col_index,
            new_value,
            row_key,
        } => BrowseTabInput::GridCellEdited {
            row_position,
            col_index,
            new_value,
            row_key,
        },
        GridMsg::CopyToClipboard(text) => BrowseTabInput::GridCopyToClipboard(text),
        GridMsg::FetchCellValue {
            col_index,
            column_name,
            row_key,
        } => BrowseTabInput::GridFetchCellValue {
            col_index,
            column_name,
            row_key,
        },
        GridMsg::IncompleteRowData => BrowseTabInput::IncompleteRowData,
        GridMsg::ProjectionFailure => BrowseTabInput::ProjectionFailure,
        GridMsg::ShowRowAsJson(text) => BrowseTabInput::GridShowRowAsJson(text),
        GridMsg::ExportResults(result) => BrowseTabInput::GridExportResults(result),
        GridMsg::CopyRowAsInsert { row_position } => BrowseTabInput::GridCopyRowAsInsert { row_position },
        GridMsg::SetCellNull {
            row_position,
            col_index,
            row_key,
        } => BrowseTabInput::GridSetCellNull {
            row_position,
            col_index,
            row_key,
        },
        GridMsg::DeleteRowAt { row_position, row_key } => BrowseTabInput::GridDeleteRowAt { row_position, row_key },
        GridMsg::InsertRow => BrowseTabInput::InsertRow,
        GridMsg::DuplicateRow { row_position } => BrowseTabInput::DuplicateRow { row_position },
        GridMsg::FilterByValue { column, value } => BrowseTabInput::FilterByValue { column, value },
    }
}
