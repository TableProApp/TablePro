use super::data_input::DataInput;
use super::grid_input::GridInput;
use super::paging_input::PagingInput;
use super::save_input::SaveInput;

/// An input to the tab, grouped by the state it changes, each group
/// handled on its own.
#[derive(Debug)]
pub(crate) enum BrowseTabInput {
    Data(DataInput),
    Paging(PagingInput),
    Save(SaveInput),
    Grid(GridInput),
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

impl From<SaveInput> for BrowseTabInput {
    fn from(input: SaveInput) -> Self {
        Self::Save(input)
    }
}

impl From<GridInput> for BrowseTabInput {
    fn from(input: GridInput) -> Self {
        Self::Grid(input)
    }
}
