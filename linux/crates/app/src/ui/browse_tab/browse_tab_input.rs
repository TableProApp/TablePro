use super::clipboard_input::ClipboardInput;
use super::data_input::DataInput;
use super::edit_input::EditInput;
use super::paging_input::PagingInput;
use super::save_input::SaveInput;
use super::selection_input::SelectionInput;
use crate::ui::grid::GridMsg;

/// An input to the tab, grouped by the state it changes, each group
/// handled on its own.
#[derive(Debug)]
pub(crate) enum BrowseTabInput {
    Data(DataInput),
    Paging(PagingInput),
    Edit(EditInput),
    Save(SaveInput),
    Selection(SelectionInput),
    Clipboard(ClipboardInput),
}

impl From<DataInput> for BrowseTabInput {
    fn from(input: DataInput) -> Self {
        Self::Data(input)
    }
}

impl From<PagingInput> for BrowseTabInput {
    fn from(input: PagingInput) -> Self {
        Self::Paging(input)
    }
}

impl From<EditInput> for BrowseTabInput {
    fn from(input: EditInput) -> Self {
        Self::Edit(input)
    }
}

impl From<SaveInput> for BrowseTabInput {
    fn from(input: SaveInput) -> Self {
        Self::Save(input)
    }
}

impl From<SelectionInput> for BrowseTabInput {
    fn from(input: SelectionInput) -> Self {
        Self::Selection(input)
    }
}

impl From<ClipboardInput> for BrowseTabInput {
    fn from(input: ClipboardInput) -> Self {
        Self::Clipboard(input)
    }
}

impl From<GridMsg> for BrowseTabInput {
    fn from(msg: GridMsg) -> Self {
        match msg {
            GridMsg::SortChanged(col_idx, ascending) => PagingInput::SortChanged { col_idx, ascending }.into(),
            GridMsg::SortCleared => PagingInput::SortCleared.into(),
            GridMsg::Edit { row, column, edit } => EditInput::GridEdit { row, column, edit }.into(),
            GridMsg::Copy(request) => ClipboardInput::GridCopy(request).into(),
            GridMsg::ShowRowJson(request) => ClipboardInput::GridShowRowJson(request).into(),
            GridMsg::ShowToast(text) => ClipboardInput::GridShowToast(text).into(),
            GridMsg::CopyRowsAsInsert { rows } => ClipboardInput::GridCopyRowsAsInsert(rows).into(),
            GridMsg::CopyInClause(values) => ClipboardInput::GridCopyInClause(values).into(),
            GridMsg::SetCellValue { row, column, preset } => EditInput::GridSetCellValue { row, column, preset }.into(),
            GridMsg::ExportResults(page) => ClipboardInput::Export(Some(page)).into(),
            GridMsg::DeleteRows { rows } => EditInput::DeleteRows(rows).into(),
            GridMsg::InsertRow => EditInput::InsertRow.into(),
            GridMsg::DuplicateRows { rows } => EditInput::DuplicateRows(rows).into(),
        }
    }
}
